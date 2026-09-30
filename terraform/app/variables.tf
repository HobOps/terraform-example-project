# `make init` sets these in config.auto.tfvars from bootstrap/config.env.
# Every stack declares all three so that file never sets an undeclared one.

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
