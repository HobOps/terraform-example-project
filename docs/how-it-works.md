# How it works

## Three keys

| Key | Where it lives | What it protects |
|-----|----------------|------------------|
| Cloud KMS key `sops-key` | Inside Cloud KMS; it never leaves Google | The data key of every SOPS file |
| State CSEK (AES-256) | `terraform/secrets/encryption_key.txt`, SOPS-encrypted | The Terraform state objects in GCS |
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

### The CSEK goes through the environment, not `-backend-config`

`terraform init -backend-config="encryption_key=…"` works, but Terraform then
saves the whole backend configuration in `.terraform/terraform.tfstate`, and
the key is included, in plaintext. From then on only `.gitignore` protects
it.

`scripts/tf` exports `GOOGLE_ENCRYPTION_KEY` instead. The gcs backend reads it
when `encryption_key` is not set, and never saves it. The result:

- `.terraform/terraform.tfstate` holds only `bucket` and `prefix`;
- the key exists only while a terraform command is running;
- after a [CSEK rotation](operations.md#rotate-the-csek) nobody has to run
  `init` again.

### The wrapper refuses to run without a key

If `GOOGLE_ENCRYPTION_KEY` is empty, `init` on a new prefix writes the first
state with Google-managed encryption. `scripts/tf` stops instead: it stops if
SOPS cannot decrypt the file (for example, because you have no KMS
permission), and it stops if the result is not 32 bytes.

### Secrets never reach the state

A `data "sops_file"` stores every decrypted value in the state. That includes
values marked sensitive: `sensitive` only hides them from the CLI output. If
you load the CSEK that way, the state contains its own key. Any plaintext
copy of that state then carries the key with it: a `state pull` redirected to
a file, an `errored.tfstate`, a backup.

The example stack uses these instead:

- `ephemeral "sops_file"`: ephemeral resources are never written to the
  state or to the plan;
- write-only arguments such as `secret_data_wo` in
  `google_secret_manager_secret_version`: they are sent to the API and never
  stored. Terraform cannot compare them, so a companion argument
  (`secret_data_wo_version`) signals a change.

In the end-to-end test, neither the password nor the CSEK appeared in either
stack's state.

Ephemeral values can only go where nothing is persisted: provider settings,
write-only arguments, other ephemeral resources, ephemeral variables and
outputs, and locals built from them. If a resource has no write-only variant
of an argument, whatever you pass to it ends up in the state. The CSEK still
protects it there.

### Reading another stack's state

`terraform/app/remote-state.tf` does not set `encryption_key`. The
`terraform_remote_state` data source uses the same gcs backend code, so it
also falls back to `GOOGLE_ENCRYPTION_KEY`. All stacks in one bucket share
one CSEK.

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
| `tfplan` | The plan, including state values | Git-ignored; `make apply` deletes it |
| Output of `scripts/tf state pull` | The whole state | Do not redirect it to files |
| `errored.tfstate` | The whole state, when an apply could not save it | [Push it back and delete it](operations.md#an-apply-could-not-save-the-state-erroredtfstate) |
| The `terraform` process environment | The CSEK | Only while the command runs |
| `<prefix>/default.tflock` | Lock metadata | Not sensitive |
