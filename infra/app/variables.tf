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

# --- Container app runtime configuration ---

variable "project" {
  description = "Image repository name in ACR and the container name (<acr-login-server>/<project>@<image_digest>)."
  type        = string
  default     = "webapp"
}

variable "image_digest" {
  description = "Immutable digest of the image to deploy, e.g. sha256:abc123... Deploying by digest (not a tag) guarantees the exact bytes built and tested are what runs. Supplied by the build/promote workflows."
  type        = string

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "image_digest must be a full image digest of the form sha256:<64 hex chars>."
  }
}

variable "cpu" {
  description = "vCPU allocated to the container."
  type        = number
  default     = 0.25
}

variable "memory" {
  description = "Memory allocated to the container (must pair validly with cpu, e.g. 0.25 vCPU -> 0.5Gi)."
  type        = string
  default     = "0.5Gi"
}

variable "min_replicas" {
  description = "Minimum replicas. 0 enables scale-to-zero so there is no standing compute cost when idle."
  type        = number
  default     = 0
}

variable "max_replicas" {
  description = "Maximum replicas the app can scale out to."
  type        = number
  default     = 1
}

variable "target_port" {
  description = "Port the container listens on, exposed by ingress."
  type        = number
  default     = 8080
}
