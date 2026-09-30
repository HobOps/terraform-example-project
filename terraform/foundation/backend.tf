terraform {
  # State: gs://<STATE_BUCKET>/foundation/default.tfstate, encrypted with the
  # CSEK. scripts/tf passes the bucket at init and the key through
  # GOOGLE_ENCRYPTION_KEY, so neither is written here.
  backend "gcs" {
    prefix = "foundation"
  }
}
