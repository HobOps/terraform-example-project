terraform {
  # State: gs://<STATE_BUCKET>/app/default.tfstate (see foundation/backend.tf).
  backend "gcs" {
    prefix = "app"
  }
}
