terraform {
  # State: gs://<STATE_BUCKET>/app/default.tfstate, encrypted with the state
  # CSEK. `make init` passes the bucket from bootstrap/config.env and writes
  # the key to .terraform/csek.
  backend "gcs" {
    prefix = "app"

    # A path, not the key: the gcs backend reads the key from this file, so
    # .terraform/terraform.tfstate and plan files only hold the path. Without
    # the file (no `make init` yet) terraform fails instead of writing an
    # unencrypted state.
    encryption_key = ".terraform/csek"
  }
}
