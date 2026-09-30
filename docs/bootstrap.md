# Bootstrap

This guide builds a project from scratch: first the Google Cloud resources
the Terraform backend needs, then the files in the repository, and finally
the encrypted state. `bootstrap/bootstrap.sh` does steps 1 to 6 (plus step 9
when `TERRAFORM_MEMBERS` is set) from `bootstrap/config.env`. The commands
below are exactly what it runs: use them to build everything by hand, or to
see what the script will do.

## What you are building

```
bootstrap/
  config.env                 names and IDs used by bootstrap.sh and make init
terraform/
  common.mk                  the `make init` target
  secrets/
    encryption_key.txt       the state CSEK, SOPS-encrypted with Cloud KMS
  <stack>/                   one directory per Terraform root module
    .sops.yaml               which Cloud KMS key SOPS uses from this directory
    Makefile                 include ../common.mk
    backend.tf               gcs backend: prefix + encryption_key = ".terraform/csek"
    variables.tf             project_id, region, state_bucket
    versions.tf, providers.tf, main.tf, ...

gs://<STATE_BUCKET>/<stack>/default.tfstate   one state per stack, encrypted with the CSEK
```

The examples use these variables. They match `bootstrap/config.env`:

```bash
PROJECT_ID=my-project-tf-1234
ORG_ID=123456789012                  # or FOLDER_ID, or neither
BILLING_ACCOUNT=0X0X0X-0X0X0X-0X0X0X
STATE_BUCKET=${PROJECT_ID}-tfstate
KMS_KEY_ID=projects/${PROJECT_ID}/locations/global/keyRings/sops/cryptoKeys/sops-key
```

## Part 1: Google Cloud

### 0. Log in

```bash
gcloud auth login                        # credentials for gcloud
gcloud auth application-default login    # credentials for SOPS and Terraform (ADC)
```

If you would rather not change your global ADC, you can give each command an
access token instead:
`export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`. gcloud,
SOPS, the gcs backend and the google provider accept it.

### 1. Project and billing

```bash
gcloud projects create "$PROJECT_ID" --organization="$ORG_ID"   # or --folder=...
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
```

Find your billing account ID with `gcloud billing accounts list`. Cloud KMS
and Cloud Storage both need billing enabled.

### 2. APIs

```bash
gcloud services enable storage.googleapis.com cloudkms.googleapis.com --project="$PROJECT_ID"
```

Add whatever your stacks use to `EXTRA_APIS`.

### 3. State bucket

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

### 4. Cloud KMS key

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

## Part 2: The repository

### 5. The state CSEK: `terraform/secrets/encryption_key.txt`

```bash
mkdir -p terraform/secrets
head -c 32 /dev/urandom | base64 | tr -d '\n' |
  sops encrypt --gcp-kms "$KMS_KEY_ID" \
    --filename-override terraform/secrets/encryption_key.txt \
    --output terraform/secrets/encryption_key.txt /dev/stdin
```

- 32 random bytes form an AES-256 key. GCS expects it base64-encoded
  (44 characters).
- The key exists unencrypted only inside the pipe. Never print it, or it ends
  up in your terminal scrollback and shell history.
- `--gcp-kms` names the KMS key directly, so this step does not need a
  `.sops.yaml`. `--filename-override` sets the format: a `.txt` file is stored
  as a SOPS *binary* file, `{"data": "ENC[...]", "sops": {...}}`. Decrypting it
  returns the exact bytes you encrypted.
- `/dev/stdin` names the input explicitly. SOPS 3.9 does not read the pipe on
  its own (`Error: no file specified`); newer versions accept both forms.

Check it without showing it:

```bash
sops decrypt terraform/secrets/encryption_key.txt | base64 -d | wc -c   # 32
```

The script never replaces an existing `encryption_key.txt`. A new key would
lock you out of every state the old one encrypted. To change keys, see
[rotating the CSEK](operations.md#rotate-the-csek).

### 6. A `.sops.yaml` in each stack

SOPS reads `.sops.yaml` from the directory you run it in, or the closest
parent that has one. The file decides which key encrypts a new file, based
on the file's path. Put one in every stack directory:

```yaml
# terraform/<stack>/.sops.yaml
creation_rules:
  # The state CSEK: ../secrets/encryption_key.txt
  - path_regex: encryption_key\.txt$
    gcp_kms: projects/my-project-tf-1234/locations/global/keyRings/sops/cryptoKeys/sops-key
  # Other secrets, e.g. ../secrets/app.secrets.yaml
  - path_regex: \.secrets\.yaml$
    gcp_kms: projects/my-project-tf-1234/locations/global/keyRings/sops/cryptoKeys/sops-key
```

- **Decrypting** never needs it: each SOPS file records its own keys. That
  means `make init` works without it.
- **Encrypting** does. From a stack directory you can rotate the CSEK
  (`../secrets/encryption_key.txt`) or add a secret such as
  `../secrets/app.secrets.yaml`. SOPS refuses any other file name with
  `no matching creation rules found`. Run it from the repository root, where
  there is no `.sops.yaml`, and it fails with `config file not found, or has no
  creation rules`.

The template's stacks ship with a placeholder key. `bootstrap.sh` fills in
`KMS_KEY_ID` in every `terraform/*/.sops.yaml` that still has it.

### 7. The stack files

Each stack is a directory under `terraform/`, with these files next to your
`.tf` code (see `terraform/foundation`):

- **`Makefile`**: one line, `include ../common.mk`, which adds `make init`.
- **`backend.tf`**:

  ```hcl
  terraform {
    backend "gcs" {
      prefix         = "<stack>"          # unique per stack
      encryption_key = ".terraform/csek"  # a path, written by make init
    }
  }
  ```

  The bucket is left out on purpose. `make init` passes it from `config.env`.
- **`variables.tf`**: declares `project_id`, `region` and `state_bucket`.
  `make init` sets them in `config.auto.tfvars`.

### 8. Commit

```bash
git add bootstrap/config.env terraform
git commit -m "chore: bootstrap ${PROJECT_ID}"
```

`encryption_key.txt` is encrypted, so it is safe to commit. `config.env`
holds names and IDs, no secrets. `.gitignore` keeps out `.terraform/` (and
the decrypted CSEK in it), `config.auto.tfvars`, state files and plan files.

### 9. Team access

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

## Part 3: Initialize the Terraform state

```bash
cd terraform/foundation
make init
```

`make init` runs `../../scripts/init`, which:

1. decrypts `../secrets/encryption_key.txt` into `.terraform/csek`, readable
   only by you (mode 0600);
2. writes `config.auto.tfvars` with `project_id`, `region` and `state_bucket`
   from `config.env`. Terraform loads that file automatically;
3. runs `terraform init -backend-config=bucket=$STATE_BUCKET`.

The gcs backend accepts either the key or the path to a file that contains
it. `backend.tf` gives it the path, so Terraform records only the path.

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
terraform plan
terraform apply
```

### An existing local state

If the stack already has a local `terraform.tfstate`, add `backend.tf` and
run `make init ARGS="-migrate-state"`. Terraform copies the state into the
bucket, encrypted with the CSEK. Then delete the local file: it is
plaintext.
