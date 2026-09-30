# Example resource that depends on another stack: replace it with your own.

resource "google_storage_bucket_object" "hello" {
  bucket       = data.terraform_remote_state.foundation.outputs.bucket_name
  name         = "hello.txt"
  content      = "Written by the app stack.\n"
  content_type = "text/plain"
}
