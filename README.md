# terraform-example-project

Template for Terraform projects on Google Cloud in which:

- the Terraform state lives in a GCS bucket, encrypted with a
  **customer-supplied encryption key (CSEK)**;
- the CSEK is committed to git as `terraform/secrets/encryption_key.txt`,
  encrypted with **SOPS and Cloud KMS**, and each stack has a `.sops.yaml`
  that points SOPS at that KMS key;
- the CSEK never reaches the state: `make init` decrypts it into
  `.terraform/csek`, and Terraform only records that path;
- `make init` is the only step that needs make. After it, you run
  `terraform` directly: `terraform plan`, `terraform apply`,
  `terraform state list`…

Create your repository with **Use this template**, then follow the
[quick start](#quick-start).

```
Cloud KMS key (sops-key)                      never leaves Google
        │ decrypts
        ▼
terraform/secrets/encryption_key.txt          committed, SOPS-encrypted
        │ make init: sops decrypt
        ▼
terraform/<stack>/.terraform/csek             local, 0600, git-ignored
        │ backend "gcs" { encryption_key = ".terraform/csek" }
        ▼
terraform plan/apply ─────────────────►  gs://<STATE_BUCKET>/<stack>/default.tfstate
                                          encrypted by GCS with the CSEK
```

## Layout

```
bootstrap/
  bootstrap.sh            creates the GCP resources and the CSEK, fills in each .sops.yaml
  config.env.example      settings: copy it to config.env
scripts/
  init                    what `make init` runs
terraform/
  common.mk               the `make init` target shared by every stack
  secrets/
    encryption_key.txt    the state CSEK, SOPS-encrypted (created by the bootstrap)
  foundation/             example stack: a bucket
    .sops.yaml            which Cloud KMS key SOPS uses from this directory
    Makefile              include ../common.mk
    backend.tf            prefix + encryption_key = ".terraform/csek"
    variables.tf, versions.tf, providers.tf, main.tf, outputs.tf
  app/                    example stack: reads the foundation state (same files)
docs/
  bootstrap.md            how to build all of this, step by step, by hand
  how-it-works.md         design, security model and caveats
  operations.md           reading and restoring state, rotating the CSEK, onboarding
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
terraform plan                          # review it
terraform apply                         # shows the plan again and asks
cd ../app && make init                  # then terraform plan / apply
```

[docs/bootstrap.md](docs/bootstrap.md) builds the same thing by hand, one step
at a time: the GCP resources, `terraform/secrets/encryption_key.txt`, the
`.sops.yaml` of each stack and the stack files.

## Everyday use

In each stack directory (`terraform/<stack>`), run `make init` once. After
that, use terraform as usual. Run `make init` again after:

- cloning the repository or running `make clean`;
- pulling a new CSEK (after a [rotation](docs/operations.md#rotate-the-csek));
- editing `bootstrap/config.env`.

`make init` does three things:

1. writes the decrypted CSEK to `.terraform/csek` (mode 0600);
2. writes `config.auto.tfvars` (`project_id`, `region`, `state_bucket`) from
   `bootstrap/config.env`;
3. runs `terraform init -backend-config=bucket=$STATE_BUCKET`. Pass extra
   options with `make init ARGS="-upgrade"`.

`backend.tf` points `encryption_key` at `.terraform/csek`. Until `make init`
creates that file, terraform stops with
`Error decoding encryption key: illegal base64 data`, so it cannot write an
unencrypted state by mistake.

## Adding a stack

```bash
mkdir terraform/network
cp terraform/app/{.sops.yaml,Makefile,versions.tf,providers.tf,variables.tf} terraform/network/
cat > terraform/network/backend.tf <<'EOF'
terraform {
  backend "gcs" {
    prefix         = "network" # unique per stack
    encryption_key = ".terraform/csek"
  }
}
EOF
cd terraform/network && make init
```

Stacks must live at `terraform/<stack>`: `common.mk` calls `../../scripts/init`.
To read another stack's outputs, copy `terraform/app/remote-state.tf`.

## Making it yours

- Replace the example stacks (`terraform/foundation`, `terraform/app`) with
  your own. Keep the `.sops.yaml`, `Makefile`, `backend.tf` and
  `variables.tf` pattern.
- If a stack needs its own secrets, see
  [secrets in a stack](docs/how-it-works.md#secrets-in-a-stack).
- Keep `bootstrap/config.env` committed: it is the source of truth for the
  names, and `make init` reads it.

## Tested

The whole flow was run end to end against throwaway projects:

- the bootstrap, twice (the second run changes nothing), including the KMS
  key in each stack's `.sops.yaml`;
- `make init`, then plain `terraform plan`, `apply` and destroy, for both
  stacks;
- `terraform init` without `make init` (it fails and writes nothing);
- restoring an older state version;
- rotating the CSEK with the commands in `docs/operations.md`;
- adding `terraform/secrets/<name>.secrets.yaml` from a stack directory;
- the `TERRAFORM_MEMBERS` grants.

The CSEK never showed up in `.terraform/terraform.tfstate` or in a state:
only `.terraform/csek` holds it. Versions used: Terraform 1.15.8,
hashicorp/google 8.5.0, SOPS 3.13.3 and gcloud 579. CI runs `terraform fmt`,
`terraform validate` and ShellCheck.

## License

[MIT](LICENSE)
