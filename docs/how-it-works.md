# How it works

## Three keys

| Key | Where it lives | What it protects |
|-----|----------------|------------------|
| Cloud KMS key `sops-key` | Inside Cloud KMS; it never leaves Google | The data key of every SOPS file |
| State CSEK (AES-256) | `terraform/secrets/encryption_key.txt`, SOPS-encrypted, plus a decrypted copy in each initialized stack at `.terraform/csek` | The Terraform state objects in GCS |
| SOPS data keys | Inside each SOPS file, encrypted by KMS | That file's values |

To read a state file you need two permissions: read access to the bucket and
decrypt access to the KMS key. The KMS permission is what lets you obtain the
CSEK. Losing either the KMS key or `encryption_key.txt` means losing the state.

## What a CSEK does

When you pass a customer-supplied encryption key, GCS encrypts the object at
rest with it and keeps only a SHA-256 hash of the key. Every read and write
must send the key again (over TLS). Without it:

- Terraform fails with `ResourceIsEncryptedWithCustomerEncryptionKey`.
- gcloud fails with `Missing decryption key with SHA256 hash …`.
- `gcloud storage objects describe` shows `encryption_algorithm: AES256`.

This is not client-side encryption: GCS does the encrypting, with your key.
What it adds over Google-managed encryption is a second access factor, since
read access to the bucket is not enough on its own.

### Why not CMEK (`kms_encryption_key`)?

The gcs backend can also encrypt the state with a Cloud KMS key (CMEK). Then
there is no key to distribute, but the Cloud Storage service agent does the
decrypting. Anyone with read access to the bucket can read the state, so
bucket IAM is your only control. The CSEK keeps KMS access as a required
second factor. The price is that you have to guard it and rotate it yourself.

## Design decisions

### The CSEK is a file, and Terraform only knows its path

The gcs backend's `encryption_key` accepts either the key itself or the path
to a file that contains it. There are three ways to give Terraform the key:

| Option | Plain `terraform` works after `init` | Where the key ends up |
|--------|:---:|------------------------|
| `terraform init -backend-config="encryption_key=<key>"` | yes | `.terraform/terraform.tfstate`, and any plan file you save |
| `GOOGLE_ENCRYPTION_KEY` in the environment | no: every command needs a wrapper | Only the process environment |
| **`encryption_key = ".terraform/csek"` in `backend.tf`** (this template) | yes | Only `.terraform/csek` (mode 0600, git-ignored) |

With the path, the result is:

- `.terraform/terraform.tfstate` and the states record `.terraform/csek`,
  never the key. This was checked in the end-to-end test.
- **It fails closed.** Without the file, the backend treats the string
  `.terraform/csek` as the key itself, and it is not valid base64. Plain
  `terraform init` stops with
  `Error decoding encryption key: illegal base64 data at input byte 0` and
  writes nothing. It never creates an unencrypted state.
- **Rotating is simple.** After a
  [CSEK rotation](operations.md#rotate-the-csek), `make init` rewrites the
  file. The backend configuration, which is just the path, does not change,
  so no `-reconfigure` is needed.

The price is that the key sits on disk in every initialized stack, like it
does with `-backend-config`. `make clean` deletes it.

### Secrets in a stack

Secrets live next to the CSEK in `terraform/secrets/`, as
`<name>.secrets.yaml`. Create or edit one from the stack directory, so SOPS
uses that stack's `.sops.yaml` (rule `\.secrets\.yaml$`):

```bash
cd terraform/<stack>
sops edit ../secrets/app.secrets.yaml
```

To use a secret in Terraform, do not read it with `data "sops_file"`. A data
source stores every decrypted value in the state, including values marked
sensitive: `sensitive` only hides them from the CLI output. Loading the CSEK
that way would put the state's own key inside it. Use these instead:

- `ephemeral "sops_file"` (provider `carlpett/sops`): ephemeral resources are
  never written to the state;
- write-only arguments, such as `secret_data_wo` in
  `google_secret_manager_secret_version`: sent to the API, never stored.
  Terraform cannot compare them, so a companion argument
  (`secret_data_wo_version`) signals a change.

```hcl
ephemeral "sops_file" "app" {
  source_file = "../secrets/app.secrets.yaml"
}

resource "google_secret_manager_secret_version" "db_password" {
  secret                 = google_secret_manager_secret.db_password.id
  secret_data_wo         = ephemeral.sops_file.app.data["db_password"]
  secret_data_wo_version = 1 # bump to push a new value
}
```

This was checked end to end: the value reached Secret Manager and never
appeared in the state.

Ephemeral values can only go where nothing is persisted: provider settings,
write-only arguments, other ephemeral resources, ephemeral variables and
outputs, and locals built from them. If a resource has no write-only variant
of an argument, whatever you pass to it ends up in the state. The CSEK still
protects it there.

### Reading another stack's state

`terraform/app/remote-state.tf` sets `encryption_key = ".terraform/csek"`,
the same path as `backend.tf`. The `terraform_remote_state` data source is
saved in the state, but it only holds the path. All stacks in one bucket
share one CSEK.

### Versions you can restore

Versioning keeps every earlier version of the state. The lifecycle rule
deletes a version only once `STATE_VERSIONS_TO_KEEP` newer ones exist. Old
versions of lock files go away as soon as the lock is released.

### Locks are not encrypted with the CSEK

The gcs backend writes `<prefix>/default.tflock` with Google-managed
encryption. The file only holds metadata: who, which operation, when.
Because of this, the bucket cannot be set to accept only CSEK objects
([bootstrap](bootstrap.md#3-state-bucket)).

## What is in plaintext, and where

| Where | Contents | Handling |
|-------|----------|----------|
| `terraform/<stack>/.terraform/csek` | The CSEK | Mode 0600, git-ignored; `make clean` deletes it |
| Output of `terraform state pull` | The whole state | Do not redirect it to files |
| `errored.tfstate` | The whole state, when an apply could not save it | [Push it back and delete it](operations.md#an-apply-could-not-save-the-state-erroredtfstate) |
| `config.auto.tfvars` | Project, region and bucket names | Git-ignored; written by `make init` |
| `<prefix>/default.tflock` | Lock metadata | Not sensitive |
