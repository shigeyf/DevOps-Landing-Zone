// _locals.tf

# Local variables for resource names
locals {
  resource_short_name = substr(local.resource_suffix_hash, 0, 16)

  resource_group_name  = "rg-${join("-", local.resource_suffix)}-${local.rand_id}"
  keyvault_name        = "kv-${local.resource_short_name}${local.rand_id}"
  storage_account_name = "st${local.resource_short_name}${local.rand_id}"
  storage_uami_name    = "uami-${local.resource_short_name}-${local.rand_id}-st"
}
