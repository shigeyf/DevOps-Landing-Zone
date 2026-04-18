// _variables.network.tf

variable "network_mode" {
  description = <<-EOT
    Runner network mode.
      "platform" — the project creates its ACA subnet inside the shared
                   Platform LZ VNet (default, low-friction).
      "byo"      — the project uses an externally-provided VNet and subnet.
    See §8.0 in the Target Architecture Spec.
  EOT
  type        = string
  default     = "platform"

  validation {
    condition     = var.network_mode == "platform" || var.network_mode == "byo"
    error_message = "network_mode must be either 'platform' or 'byo'."
  }
}

variable "byo_aca_subnet_id" {
  description = <<-EOT
    (Required when network_mode = "byo")
    Resource ID of the pre-existing ACA-delegated subnet in the BYO VNet.
    Must have the Microsoft.App/environments delegation and at least a /23 address space.
  EOT
  type        = string
  default     = null
}

variable "platform_aca_subnet_address_prefix" {
  description = <<-EOT
    (Used when network_mode = "platform")
    Address prefix for the project-dedicated ACA runner subnet created
    inside the Platform LZ VNet.  Must be a /23 or larger within the
    platform VNet address space.
  EOT
  type        = string
  default     = null
}

variable "enable_aca_zone_redundancy" {
  description = "Enable zone redundancy for the project's ACA Environment."
  type        = bool
  default     = true
}
