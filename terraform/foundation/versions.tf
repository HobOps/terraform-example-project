terraform {
  # Ephemeral resources (1.10) and write-only arguments (1.11) keep the
  # SOPS secrets out of the state.
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
  }
}
