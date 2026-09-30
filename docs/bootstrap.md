# Bootstrap

Terraform cannot create the things its own backend needs, so they are created
once, before the first `terraform init`:

1. [Log in](#0-log-in)
2. [Project and billing](#1-project-and-billing)
3. [APIs](#2-apis)
4. [State bucket](#3-state-bucket)
5. [Cloud KMS key](#4-cloud-kms-key)
6. [SOPS configuration](#5-sops-configuration)
7. [State encryption key (CSEK)](#6-state-encryption-key-csek)
8. [Secrets](#7-secrets)
9. [Team access](#8-team-access)
10. [Commit](#9-commit)
11. [Initialize the Terraform state](#10-initialize-the-terraform-state)

`bootstrap/bootstrap.sh` runs steps 1-7 (and step 8 when `TERRAFORM_MEMBERS`
is set) from `bootstrap/config.env`. Every step checks what exists first, so
the script is safe to run again. The commands below are what it runs. Use
them to bootstrap by hand, or to see what the script will do before you run
it.

The examples use these variables. They match `bootstrap/config.env`:

```bash
PROJECT_ID=my-project-tf-1234
ORG_ID=123456789012                  # or FOLDER_ID, or neither
BILLING_ACCOUNT=0X0X0X-0X0X0X-0X0X0X
REGION=us-central1
STATE_BUCKET=${PROJECT_ID}-tfstate
KMS_KEY_ID=projects/${PROJECT_ID}/locations/global/keyRings/sops/cryptoKeys/sops-key
```

Run every command from the repository root: SOPS looks for `.sops.yaml` in the
working directory and its parents.

## 0. Log in

```bash
gcloud auth login                        # credentials for gcloud
gcloud auth application-default login    # credentials for SOPS and Terraform (ADC)
```

If you would rather not change your global ADC, you can give each command an
access token instead:
`export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`. gcloud,
SOPS, the gcs backend and both providers accept it.

## 1. Project and billing

```bash
gcloud projects create "$PROJECT_ID" --organization="$ORG_ID"   # or --folder=...
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
```

Find your billing account ID with `gcloud billing accounts list`. Cloud KMS
and Cloud Storage both need billing enabled.

## 2. APIs

```bash
gcloud services enable storage.googleapis.com cloudkms.googleapis.com \
  secretmanager.googleapis.com --project="$PROJECT_ID"
```

Secret Manager is only for the example stacks (`EXTRA_APIS`).

## 3. State bucket

```bash
gcloud storage buckets create "gs://${STATE_BUCKET}" --project="$PROJECT_ID" \
  --location=US --uniform-bucket-level-access --public-access-prevention

cat > /tmp/lifecycle.json <<'EOF'
{
  "rule": [
    {"action": {"type": "Delete"}, "condition": {"isLive": false, "numNewerVersions": 10}},
    {"action": {"type": "Delete"}, "condition": {"isLive": false, "matchesSuffix": [".tflock"]}}
  ]
}
EOF
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning \
  --lifecycle-file=/tmp/lifecycle.json
```

- **Uniform bucket-level access** and **public access prevention**: only IAM
  controls access, and the bucket can never be made public.
- **Versioning**: every state write keeps the previous version. Those old
  versions are your restore points
  ([operations](operations.md#restore-an-older-state-version)).
- **Lifecycle rule 1**: keeps the 10 most recent versions of each state file,
  current one included (`STATE_VERSIONS_TO_KEEP`). Do not add a rule like
  `numNewerVersions: 1`, or `daysSinceNoncurrentTime` with a small value. Such
  a rule deletes the old versions right away, and versioning then gives you
  nothing to restore.
- **Lifecycle rule 2**: deletes old versions of the `.tflock` lock files. They
  have no value once the lock is released.
- **Soft delete** stays at the default 7 days, a second safety net for
  deleted objects.
- **No CSEK enforcement**: GCS can refuse objects that are not CSEK-encrypted
  (`--encryption-enforcement-file`). Do not turn that on for this bucket.
  Terraform writes its lock files with Google-managed encryption, so such a
  bucket rejects them (HTTP 412), and every `init` and `plan` fails.

## 4. Cloud KMS key

```bash
gcloud kms keyrings create sops --location=global --project="$PROJECT_ID"
gcloud kms keys create sops-key --keyring=sops --location=global \
  --purpose=encryption --project="$PROJECT_ID"
```

This key encrypts the SOPS files. It never leaves Google: SOPS asks KMS to
encrypt or decrypt each file's data key.

Key rings and keys cannot be deleted, only their key versions can be
destroyed, so choose the names on purpose. Never destroy a key version that
SOPS files still use: those files, and the CSEK in them, could no longer be
decrypted.

## 5. SOPS configuration

```bash
cat > .sops.yaml <<EOF
creation_rules:
  - gcp_kms: ${KMS_KEY_ID}
EOF
```

With a single rule that has no `path_regex`, every file you encrypt in the
repository uses the project's key.

## 6. State encryption key (CSEK)

```bash
head -c 32 /dev/urandom | base64 | tr -d '\n' |
  sops encrypt --filename-override terraform/secrets/encryption_key.txt \
    --output terraform/secrets/encryption_key.txt
```

- 32 random bytes form an AES-256 key. GCS expects it base64-encoded
  (44 characters).
- The key exists unencrypted only inside the pipe. Never print it, or it ends
  up in your terminal scrollback and shell history.
- `--filename-override` tells SOPS which `.sops.yaml` rule applies and which
  format to use. A `.txt` file is stored as a SOPS *binary* file:
  `{"data": "ENC[...]", "sops": {...}}`. Decrypting it returns the exact bytes
  you encrypted.

Check it without showing it:

```bash
sops decrypt terraform/secrets/encryption_key.txt | base64 -d | wc -c   # 32
```

The script never replaces an existing `encryption_key.txt`. A new key would
lock you out of every state the old one encrypted. To change keys, see
[rotating the CSEK](operations.md#rotate-the-csek).

## 7. Secrets

```bash
sops edit terraform/secrets/example.secrets.yaml
```

`sops edit` opens `$EDITOR` on the decrypted content and writes it back
encrypted; it creates the file when it does not exist. The bootstrap script
creates `example.secrets.yaml` with a random `db_password` for the example
stack.

## 8. Team access

Whoever creates the project owns it and needs nothing else. Each additional
person or group (`TERRAFORM_MEMBERS`) needs:

```bash
MEMBER=group:devops@example.com
gcloud kms keys add-iam-policy-binding sops-key --keyring=sops --location=global \
  --project="$PROJECT_ID" --member="$MEMBER" --role=roles/cloudkms.cryptoKeyEncrypterDecrypter
gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="$MEMBER" --role=roles/storage.objectAdmin
```

They also need permissions on the resources the stacks manage. Grant those
separately.

## 9. Commit

```bash
git add bootstrap/config.env .sops.yaml terraform/secrets
git commit -m "chore: bootstrap ${PROJECT_ID}"
```

Everything under `terraform/secrets/` is encrypted, so it is safe to commit.
`config.env` holds names and IDs, no secrets.

## 10. Initialize the Terraform state

```bash
cd terraform/foundation
make init
```

`make init` runs `../../scripts/init`, which:

1. decrypts the CSEK with SOPS into `.terraform/csek`, readable only by you
   (mode 0600);
2. writes `config.auto.tfvars` with `project_id`, `region` and `state_bucket`
   from `config.env`. Terraform loads that file automatically;
3. runs `terraform init -backend-config=bucket=$STATE_BUCKET`. The prefix
   comes from the stack's `backend.tf`.

`backend.tf` sets `encryption_key = ".terraform/csek"`. The gcs backend
accepts either the key or the path to a file that contains it, so Terraform
records only the path.

For a new prefix, the gcs backend takes the lock `<prefix>/default.tflock`,
writes an empty `<prefix>/default.tfstate` encrypted with the CSEK, and
releases the lock. Check the result:

```bash
gcloud storage objects describe "gs://${STATE_BUCKET}/foundation/default.tfstate" \
  --format='value(encryption_algorithm)'              # AES256: encrypted with a CSEK
gcloud storage cat "gs://${STATE_BUCKET}/foundation/default.tfstate"
                                                      # fails: Missing decryption key
```

From here on, use terraform directly:

```bash
terraform plan -out=tfplan
terraform apply tfplan && rm tfplan
```

### An existing local state

If the stack already has a local `terraform.tfstate`, add `backend.tf` and
run `make init ARGS="-migrate-state"`. Terraform copies the state into the
bucket, encrypted with the CSEK. Then delete the local file: it is
plaintext.
