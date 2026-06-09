output "resource_group" {
  description = "The environment resource group Terraform deployed into."
  value       = data.azurerm_resource_group.rg.name
}

output "workingcicd" {
  description = "ID of the workingcicd VNet — its presence confirms the pipeline applied successfully."
  value       = azurerm_virtual_network.workingcicd.id
}
