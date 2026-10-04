variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Only dev and prod are supported."
  }
}
variable "backend_image_tag" {
  type    = string
  default = "bootstrap"
}
variable "deployment_revision" {
  type    = string
  default = null
}
variable "sdk_ci_principal_id" {
  type    = string
  default = null
}
variable "existing_ingest_keys" {
  type      = string
  sensitive = true
  default   = null
}
variable "existing_secrets_key" {
  type      = string
  sensitive = true
  default   = null
}
