#!/usr/bin/env bash
# Creates what Terraform needs before its first run: the project, the APIs,
# the state bucket, the Cloud KMS key, .sops.yaml and the state CSEK.
# docs/bootstrap.md explains each step and the equivalent manual commands.
#
# Idempotent: every step checks what exists and only creates what is
# missing, so it is safe to run again (e.g. after adding TERRAFORM_MEMBERS).
# It never replaces an existing CSEK: a new key would lock you out of the
# state encrypted with the old one.
#
# Usage: bootstrap/bootstrap.sh   (after creating bootstrap/config.env)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" # sops looks for .sops.yaml from the working directory up

config="bootstrap/config.env"
sops_config=".sops.yaml"
csek_file="terraform/secrets/encryption_key.txt"
example_secret_file="terraform/secrets/example.secrets.yaml"

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for bin in gcloud sops base64 head; do
  command -v "$bin" >/dev/null || die "'$bin' is not in PATH"
done
[[ -f "$config" ]] || die "copy bootstrap/config.env.example to $config and edit it"
# shellcheck source=bootstrap/config.env.example
source "$config"
: "${PROJECT_ID:?set PROJECT_ID in $config}"
: "${REGION:?set REGION in $config}"
: "${STATE_BUCKET:?set STATE_BUCKET in $config}"
: "${STATE_BUCKET_LOCATION:?set STATE_BUCKET_LOCATION in $config}"
: "${STATE_VERSIONS_TO_KEEP:?set STATE_VERSIONS_TO_KEEP in $config}"
: "${KMS_LOCATION:?set KMS_LOCATION in $config}"
: "${KMS_KEYRING:?set KMS_KEYRING in $config}"
: "${KMS_KEY:?set KMS_KEY in $config}"
kms_key_id="projects/${PROJECT_ID}/locations/${KMS_LOCATION}/keyRings/${KMS_KEYRING}/cryptoKeys/${KMS_KEY}"
kms_flags=(--keyring="$KMS_KEYRING" --location="$KMS_LOCATION" --project="$PROJECT_ID")

ensure_project() {
  if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    log "project $PROJECT_ID exists"
    return
  fi
  local parent=()
  if [[ -n "${FOLDER_ID:-}" ]]; then
    parent=(--folder="$FOLDER_ID")
  elif [[ -n "${ORG_ID:-}" ]]; then
    parent=(--organization="$ORG_ID")
  fi
  log "creating project $PROJECT_ID"
  # ${parent[@]+...}: an empty array is "unbound" for set -u in bash 3.2 (macOS).
  gcloud projects create "$PROJECT_ID" ${parent[@]+"${parent[@]}"}
}

