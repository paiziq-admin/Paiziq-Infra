mock_provider "azurerm" {
  mock_resource "azurerm_user_assigned_identity" {
    defaults = { principal_id = "171abb64-1aad-4bec-b59f-aa935eca4c1a" }
  }
}
mock_provider "random" {}

run "dev" {
  command = plan
  variables { environment = "dev" }
  assert {
    condition     = azurerm_resource_group.environment.name == "paiziq-dev"
    error_message = "Dev must use the exact requested resource group."
  }
  assert {
    condition     = azurerm_storage_account.data.name == "paiziqdevdata8406cce02"
    error_message = "Dev storage must match the existing deployment for adoption."
  }
  assert {
    condition     = azurerm_container_app.backend.template[0].max_replicas == 1 && azurerm_container_app.backend.template[0].min_replicas == 1
    error_message = "SQLite requires one backend replica."
  }
  assert {
    condition     = azurerm_container_app.backend.template[0].volume[0].storage_type == "AzureFile"
    error_message = "The database must persist outside the container."
  }
  assert {
    condition     = !azurerm_container_registry.backend.admin_enabled && !azurerm_container_app.backend.ingress[0].allow_insecure_connections
    error_message = "Registry admin credentials and insecure ingress must stay disabled."
  }
}
run "prod" {
  command = plan
  variables { environment = "prod" }
  assert {
    condition     = azurerm_resource_group.environment.name == "paiziq-prod" && azurerm_container_registry.backend.name != "paiziqdevacr8406cce0"
    error_message = "Prod must be isolated from dev."
  }
  assert {
    condition     = azurerm_storage_account.data.name != "paiziqdevdata8406cce02"
    error_message = "Prod must never reuse the dev database."
  }
}
run "reject_unknown_environment" {
  command = plan
  variables { environment = "staging" }
  expect_failures = [var.environment]
}
