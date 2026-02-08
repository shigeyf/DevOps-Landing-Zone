// uami.tf

module "tfstate_uami" {
  count   = var.enable_user_assigned_identity ? 1 : 0
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "0.3.4"

  enable_telemetry    = var.enable_telemetry
  name                = var.storage_uami_name
  location            = var.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}
