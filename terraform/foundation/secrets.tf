# Stores a value from terraform/secrets/example.secrets.yaml (SOPS + Cloud
# KMS) in Secret Manager without writing it to the state or the plan:
#   - ephemeral resources are never persisted;
#   - secret_data_wo is write-only: sent to the API, never stored.
# A `data "sops_file"` would put every decrypted value in the state instead.

ephemeral "sops_file" "example" {
  source_file = "../secrets/example.secrets.yaml"
}

resource "google_secret_manager_secret" "example" {
  secret_id = "example-db-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "example" {
  secret         = google_secret_manager_secret.example.id
  secret_data_wo = ephemeral.sops_file.example.data["db_password"]
  # Terraform cannot diff a write-only value: bump this to push a new one.
  secret_data_wo_version = 1
}
