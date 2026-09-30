# Reads the foundation stack's outputs from its encrypted state.
#
# There is no encryption_key here on purpose: the gcs backend falls back to
# GOOGLE_ENCRYPTION_KEY, which scripts/tf exports. Loading the key through a
# data source (e.g. data "sops_file") would store it in this stack's state.
data "terraform_remote_state" "foundation" {
  backend = "gcs"

  config = {
    bucket = var.state_bucket
    prefix = "foundation"
  }
}
