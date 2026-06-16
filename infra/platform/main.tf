terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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


resource "random_string" "acr" {
  length  = 6
  special = false
  upper   = false
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

resource "azurerm_container_registry" "acr" {
  name                = "cr${var.workload}${var.environment}${random_string.acr.result}" # globally unique
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "Standard"
  admin_enabled       = false
}

resource "azurerm_user_assigned_identity" "uami" {
  location            = data.azurerm_resource_group.rg.location
  name                = "id-${local.name_suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.uami.principal_id
  skip_service_principal_aad_check = true # Entra might lag behind in recognising new identity, maybe there is a better solution
}