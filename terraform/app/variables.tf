variable "resource_group_name" {
  description = "Name of the pre-existing resource group for this environment (created by bootstrap as <resource-group-base-name>-<env>)."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev/test/prod). Used to locate the matching platform state key."
  type        = string
}

variable "workload" {
  description = "Short, lowercase, alphanumeric workload name used as the middle segment of every resource name (<abbrev>-<workload>-<env>). Must match the platform workload."
  type        = string
  default     = "webapp"
}

# Backend coordinates for the platform state, supplied by the workflow as TF_VAR_* so the
# terraform_remote_state data source can read the platform project's outputs.
variable "tf_backend_resource_group_name" {
  description = "Resource group holding the Terraform backend storage account."
  type        = string
}

variable "tf_backend_storage_account_name" {
  description = "Storage account holding the Terraform state."
  type        = string
}

variable "tf_backend_container_name" {
  description = "Blob container holding the Terraform state."
  type        = string
}
