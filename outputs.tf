output "fqdn" {
  description = "Internal FQDN of the Socket Registry Firewall container app"
  value       = azurerm_container_app.firewall.ingress[0].fqdn
}

output "resource_group_name" {
  description = "Name of the resource group containing all resources"
  value       = azurerm_resource_group.this.name
}

output "container_app_name" {
  description = "Name of the Container App running the firewall"
  value       = azurerm_container_app.firewall.name
}

output "container_app_environment_name" {
  description = "Name of the Container Apps Environment"
  value       = azurerm_container_app_environment.this.name
}

output "key_vault_name" {
  description = "Name of the Key Vault storing secrets"
  value       = azurerm_key_vault.this.name
}

output "managed_identity_client_id" {
  description = "Client ID of the user-assigned managed identity"
  value       = azurerm_user_assigned_identity.this.client_id
}
