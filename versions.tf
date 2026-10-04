terraform {
  required_version = "= 1.16.5"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "= 5.8.0" }
    random  = { source = "hashicorp/random", version = "= 3.9.1" }
  }
  backend "azurerm" {}
}
provider "azurerm" {
  resource_provider_registrations = "none"
  features {
    resource_group {
      # Cleanup owns the whole environment, including untracked resources.
      prevent_deletion_if_contains_resources = false
    }
  }
}
