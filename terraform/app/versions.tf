terraform {
  # 1.11 adds write-only arguments, which keep secrets out of the state
  # (docs/how-it-works.md).
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
}
