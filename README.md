# terraform-example-project

Template for Terraform projects on Google Cloud in which:

- the Terraform state lives in a GCS bucket, encrypted with a
  **customer-supplied encryption key (CSEK)**;
- the CSEK and every other secret are committed to git, encrypted with
  **SOPS and Cloud KMS**;
- neither the CSEK nor the secrets are ever written to disk in plaintext:
  not in `.terraform/`, not in the state.

Create your repository with **Use this template**, then follow the
[quick start](#quick-start).

```
Cloud KMS key (sops-key)                      never leaves Google
        │ decrypts
        ▼
terraform/secrets/encryption_key.txt          committed, SOPS-encrypted
        │ scripts/tf: sops decrypt → GOOGLE_ENCRYPTION_KEY (process only)
        ▼
terraform (gcs backend) ──────────────►  gs://<STATE_BUCKET>/<stack>/default.tfstate
                                          encrypted by GCS with the CSEK
```

## Layout

```
bootstrap/
  bootstrap.sh          creates the project, APIs, bucket, KMS key, .sops.yaml and CSEK
  config.env.example    settings: copy it to config.env
scripts/
  tf                    terraform wrapper: puts the CSEK and the settings in the environment
terraform/
  common.mk             make targets shared by every stack
  secrets/              SOPS-encrypted files: the CSEK and your secrets
  foundation/           example stack: a bucket and a Secret Manager secret read from SOPS
  app/                  example stack: reads the foundation state
docs/
  bootstrap.md          every bootstrap step with its manual commands
  how-it-works.md       design, security model and caveats
  operations.md         reading and restoring state, rotating the CSEK, onboarding
```

## Requirements

- [gcloud](https://cloud.google.com/sdk/docs/install), logged in twice:
  `gcloud auth login` (for gcloud) and `gcloud auth application-default login`
  (for SOPS and Terraform).
- [SOPS](https://github.com/getsops/sops) 3.9 or later.
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.11 or later.
- bash and make.
- For the bootstrap: permission to create projects and link a billing account,
  or an existing project that you own.

## Quick start

```bash
cp bootstrap/config.env.example bootstrap/config.env
$EDITOR bootstrap/config.env            # project, billing account, names
bootstrap/bootstrap.sh                  # idempotent: safe to run again

git add bootstrap/config.env .sops.yaml terraform/secrets
git commit -m "chore: bootstrap my-project"

cd terraform/foundation
make init                               # creates the encrypted state
make plan                               # review it
make apply
cd ../app && make init plan             # then make apply
```

[docs/bootstrap.md](docs/bootstrap.md) explains each step and gives the manual
commands the script runs.

## Everyday use

From a stack directory (`terraform/<stack>`):

| Command | What it does |
|---------|--------------|
| `make init` | Initialize the backend and the providers |
| `make plan` | Plan into `./tfplan` |
| `make apply` | Apply `./tfplan`, then delete it (a plan file is plaintext) |
| `make plan-destroy` | Plan a destroy into `./tfplan`; review it, then `make apply` |
| `make output` | Show the outputs |
| `make clean` | Delete `.terraform/` and `./tfplan` |
| `../../scripts/tf <args>` | Any other terraform command: `state list`, `import`, … |

Do not run `terraform` directly: it would not have the CSEK. Against an
existing state it fails with `ResourceIsEncryptedWithCustomerEncryptionKey`;
against a new prefix, `init` would create an **unencrypted** state.

## Adding a stack

```bash
mkdir terraform/network
cp terraform/app/{Makefile,versions.tf,providers.tf,variables.tf} terraform/network/
cat > terraform/network/backend.tf <<'EOF'
terraform {
  backend "gcs" {
    prefix = "network" # unique per stack
  }
}
EOF
cd terraform/network && make init
```

Stacks must live at `terraform/<stack>`: `common.mk` calls `../../scripts/tf`.
To read another stack's outputs, copy `terraform/app/remote-state.tf`.

## Making it yours

- Delete the example stacks (`terraform/foundation`, `terraform/app`) and
  `terraform/secrets/example.secrets.yaml`, and drop
  `secretmanager.googleapis.com` from `EXTRA_APIS` if you do not use it.
- Add secrets with `sops edit terraform/secrets/<name>.secrets.yaml` and read
  them as in `terraform/foundation/secrets.tf`.
- Keep `bootstrap/config.env` committed: it is the source of truth for the
  names, and `scripts/tf` reads it.

## Tested

The whole flow was run end to end against a throwaway project:

- the bootstrap, twice (the second run changes nothing);
- `init`, `plan`, `apply` and destroy for both stacks;
- restoring an older state version;
- rotating the CSEK;
- the `TERRAFORM_MEMBERS` grants.

Versions used: Terraform 1.15.8, hashicorp/google 8.5.0, carlpett/sops 1.4.1,
SOPS 3.13.3 and gcloud 579. CI runs `terraform fmt`, `terraform validate` and
ShellCheck.

## License

[MIT](LICENSE)
