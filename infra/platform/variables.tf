variable "resource_group_name" {
  description = "Name of the pre-existing resource group for this environment (created by bootstrap as <resource-group-base-name>-<env>)."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev/test/prod). Suffixed onto resource names so each env is independently named."
  type        = string
}

variable "workload" {
  description = "Short, lowercase, alphanumeric workload name used as the middle segment of every resource name (<abbrev>-<workload>-<env>)."
  type        = string
  default     = "webapp"
}

# Name of the shared registry (created by bootstrap.sh), used to derive the login
# server the app pulls from. Supplied by the workflows as TF_VAR_tf_shared_acr_name
# from the SHARED_ACR_NAME GitHub variable.
variable "tf_shared_acr_name" {
  description = "Name of the shared Azure Container Registry."
  type        = string
}
