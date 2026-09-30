# Reads the foundation stack's outputs from its encrypted state.
#
# encryption_key is the same path as in backend.tf, so this stack's state
# only stores the path. Never load the key itself into a data source (e.g.
# data "sops_file"): data sources are saved in the state.
data "terraform_remote_state" "foundation" {
  backend = "gcs"

  config = {
    bucket         = var.state_bucket
    prefix         = "foundation"
    encryption_key = ".terraform/csek"
  }
}
