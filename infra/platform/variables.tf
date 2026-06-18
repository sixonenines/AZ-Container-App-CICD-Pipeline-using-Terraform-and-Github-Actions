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

# Login server of the shared registry the app pulls from, resolved and published by
# bootstrap.sh and supplied by the workflows as TF_VAR_tf_shared_acr_login_server
# from the SHARED_ACR_LOGIN_SERVER GitHub variable.
variable "tf_shared_acr_login_server" {
  description = "Login server of the shared Azure Container Registry (e.g. <name>.azurecr.io)."
  type        = string
}
