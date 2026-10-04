output "resource_group" { value = azurerm_resource_group.environment.name }
output "registry_name" { value = azurerm_container_registry.backend.name }
output "registry_server" { value = azurerm_container_registry.backend.login_server }
output "backend_url" { value = "https://${azurerm_container_app.backend.ingress[0].fqdn}" }
output "dashboard_url" { value = "https://${azurerm_static_web_app.dashboard.default_host_name}" }
