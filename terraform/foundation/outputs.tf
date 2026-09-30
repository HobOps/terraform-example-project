output "bucket_name" {
  description = "Example bucket, used by the app stack."
  value       = google_storage_bucket.example.name
}
