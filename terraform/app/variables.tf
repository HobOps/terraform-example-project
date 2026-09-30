# scripts/tf sets these from bootstrap/config.env.

variable "project_id" {
  description = "GCP project for the resources."
  type        = string
}

variable "region" {
  description = "Default region for the resources."
  type        = string
}

variable "state_bucket" {
  description = "Bucket that holds the Terraform state of every stack."
  type        = string
}
