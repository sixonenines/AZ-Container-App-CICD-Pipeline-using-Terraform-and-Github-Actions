output "resource_group_name" {
  description = "The environment resource group Terraform deployed into."
  value       = data.azurerm_resource_group.rg.name
}

output "container_app_environment_id" {
  description = "The ID of the Container App Environment."
  value       = azurerm_container_app_environment.cae.id
}

output "container_registry_login_server" {
  description = "Login server of the shared ACR the app pulls images from."
  # Deterministic for public Azure (<name>.azurecr.io), so we derive it rather than
  # data-sourcing the registry — that keeps this stack free of any rights on the
  # shared registry.
  value = "${var.tf_shared_acr_name}.azurecr.io"
}

output "user_assigned_identity_id" {
  description = "Identity (with AcrPull on the shared ACR) for the container app to use."
  value       = data.azurerm_user_assigned_identity.uami.id
}