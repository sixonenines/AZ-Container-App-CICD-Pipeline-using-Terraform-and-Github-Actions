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
  name_suffix = "${var.workload}-${var.environment}"
}

# The runtime identity the Container App uses to pull images. Created by
# bootstrap.sh (which also grants it AcrPull on the shared registry); read here by
# name so this stack needs no rights over the shared registry's access control.
data "azurerm_user_assigned_identity" "uami" {
  name                = "id-${local.name_suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-${local.name_suffix}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "cae" {
  name                       = "cae-${local.name_suffix}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
}

