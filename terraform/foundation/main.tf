# Example resources: replace them with your own.

resource "google_storage_bucket" "example" {
  name                        = "${var.project_id}-example"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Lets `make plan-destroy` remove the example even when it has objects.
  force_destroy = true
}
