output "bucket_name" {
  description = "Example bucket, used by the app stack."
  value       = google_storage_bucket.example.name
}

output "secret_id" {
  description = "Secret Manager secret that holds the example password."
  value       = google_secret_manager_secret.example.id
}
