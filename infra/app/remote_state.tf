## Terraform suggests that instead of reading the whole state file, push the info required to a different remote storage and read that.
# Its probably still fine for this project, but I should still look into it.

data "terraform_remote_state" "platform" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tf_backend_resource_group_name
    storage_account_name = var.tf_backend_storage_account_name
    container_name       = var.tf_backend_container_name
    key                  = "platform.${var.environment}.terraform.tfstate"
    use_oidc             = true
    use_azuread_auth     = true
  }
}
