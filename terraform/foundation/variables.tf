# scripts/tf sets these from bootstrap/config.env.

variable "project_id" {
  description = "GCP project for the resources."
  type        = string
}

variable "region" {
  description = "Default region for the resources."
  type        = string
}
