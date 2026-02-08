// storage.cmk.tf

locals {
  _storage_cmk_name = "cmk-${var.storage_account_name}"
}

resource "azurerm_key_vault_key" "tfbackend_cmk" {
  count = var.enable_storage_customer_managed_key ? 1 : 0

  name         = local._storage_cmk_name
  key_vault_id = module.kv.resource_id
  key_type     = var.storage_customer_managed_key_policy.key_type
  key_size     = var.storage_customer_managed_key_policy.key_size
  curve        = var.storage_customer_managed_key_policy.curve_type

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  expiration_date = var.storage_customer_managed_key_policy.expiration_date != null ? var.storage_customer_managed_key_policy.expiration_date : null

  dynamic "rotation_policy" {
    for_each = var.storage_customer_managed_key_policy.rotation_policy != null ? [1] : []
    content {
      dynamic "automatic" {
        for_each = var.storage_customer_managed_key_policy.rotation_policy.automatic != null ? [1] : []
        content {
          time_after_creation = var.storage_customer_managed_key_policy.rotation_policy.automatic.time_after_creation
          time_before_expiry  = var.storage_customer_managed_key_policy.rotation_policy.automatic.time_before_expiry
        }
      }
      expire_after         = var.storage_customer_managed_key_policy.rotation_policy.expire_after
      notify_before_expiry = var.storage_customer_managed_key_policy.rotation_policy.notify_before_expiry
    }
  }

  depends_on = [
    module.kv,
  ]

  lifecycle {
    ignore_changes = [
      expiration_date, # Rotation policy may update this
      version,         # Key rotation creates new version
      versionless_id,  # Changes with version
    ]
  }
}
