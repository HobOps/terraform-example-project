# Operations

Run the commands from the repository root unless a step says otherwise.
`STATE_BUCKET` is the value from `bootstrap/config.env`:

```bash
source bootstrap/config.env
```

## Give the CSEK to gcloud

`gcloud storage` reads customer-supplied keys from a YAML "key store" file
(`storage/key_store_path`):

```yaml
encryption_key: <key used to write objects; also tried when reading>
decryption_keys:
  - <extra keys tried when reading>
```

Build that file with process substitution, so the key never lands on disk
and never appears in the command line:

```bash
keystore() { printf 'encryption_key: %s\n' "$(sops decrypt terraform/secrets/encryption_key.txt)"; }
CLOUDSDK_STORAGE_KEY_STORE_PATH=<(keystore) gcloud storage cat "gs://${STATE_BUCKET}/foundation/default.tfstate"
```

From an initialized stack directory, `$(cat .terraform/csek)` works as well.

These replace `gsutil -o 'GSUtil:encryption_key=…'`: gsutil is deprecated,
and that flag puts the key in the process arguments and the shell history.
Setting `CLOUDSDK_STORAGE_ENCRYPTION_KEY` or
`CLOUDSDK_STORAGE_DECRYPTION_KEYS` does not work, because those properties do
not exist.

## Read the state

With Terraform, from an initialized stack directory:

```bash
terraform state list
terraform state pull | jq '.serial, .lineage'
```

With gcloud, see [above](#give-the-csek-to-gcloud).

## Restore an older state version

```bash
gcloud storage ls -a -l "gs://${STATE_BUCKET}/foundation/default.tfstate"
# pick a generation, e.g. 1790728537546772
CLOUDSDK_STORAGE_KEY_STORE_PATH=<(keystore) gcloud storage cp \
  "gs://${STATE_BUCKET}/foundation/default.tfstate#1790728537546772" \
  "gs://${STATE_BUCKET}/foundation/default.tfstate"
(cd terraform/foundation && terraform plan)
```

The key store's `encryption_key` does two jobs here: it decrypts the old
version and encrypts the new current version. The restore adds a version; it
does not delete any, so you can go back again the same way. Make sure nobody
runs Terraform on that stack in the meantime.

Versions written before a [CSEK rotation](#rotate-the-csek) need the old key.
Add it under `decryption_keys`.

## An apply could not save the state (`errored.tfstate`)

If `apply` changes resources but cannot write the state to GCS, Terraform
writes `errored.tfstate` in the stack directory. That file is a plaintext
copy of the whole state. Push it back as soon as the problem is fixed, then
delete it:

```bash
cd terraform/<stack>
terraform state push errored.tfstate
rm errored.tfstate
terraform plan   # should show no unexpected changes
```

## Rotate the CSEK

Pick a moment when nobody else is running Terraform: the rotation does not
take the state locks. Run it from any stack directory, because step 3 needs
that stack's `.sops.yaml` (rule `encryption_key\.txt$`).

```bash
cd terraform/foundation
source ../../bootstrap/config.env
old="$(sops decrypt ../secrets/encryption_key.txt)"
new="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"

# 1. Keep the old key: the older versions of the state stay encrypted with it.
cp ../secrets/encryption_key.txt ../secrets/encryption_key.previous.txt

# 2. Re-encrypt the current state of every stack with the new key.
CLOUDSDK_STORAGE_KEY_STORE_PATH=<(printf 'decryption_keys:\n  - %s\n' "$old") \
  gcloud storage objects update "gs://${STATE_BUCKET}/**.tfstate" --encryption-key="$new"

# 3. Store the new key. SOPS takes the KMS key from ./.sops.yaml.
printf '%s' "$new" | sops encrypt --filename-override ../secrets/encryption_key.txt \
  --output ../secrets/encryption_key.txt /dev/stdin
unset old new

# 4. Refresh .terraform/csek in every stack and check it, then commit both files.
for stack in ../*/; do
  [ -f "${stack}backend.tf" ] && (cd "$stack" && make init >/dev/null && terraform plan)
done                                    # No changes
```

- The new key has to go in the `--encryption-key` flag. Only that flag makes
  `objects update` re-encrypt the objects. With only a key store, gcloud
  patches the metadata and the objects keep the old key. The flag exposes the
  new key in the process arguments while the command runs.
- Check the result: `gcloud storage objects describe <object>
  --format='value(decryption_key_hash_sha256)'` should show a new hash for
  every current state object.
- Everyone else runs `make init` in each stack after pulling the new
  `encryption_key.txt`. Until they do, their `.terraform/csek` holds the old
  key and terraform fails with `Failed to open state file … HTTP response
  code 400`. No `-reconfigure` is needed: the backend configuration is still
  the same path.
- Delete `encryption_key.previous.txt` once all versions encrypted with it are
  gone: that is after `STATE_VERSIONS_TO_KEEP` writes on every stack, plus the
  7 days of soft delete.

## Rotate or change the KMS key

- **Automatic rotation** of `sops-key`
  (`gcloud kms keys update sops-key … --rotation-period=90d --next-rotation-time=…`)
  needs no other change. SOPS files record which key version encrypted them,
  and KMS keeps the older versions for decrypting.
- **Moving to a different key**: change `gcp_kms` in every stack's
  `.sops.yaml`. Then, from a stack directory, run `sops updatekeys <file>` on
  every file in `../secrets/`.

## Onboard someone

Add them to `TERRAFORM_MEMBERS` in `bootstrap/config.env`. Run
`bootstrap/bootstrap.sh` again: it only adds the missing grants. Commit the
change. Also grant them permissions on the resources the stacks manage.

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Error decoding encryption key: illegal base64 data at input byte 0` | `.terraform/csek` does not exist yet, or `make clean` deleted it | `make init` |
| `Failed to open state file … HTTP response code 400` | `.terraform/csek` has a different key than the state (someone rotated it) | Pull, then `make init` |
| `ResourceIsEncryptedWithCustomerEncryptionKey` | The backend got no key at all (`encryption_key` missing from `backend.tf`) | Add `encryption_key = ".terraform/csek"`, then `make init` |
| Terraform asks for `project_id`, or `No value for required variable` | `config.auto.tfvars` is missing | `make init` |
| `Missing decryption key with SHA256 hash …` | gcloud has no key, or the object uses another key (a version from before a rotation) | Pass a [key store](#give-the-csek-to-gcloud); add the previous key under `decryption_keys` |
| SOPS: `config file not found, or has no creation rules` | You ran `sops encrypt` or `sops edit` outside a stack directory | `cd terraform/<stack>` first; that directory has the `.sops.yaml` |
| SOPS: `no matching creation rules found` | The file name matches no rule in the stack's `.sops.yaml` | Name it `encryption_key.txt` or `<name>.secrets.yaml`, or add a rule |
| SOPS: `no master key was able to decrypt the file` | No ADC, an expired session, or no KMS permission | `gcloud auth application-default login`; check `roles/cloudkms.cryptoKeyEncrypterDecrypter` |
| `does not decrypt to a 32-byte key` | `encryption_key.txt` has something other than a base64 AES-256 key | Restore it from git |
| `Error 412 … encryption enforcement` | The bucket rejects Google-managed encryption, which lock files use | Set every `restrictionMode` to `NotRestricted` |
