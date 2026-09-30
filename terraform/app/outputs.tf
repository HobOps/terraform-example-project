output "object_url" {
  description = "Object written by this stack."
  value       = "gs://${google_storage_bucket_object.hello.bucket}/${google_storage_bucket_object.hello.name}"
}
