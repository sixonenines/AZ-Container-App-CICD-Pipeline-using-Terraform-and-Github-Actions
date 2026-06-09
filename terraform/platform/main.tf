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
    use_oidc             = true                                    # Can also be set via `ARM_USE_OIDC` environment variable.
    use_azuread_auth     = true                                    # Can also be set via `ARM_USE_AZUREAD` environment variable.
    #storage_account_name = "uniqueuniquestoragename"               # Can be passed via `-backend-config=`"storage_account_name=<storage account name>"` in the `init` command.
    #container_name       = "tfstate"                               # Can be passed via `-backend-config=`"container_name=<container name>"` in the `init` command.
    #key                  = "dev.prod.terraform.tfstate"                # Can be passed via `-backend-config=`"key=<blob key name>"` in the `init` command.
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}

# exposes attributes of the current client configuration.
data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "rg" { 
  name = var.resource_group_name
}

resource "azurerm_virtual_network" "workingcicd" {
  name                = "vnet-${data.azurerm_resource_group.rg.name}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  address_space       = ["192.168.0.0/16"]

  tags = {
    purpose     = "Proof of concept"
    provisioned = "terraform"
  }
}