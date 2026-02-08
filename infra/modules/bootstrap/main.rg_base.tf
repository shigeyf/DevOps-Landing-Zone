// rg_base.tf

module "resource_group_base" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.2.2"

  enable_telemetry = var.enable_telemetry
  name             = var.resource_group_name
  location         = var.location
  tags             = var.tags
}
