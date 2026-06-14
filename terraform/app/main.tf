terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.1"
    }
  }
}

terraform {
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.ContainerRegistry",
    "Microsoft.OperationalInsights",
  ]
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

resource "azurerm_container_app" "ca" {
  name                         = "ca-${var.workload}-${var.environment}"
  container_app_environment_id = data.terraform_remote_state.platform.outputs.container_app_environment_id
  resource_group_name          = data.azurerm_resource_group.rg.name
  revision_mode                = "Single"

  template {
    container {
      name   = "examplecontainerapp"
      image  = "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [data.terraform_remote_state.platform.outputs.user_assigned_identity_id]
  }
  # Registry (using ACR login server + the identity above), ingress, cors, maybe key vault still required.
  # ACR login server is available as:
  #   data.terraform_remote_state.platform.outputs.container_registry_login_server
}