ensure_billing() {
  if [[ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)')" == "True" ]]; then
    log "billing is enabled"
    return
  fi
  [[ -n "${BILLING_ACCOUNT:-}" ]] || die "billing is not enabled on $PROJECT_ID: set BILLING_ACCOUNT in $config"
  log "linking billing account $BILLING_ACCOUNT"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" >/dev/null
}

enable_apis() {
  local apis=(storage.googleapis.com cloudkms.googleapis.com)
  local extra=()
  read -r -a extra <<<"${EXTRA_APIS:-}"
  apis+=(${extra[@]+"${extra[@]}"})
  log "enabling APIs: ${apis[*]}"
  gcloud services enable "${apis[@]}" --project="$PROJECT_ID"
}

ensure_bucket() {
  local url="gs://${STATE_BUCKET}"
  if gcloud storage buckets describe "$url" >/dev/null 2>&1; then
    log "bucket $url exists"
  else
    log "creating bucket $url"
    gcloud storage buckets create "$url" --project="$PROJECT_ID" \
      --location="$STATE_BUCKET_LOCATION" \
      --uniform-bucket-level-access --public-access-prevention
  fi

  # Applied on every run so the bucket converges to config.env.
  # Rule 1 keeps STATE_VERSIONS_TO_KEEP versions of each state file.
  # Rule 2 drops old versions of the lock files as soon as they are released.
  local lifecycle
  lifecycle="$(mktemp)"
  cat >"$lifecycle" <<EOF
{
  "rule": [
    {"action": {"type": "Delete"}, "condition": {"isLive": false, "numNewerVersions": ${STATE_VERSIONS_TO_KEEP}}},
    {"action": {"type": "Delete"}, "condition": {"isLive": false, "matchesSuffix": [".tflock"]}}
  ]
}
EOF
  log "setting versioning and lifecycle on $url"
  gcloud storage buckets update "$url" --versioning --lifecycle-file="$lifecycle" >/dev/null
  rm -f "$lifecycle"
}

ensure_kms_key() {
  if gcloud kms keyrings describe "$KMS_KEYRING" --location="$KMS_LOCATION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    log "KMS keyring $KMS_KEYRING exists"
  else
    log "creating KMS keyring $KMS_KEYRING"
    gcloud kms keyrings create "$KMS_KEYRING" --location="$KMS_LOCATION" --project="$PROJECT_ID"
  fi
  if gcloud kms keys describe "$KMS_KEY" "${kms_flags[@]}" >/dev/null 2>&1; then
    log "KMS key $KMS_KEY exists"
  else
    log "creating KMS key $KMS_KEY"
    gcloud kms keys create "$KMS_KEY" "${kms_flags[@]}" --purpose=encryption
  fi
}

grant_members() {
  local members=()
  read -r -a members <<<"${TERRAFORM_MEMBERS:-}"
  local member
  for member in ${members[@]+"${members[@]}"}; do
    log "granting $member access to the KMS key and the state bucket"
    gcloud kms keys add-iam-policy-binding "$KMS_KEY" "${kms_flags[@]}" \
      --member="$member" --role=roles/cloudkms.cryptoKeyEncrypterDecrypter >/dev/null
    gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
      --member="$member" --role=roles/storage.objectAdmin >/dev/null
  done
}

write_sops_config() {
  # The template ships a placeholder; a .sops.yaml you edited is left alone.
  if [[ -f "$sops_config" ]] && ! grep -q REPLACE_WITH_PROJECT_ID "$sops_config"; then
    grep -qF "$kms_key_id" "$sops_config" ||
      printf 'WARNING: %s does not mention %s\n' "$sops_config" "$kms_key_id" >&2
    log "$sops_config already configured"
    return
  fi
  log "writing $sops_config"
  cat >"$sops_config" <<EOF
# Written by bootstrap/bootstrap.sh: SOPS encrypts every file in this repo
# with the project's Cloud KMS key.
creation_rules:
  - gcp_kms: ${kms_key_id}
EOF
}

# The CSEK is 32 random bytes in base64, the format GCS expects. It only
# exists unencrypted inside this pipe: SOPS writes it encrypted with KMS.
ensure_csek() {
  if [[ -f "$csek_file" ]]; then
    local size
    size="$(sops decrypt "$csek_file" | base64 -d | wc -c)"
    [[ "$size" -eq 32 ]] || die "$csek_file does not decrypt to a 32-byte key"
    log "CSEK exists and decrypts to a 32-byte key"
    return
  fi
  log "generating the state CSEK in $csek_file"
  mkdir -p "$(dirname "$csek_file")"
  head -c 32 /dev/urandom | base64 | tr -d '\n' |
    sops encrypt --filename-override "$csek_file" --output "$csek_file"
}

# Demo value for the example stacks; delete the file along with them.
ensure_example_secret() {
  if [[ -f "$example_secret_file" ]]; then
    log "$example_secret_file exists"
    return
  fi
  log "creating $example_secret_file with a random demo password"
  printf 'db_password: %s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '\n/+=')" |
    sops encrypt --filename-override "$example_secret_file" --output "$example_secret_file"
}

ensure_project
ensure_billing
enable_apis
ensure_bucket
ensure_kms_key
grant_members
write_sops_config
ensure_csek
ensure_example_secret

cat <<EOF

Bootstrap complete. Next steps:
  git add $config $sops_config terraform/secrets
  git commit -m "chore: bootstrap $PROJECT_ID"
  make -C terraform/foundation init
  terraform -chdir=terraform/foundation plan
EOF
