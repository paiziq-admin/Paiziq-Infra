locals {
  group_name   = "paiziq-${var.environment}"
  registry     = "paiziq${var.environment}acr8406cce0"
  storage      = var.environment == "dev" ? "paiziqdevdata8406cce02" : "paiziqproddata8406cce0"
  backend_name = var.environment == "dev" ? "paiziq-ingest-dev-recovery" : "paiziq-ingest-prod"
  backend_env  = var.environment == "dev" ? "paiziq-dev-env-recovery-eastus2" : "paiziq-prod-env-eastus2"
  tags         = { application = "paiziq", environment = var.environment, managed_by = "terraform" }
}
resource "azurerm_resource_group" "environment" {
  name     = local.group_name
  location = "centralus"
  tags     = local.tags
}
resource "azurerm_container_registry" "backend" {
  name                = local.registry
  resource_group_name = azurerm_resource_group.environment.name
  location            = "centralus"
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}
resource "azurerm_storage_account" "data" {
  name                            = local.storage
  resource_group_name             = azurerm_resource_group.environment.name
  location                        = "eastus2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}
resource "azurerm_storage_share" "data" {
  name               = "paiziq-ingest-data"
  storage_account_id = azurerm_storage_account.data.id
  quota              = 5
}
resource "azurerm_container_app_environment" "backend" {
  name                = local.backend_env
  resource_group_name = azurerm_resource_group.environment.name
  location            = "eastus2"
  # Consumption only: no dedicated nodes, VNet or paid log workspace.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
  tags = local.tags
}
resource "azurerm_container_app_environment_storage" "data" {
  name                         = "paiziq-data"
  container_app_environment_id = azurerm_container_app_environment.backend.id
  account_name                 = azurerm_storage_account.data.name
  share_name                   = azurerm_storage_share.data.name
  access_key                   = azurerm_storage_account.data.primary_access_key
  access_mode                  = "ReadWrite"
}
resource "azurerm_static_web_app" "dashboard" {
  name                = "paiziq-dashboard-${var.environment}"
  resource_group_name = azurerm_resource_group.environment.name
  location            = "centralus"
  sku_tier            = "Free"
  sku_size            = "Free"
  tags                = local.tags
  lifecycle {
    ignore_changes = [repository_url, repository_branch]
  }
}
resource "azurerm_user_assigned_identity" "pull" {
  name                = "paiziq-${var.environment}-registry-pull"
  resource_group_name = azurerm_resource_group.environment.name
  location            = "eastus2"
  tags                = local.tags
}
resource "azurerm_role_assignment" "pull" {
  scope                            = azurerm_container_registry.backend.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.pull.principal_id
  skip_service_principal_aad_check = true
}
# The persistent SDK CI identity lives in paiziq-infra, outside cleanup scope.
resource "azurerm_role_assignment" "sdk_deploy" {
  count                            = var.sdk_ci_principal_id == null ? 0 : 1
  scope                            = azurerm_resource_group.environment.id
  role_definition_name             = "Contributor"
  principal_id                     = var.sdk_ci_principal_id
  skip_service_principal_aad_check = true
}
resource "azurerm_role_assignment" "sdk_push" {
  count                            = var.sdk_ci_principal_id == null ? 0 : 1
  scope                            = azurerm_container_registry.backend.id
  role_definition_name             = "AcrPush"
  principal_id                     = var.sdk_ci_principal_id
  skip_service_principal_aad_check = true
}
resource "random_password" "ingest" {
  length  = 48
  special = false
}
resource "random_id" "encryption" {
  byte_length = 32
}
resource "azurerm_container_app" "backend" {
  name                         = local.backend_name
  resource_group_name          = azurerm_resource_group.environment.name
  container_app_environment_id = azurerm_container_app_environment.backend.id
  revision_mode                = "Single"
  max_inactive_revisions       = 3
  tags                         = local.tags
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.pull.id]
  }
  registry {
    server   = azurerm_container_registry.backend.login_server
    identity = azurerm_user_assigned_identity.pull.id
  }
  secret {
    name  = "ingest-keys"
    value = var.existing_ingest_keys != null ? var.existing_ingest_keys : random_password.ingest.result
  }
  secret {
    name  = "secrets-key"
    value = var.existing_secrets_key != null ? var.existing_secrets_key : replace(replace(random_id.encryption.b64_std, "+", "-"), "/", "_")
  }
  template {
    revision_suffix = var.deployment_revision
    min_replicas    = 1
    max_replicas    = 1
    volume {
      name          = "data"
      storage_name  = azurerm_container_app_environment_storage.data.name
      storage_type  = "AzureFile"
      mount_options = "uid=10001,gid=10001,nobrl,mfsymlinks,cache=none"
    }
    container {
      name   = "paiziq-ingest"
      image  = "${azurerm_container_registry.backend.login_server}/paiziq-ingest:${var.backend_image_tag}"
      cpu    = 0.5
      memory = "1Gi"
      env {
        name  = "PAIZIQ_ENV"
        value = "production"
      }
      env {
        name  = "PAIZIQ_INGEST_DB"
        value = "/data/paiziq.sqlite"
      }
      env {
        name        = "PAIZIQ_INGEST_KEYS"
        secret_name = "ingest-keys"
      }
      env {
        name        = "PAIZIQ_SECRETS_KEY"
        secret_name = "secrets-key"
      }
      env {
        name  = "PAIZIQ_CORS_ORIGINS"
        value = "https://${azurerm_static_web_app.dashboard.default_host_name}"
      }
      env {
        name  = "PAIZIQ_RATE_LIMIT_RPM"
        value = "240"
      }
      env {
        name  = "PAIZIQ_LOG_LEVEL"
        value = "INFO"
      }
      volume_mounts {
        name = "data"
        path = "/data"
      }
      readiness_probe {
        transport = "HTTP"
        port      = 8800
        path      = "/health"
      }
      liveness_probe {
        transport = "HTTP"
        port      = 8800
        path      = "/health"
      }
    }
  }
  ingress {
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 8800
    transport                  = "auto"
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
  depends_on = [azurerm_role_assignment.pull]
}
