// terraform.tf

terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "2.8.0"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "0.3.5"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.59.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.8.1"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
  }
}
