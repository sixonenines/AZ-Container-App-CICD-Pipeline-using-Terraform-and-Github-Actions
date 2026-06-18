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

locals {
  # alias the platform project's outputs so references stay short
  platform = data.terraform_remote_state.platform.outputs
}

resource "azurerm_container_app" "ca" {
  name                         = "ca-${var.workload}-${var.environment}"
  container_app_environment_id = local.platform.container_app_environment_id
  resource_group_name          = data.azurerm_resource_group.rg.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [local.platform.user_assigned_identity_id]
  }

  registry {
    server   = local.platform.container_registry_login_server
    identity = local.platform.user_assigned_identity_id
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = var.project
      image  = "${local.platform.container_registry_login_server}/${var.project}@${var.image_digest}"
      cpu    = var.cpu
      memory = var.memory
    }
  }

  ingress {
    external_enabled = true
    target_port      = var.target_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}