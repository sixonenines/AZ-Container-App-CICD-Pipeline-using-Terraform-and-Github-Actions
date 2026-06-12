output "resource_group" {
  description = "The environment resource group Terraform deployed into."
  value       = data.azurerm_resource_group.rg.name
}