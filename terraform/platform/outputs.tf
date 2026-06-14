output "resource_group_name" {
  description = "The environment resource group Terraform deployed into."
  value       = data.azurerm_resource_group.rg.name
}

output "container_app_environment_id" {
  description = "The ID of the Container App Environment."
  value       = azurerm_container_app_environment.cae.id
}

output "container_registry_login_server" {
  description = "Login server of the ACR the app pulls images from."
  value       = azurerm_container_registry.acr.login_server
}

output "user_assigned_identity_id" {
  description = "Identity (with AcrPull) for the container app to use."
  value       = azurerm_user_assigned_identity.uami.id
}