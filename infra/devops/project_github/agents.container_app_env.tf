// agents.container_app_env.tf
//
// Project-scoped ACA Environment (target architecture — §5.4.1).
//
// In "platform" mode the project creates a dedicated ACA-delegated subnet
// inside the shared Platform LZ VNet and deploys the ACA Environment there.
// In "byo" mode the project uses the externally-provided subnet
// (var.byo_aca_subnet_id).
//
// The Platform LZ supplies shared infrastructure consumed by this
// environment: ACR, Log Analytics workspace, container-run UAMI, and
// private DNS zones — all obtained via the devops remote-state outputs.

# ── subnet (platform mode only) ─────────────────────────────────────────

resource "azurerm_subnet" "aca" {
  count = (
    var.use_self_hosted_runners
    && var.self_hosted_runners_type == "aca"
    && var.network_mode == "platform"
    && local.options.private_network_enabled
    ? 1 : 0
  )

  name                 = "snet-aca-${var.project_name}"
  resource_group_name  = local._devops_outputs.devops_network.resource_group_name
  virtual_network_name = local._devops_outputs.devops_network.vnet_name
  address_prefixes     = [var.platform_aca_subnet_address_prefix]

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name = "Microsoft.App/environments"
    }
  }
}

# ── locals ───────────────────────────────────────────────────────────────

locals {
  // Effective ACA subnet: platform-created or BYO-provided
  _platform_aca_subnet_id = (
    length(azurerm_subnet.aca) > 0
    ? azurerm_subnet.aca[0].id
    : null
  )

  effective_aca_subnet_id = (
    var.network_mode == "platform"
    ? local._platform_aca_subnet_id
    : var.byo_aca_subnet_id
  )

  // Whether the project should create an ACA Environment
  create_aca_env = (
    var.use_self_hosted_runners
    && var.self_hosted_runners_type == "aca"
  )

  // Names
  container_app_environment_name             = "cae-${local.resource_name}-${local.rand_id}"
  container_app_aca_infra_resource_group_name = "rg-cae-infra-${local.resource_name}-${local.rand_id}"
  container_app_workload_profile_name        = "Consumption"
}

# ── ACA Environment ─────────────────────────────────────────────────────

module "aca" {
  count  = local.create_aca_env ? 1 : 0
  source = "../../modules/aca_env"

  container_app_environment_name = local.container_app_environment_name
  location                       = var.location
  resource_group_name            = local.agents_resource_group_name
  tags                           = var.tags

  logs_destination                        = "log-analytics"
  log_analytics_workspace_id              = local.log_analytics_workspace_id
  workload_profile_name                   = local.container_app_workload_profile_name
  container_app_infra_resource_group_name = local.container_app_aca_infra_resource_group_name
  container_app_subnet_id                 = local.options.private_network_enabled ? local.effective_aca_subnet_id : null
  internal_load_balancer_enabled          = local.options.private_network_enabled ? true : false
  zone_redundancy_enabled                 = local.options.private_network_enabled ? var.enable_aca_zone_redundancy : false

  depends_on = [
    azurerm_subnet.aca,
  ]
}
