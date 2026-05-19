# Module Design Specification

[English](./Module-Design.md) | [日本語](./Module-Design.ja.md)

> **Status:** Draft — planning phase.
>
> **Purpose:** Define the reusable sub-module (building block) design for the four-layer DevOps Landing Zone deployment model. Each deployment layer (`bootstrap`, `devops-org-lz`, `devops-project-lz`, `devops-repo-lz`) composes abstract, domain-level sub-modules that encapsulate resources and VCS-specific implementations behind uniform interfaces.

---

## Table of Contents

1. [Four-Layer Deployment Model](#1-four-layer-deployment-model)
2. [Module Design Principles](#2-module-design-principles)
3. [Layer 0: Bootstrap Sub-Modules (bootstrap)](#3-layer-0-bootstrap-sub-modules-bootstrap)
4. [Layer 1: Organization LZ Sub-Modules (devops-org-lz)](#4-layer-1-organization-lz-sub-modules-devops-org-lz)
5. [Layer 2: Project LZ Sub-Modules (devops-project-lz)](#5-layer-2-project-lz-sub-modules-devops-project-lz)
6. [Layer 3: Repo LZ Sub-Modules (devops-repo-lz)](#6-layer-3-repo-lz-sub-modules-devops-repo-lz)
7. [Abstract Module Pattern](#7-abstract-module-pattern)
8. [Module Composition Diagram](#8-module-composition-diagram)
9. [Implementation Plan](#9-implementation-plan)

---

## 1. Four-Layer Deployment Model

The DevOps Landing Zone uses **four** separate Terraform deployments (each with its own state). Layer 0 (Bootstrap) is the foundation that creates the state backend; Layers 1–3 build on it:

| Layer | Deployment            | Directory                  | Scope                                                | State Key                                  |
| ----- | --------------------- | -------------------------- | ---------------------------------------------------- | ------------------------------------------ |
| 0     | **Bootstrap**         | `infra/bootstrap/`         | Layer 1 Storage Account + Key Vault + CMK + UAMI     | `bootstrap.terraform.tfstate`              |
| 1     | **devops-org-lz**     | `infra/devops-org-lz/`     | Organization-wide shared infrastructure              | `devops-lz.terraform.tfstate`              |
| 2     | **devops-project-lz** | `infra/devops-project-lz/` | Per-project infra (identity, runner, state, network) | `projects/<name>.terraform.tfstate`        |
| 3     | **devops-repo-lz**    | `infra/devops-repo-lz/`    | Per-repo resources + environments                    | `repos/<project>/<repo>.terraform.tfstate` |

Each layer reads the previous layer's outputs via `terraform_remote_state`. Layer 0 is applied once (rarely re-applied); Layers 1–3 follow the standard operational cadence.

---

## 2. Module Design Principles

1. **Abstract over VCS platform** — Sub-modules like `repo_repository`, `repo_environment`, and `repo_runner` accept a `vcs_provider` input (`"github"` or `"azuredevops"`) and internally dispatch to the correct implementation. Callers get a uniform input/output contract.

2. **Single responsibility** — Each sub-module owns exactly one domain concept (e.g., project state storage, project identity, repository provisioning, environment binding).

3. **Platform-agnostic where possible** — Modules dealing with pure Azure resources (`project_state`, `project_identity`, `project_network`) work identically for both GitHub and Azure DevOps projects.

4. **VCS-specific only where necessary** — Modules that interact with VCS APIs (`repo_repository`, `repo_environment`, `repo_runner`) use the abstract dispatch pattern.

5. **Composable, not nested** — Sub-modules do not call each other. Root modules (`project_github`, `repo_github`, etc.) compose sub-modules and pass outputs between them.

6. **Consistent interface** — All abstract modules share a common variable pattern: `vcs_provider`, `project_name`, and domain-specific inputs.

---

## 3. Layer 0: Bootstrap Sub-Modules (bootstrap)

The Bootstrap layer creates the foundational state backend and secret store for the entire DevOps Landing Zone. It is applied **once** per organization (rarely re-applied) and uses a local state file that is migrated to the Storage Account it creates.

### Layer 0 — Consolidated Resource Inventory

| #   | Resource                    | Azure Type / Terraform Type      | Resource Group    | Sub-Module  |
| --- | --------------------------- | -------------------------------- | ----------------- | ----------- |
| 1   | Bootstrap Resource Group    | `azurerm_resource_group`         | _(self)_          | `bootstrap` |
| 2   | Layer 1 Storage Account     | `azurerm_storage_account`        | Bootstrap RG      | `bootstrap` |
| 3   | `tfstate` blob containers   | `azurerm_storage_container`      | Bootstrap RG (SA) | `bootstrap` |
| 4   | Bootstrap Key Vault         | `azurerm_key_vault`              | Bootstrap RG      | `bootstrap` |
| 5   | `tfbackend_cmk` Key         | `azurerm_key_vault_key`          | Bootstrap RG (KV) | `bootstrap` |
| 6   | Bootstrap UAMI              | `azurerm_user_assigned_identity` | Bootstrap RG      | `bootstrap` |
| 7   | `azurerm.tfbackend` configs | `local_file`                     | _(local disk)_    | `bootstrap` |

**Total: 1 Resource Group, 7 resources.**

### Sub-Modules

| Sub-Module  | Responsibility                                | Platform-Agnostic? | Status   |
| ----------- | --------------------------------------------- | ------------------ | -------- |
| `bootstrap` | RG + Storage Account + Key Vault + CMK + UAMI | Yes                | Existing |

### `bootstrap`

Creates the Layer 1 state backend and its protection chain.

#### AVM Modules Used

The bootstrap module leverages the following [Azure Verified Modules (AVM)](https://azure.github.io/Azure-Verified-Modules/) for production-grade resource deployment:

| AVM Module                                        | Registry Source                                    | Version | Purpose                                             |
| ------------------------------------------------- | -------------------------------------------------- | ------- | --------------------------------------------------- |
| Storage Account                                   | `Azure/avm-res-storage-storageaccount/azurerm`     | 0.6.3   | Layer 1 tfstate backend with CMK encryption support |
| Key Vault                                         | `Azure/avm-res-keyvault-vault/azurerm`             | 0.10.1  | CMK store with RBAC authorization + purge protect   |
| User Assigned Managed Identity _(native planned)_ | `azurerm_user_assigned_identity` (native resource) | —       | CMK encryption chain identity                       |

> [!NOTE]
> The UAMI currently uses a native `azurerm_user_assigned_identity` resource. Migration to `Azure/avm-res-managedidentity-userassignedidentity/azurerm` is planned for consistency with the AVM pattern across all layers.

#### Internal Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  bootstrap (root module)                                            │
│                                                                     │
│  ┌──────────────────┐                                               │
│  │ azurerm_resource │  Resource Group (lifecycle anchor)            │
│  │ _group.base      │                                               │
│  └────────┬─────────┘                                               │
│           │                                                         │
│  ┌────────▼─────────────────────────────────────────────────────┐   │
│  │ AVM: avm-res-keyvault-vault/azurerm                          │   │
│  │  • RBAC: Key Vault Administrator → deployer                  │   │
│  │  • RBAC: Key Vault Crypto Officer → UAMI                     │   │
│  │  • purge_protection_enabled = true                           │   │
│  └────────┬─────────────────────────────────────────────────────┘   │
│           │                                                         │
│  ┌────────▼─────────┐                                               │
│  │ azurerm_key_vault│  CMK (RSA 4096-bit, rotation policy)         │
│  │ _key.tfbackend   │                                               │
│  └────────┬─────────┘                                               │
│           │                                                         │
│  ┌────────▼─────────────────────────────────────────────────────┐   │
│  │ AVM: avm-res-storage-storageaccount/azurerm                  │   │
│  │  • StorageV2 / Standard / LRS                                │   │
│  │  • infrastructure_encryption_enabled = true                  │   │
│  │  • customer_managed_key → Key Vault CMK + UAMI               │   │
│  │  • containers: { tfstate }                                   │   │
│  │  • RBAC: Storage Blob Data Owner → deployer                  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────────┐                                               │
│  │ azurerm_user_    │  UAMI (CMK encryption chain)                 │
│  │ assigned_identity│                                               │
│  └──────────────────┘                                               │
│                                                                     │
│  ┌──────────────────┐                                               │
│  │ local_file       │  bootstrap.config.json                       │
│  │ local_file       │  backend.tf (for state migration)            │
│  │ local_file       │  azurerm.tfbackend (downstream template)     │
│  └──────────────────┘                                               │
└─────────────────────────────────────────────────────────────────────┘
```

#### Dependency Chain

Resources are created in strict dependency order to establish the encryption chain:

```
Resource Group
  └─► UAMI
  └─► Key Vault (AVM) ──► RBAC propagation wait (60s)
        └─► CMK Key (azurerm_key_vault_key)
              └─► Storage Account (AVM) with customer_managed_key
                    └─► local_file outputs (config JSON + backend configs)
```

#### Variable Interface

| Variable                              | Type          | Default          | Description                                             |
| ------------------------------------- | ------------- | ---------------- | ------------------------------------------------------- |
| `location`                            | `string`      | —                | Azure region for deployment                             |
| `tags`                                | `map(string)` | `{}`             | Tags applied to all resources                           |
| `resource_group_name`                 | `string`      | —                | Bootstrap resource group name                           |
| `storage_account_name`                | `string`      | —                | Storage Account name (must be globally unique)          |
| `keyvault_name`                       | `string`      | —                | Key Vault name (must be globally unique)                |
| `tfstate_container_name`              | `string`      | `"tfstate"`      | Blob container name for tfstate files                   |
| `enable_user_assigned_identity`       | `bool`        | `false`          | Enable UAMI for CMK encryption chain                    |
| `enable_storage_customer_managed_key` | `bool`        | `false`          | Enable CMK encryption on Storage Account                |
| `storage_customer_managed_key_policy` | `object`      | RSA/4096/P90D    | CMK key type, size, rotation policy, and expiration     |
| `bootstrap_config_filename`           | `string`      | `"./bootstrap…"` | Output path for bootstrap config JSON                   |
| `tfbackend_config_template_filename`  | `string`      | `"./azurerm…"`   | Output path for backend config template                 |
| `purge_protection_enabled`            | `bool`        | `true`           | Key Vault purge protection (recommended for production) |
| `soft_delete_retention_days`          | `number`      | `7`              | Key Vault soft-delete retention (7–90 days)             |

#### AVM Module Configuration Details

**Storage Account (`avm-res-storage-storageaccount`):**

```hcl
module "tfbackend" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.6.3"

  account_kind                      = "StorageV2"
  account_replication_type          = "LRS"
  account_tier                      = "Standard"
  min_tls_version                   = "TLS1_2"
  infrastructure_encryption_enabled = true
  public_network_access_enabled     = true  # Locked down via PE in Layer 1

  containers = { tfstate = { name = var.tfstate_container_name } }

  managed_identities = {
    system_assigned            = true
    user_assigned_resource_ids = [azurerm_user_assigned_identity.this.id]
  }

  role_assignments = {
    deployer = {
      role_definition_id_or_name = "Storage Blob Data Owner"
      principal_id               = data.azurerm_client_config.current.object_id
    }
  }

  customer_managed_key = {
    key_vault_resource_id  = module.kv.resource_id
    key_name               = azurerm_key_vault_key.tfbackend_cmk.name
    user_assigned_identity = { resource_id = azurerm_user_assigned_identity.this.id }
  }
}
```

**Key Vault (`avm-res-keyvault-vault`):**

```hcl
module "kv" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.10.1"

  sku_name                      = "standard"
  public_network_access_enabled = true  # Locked down via PE in Layer 1
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7

  role_assignments = {
    deployer = {
      role_definition_id_or_name = "Key Vault Administrator"
      principal_id               = data.azurerm_client_config.current.object_id
    }
    cmk_identity = {
      role_definition_id_or_name = "Key Vault Crypto Officer"
      principal_id               = azurerm_user_assigned_identity.this.principal_id
    }
  }

  wait_for_rbac_before_secret_operations = { create = "60s" }
}
```

#### Deployed Resources

| Resource                         | Terraform Type                   | Purpose                                                                                                |
| -------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Bootstrap Resource Group         | `azurerm_resource_group`         | Container for all bootstrap resources; lifecycle anchor for Layer 1 state backend                      |
| Layer 1 Storage Account          | `azurerm_storage_account`        | Stores Layer 1 tfstate for bootstrap, Org LZ, Project LZ, and Repo LZ (blob versioning + immutability) |
| `tfstate` blob containers        | `azurerm_storage_container`      | Per-module tfstate containers (bootstrap, lz, project\_\*, repos/\*)                                   |
| Bootstrap Key Vault              | `azurerm_key_vault`              | Holds the CMK used to encrypt the Layer 1 SA; purge-protected, RBAC authorization                      |
| `tfbackend_cmk` Key              | `azurerm_key_vault_key`          | RSA key encrypting the Layer 1 Storage Account (defense in depth for tfstate)                          |
| Bootstrap UAMI                   | `azurerm_user_assigned_identity` | Identity granted CMK access (`Storage Account → Key Vault` encryption chain)                           |
| `azurerm.tfbackend` config files | `local_file`                     | Generated Terraform backend config templates for all downstream layers                                 |

#### Outputs

| Output                   | Type     | Description                                    |
| ------------------------ | -------- | ---------------------------------------------- |
| `resource_group_name`    | `string` | Bootstrap resource group name                  |
| `storage_account_name`   | `string` | Storage Account name (used in backend configs) |
| `tfstate_container_name` | `string` | Blob container name for tfstate                |
| `keyvault_name`          | `string` | Key Vault name                                 |
| `storage_id`             | `string` | Storage Account resource ID                    |
| `keyvault_id`            | `string` | Key Vault resource ID                          |

These outputs are written to `bootstrap.config.json` and consumed by all downstream layers for `terraform_remote_state` configuration.

---

## 4. Layer 1: Organization LZ Sub-Modules (devops-org-lz)

The Org LZ is a single root module that uses existing and new sub-modules to provision organization-wide shared infrastructure.

### Layer 1 — Consolidated Resource Inventory

| #   | Resource                              | Azure Type / Terraform Type             | Resource Group | Sub-Module       |
| --- | ------------------------------------- | --------------------------------------- | -------------- | ---------------- |
| 1   | Network RG                            | `azurerm_resource_group`                | _(self)_       | `org_vnet`       |
| 2   | Platform LZ VNet                      | `azurerm_virtual_network`               | Network RG     | `org_vnet`       |
| 3   | Subnets (runner, devbox, PE, etc.)    | `azurerm_subnet`                        | Network RG     | `org_vnet`       |
| 4   | NAT Gateway _(if configured)_         | `azurerm_nat_gateway`                   | Network RG     | `org_vnet`       |
| 5   | NAT Gateway Public IP                 | `azurerm_public_ip`                     | Network RG     | `org_vnet`       |
| 6   | Private DNS Zones (blob, vault, etc.) | `azurerm_private_dns_zone`              | Network RG     | `org_vnet`       |
| 7   | Private Endpoints (Layer 1 SA, KV)    | `azurerm_private_endpoint`              | Network RG     | `org_vnet`       |
| 8   | Agents RG                             | `azurerm_resource_group`                | _(self)_       | `org_acr`        |
| 9   | Azure Container Registry              | `azurerm_container_registry`            | Agents RG      | `org_acr`        |
| 10  | ACR Build Task                        | `azurerm_container_registry_task`       | Agents RG      | `org_acr`        |
| 11  | ACR Private Endpoint                  | `azurerm_private_endpoint`              | Agents RG      | `org_acr`        |
| 12  | Log Analytics Workspace               | `azurerm_log_analytics_workspace`       | Agents RG      | `org_acr`        |
| 13  | Container-Run UAMI                    | `azurerm_user_assigned_identity`        | Agents RG      | `org_acr`        |
| 14  | DevBox RG                             | `azurerm_resource_group`                | _(self)_       | `org_devcenter`  |
| 15  | Dev Center                            | `azurerm_dev_center`                    | DevBox RG      | `org_devcenter`  |
| 16  | Dev Box Definitions                   | `azurerm_dev_center_dev_box_definition` | DevBox RG      | `org_devcenter`  |
| 17  | KV secrets (VCS PATs)                 | `azurerm_key_vault_secret`              | Bootstrap KV   | `org_devcenter`  |
| 18  | Org-level rulesets _(GitHub)_         | `github_organization_ruleset`           | —              | `org_governance` |

**Total: 3 Resource Groups (Network RG, Agents RG, DevBox RG), ~18 resources.**

### Sub-Modules

| Sub-Module       | Responsibility                                            | Platform-Agnostic? | Status   |
| ---------------- | --------------------------------------------------------- | ------------------ | -------- |
| `org_vnet`       | Platform VNet + subnets + NAT Gateway + Private DNS zones | Yes                | Existing |
| `org_acr`        | Azure Container Registry + image build tasks              | Yes                | Existing |
| `org_governance` | Org-level rulesets and repository default settings        | No (dispatches)    | New      |
| `org_devcenter`  | Dev Center + Dev Box Definitions (org catalog)            | Yes                | New      |

> [!NOTE]
> `resource_providers` is intentionally **not** modularized in the target design.
> Resource provider registrations are managed separately (outside reusable sub-modules) to avoid cross-project state ownership conflicts.

### `org_vnet`

Creates the platform-managed VNet and associated network infrastructure.

**Deployed resources:**

| Resource                                       | Terraform Type             | Purpose                                                                                  |
| ---------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------- |
| Platform LZ VNet                               | `azurerm_virtual_network`  | Hub VNet for the platform; hosts PEs, runner subnets, DevBox subnets, and DNS zone links |
| Subnets (runner, devbox, PE, etc.)             | `azurerm_subnet`           | Project-dedicated address slices (platform mode) and platform-shared service slices      |
| NAT Gateway _(if configured)_                  | `azurerm_nat_gateway`      | Deterministic egress for runner Jobs (allow-listable IPs)                                |
| NAT Gateway Public IP                          | `azurerm_public_ip`        | Static public IP(s) attached to NAT Gateway                                              |
| Private DNS Zones (blob, vault, azurecr, etc.) | `azurerm_private_dns_zone` | Name resolution for PEs from platform and BYO project VNets                              |
| Private Endpoints (Layer 1 SA, KV)             | `azurerm_private_endpoint` | Private connectivity to bootstrap SA and KV                                              |
| Network RG                                     | `azurerm_resource_group`   | Hosts VNet, subnets, NAT, DNS zones, and PEs                                             |

### `org_acr`

Creates the shared container registry for runner images.

**Deployed resources:**

| Resource                 | Terraform Type                    | Purpose                                                              |
| ------------------------ | --------------------------------- | -------------------------------------------------------------------- |
| Azure Container Registry | `azurerm_container_registry`      | Premium ACR with PE; stores the self-hosted runner container image   |
| ACR Build Task           | `azurerm_container_registry_task` | Builds and refreshes the runner container image inside the platform  |
| ACR Private Endpoint     | `azurerm_private_endpoint`        | Private access to ACR from the platform VNet                         |
| Agents RG                | `azurerm_resource_group`          | Hosts ACR, Log Analytics, container-run UAMI                         |
| Log Analytics Workspace  | `azurerm_log_analytics_workspace` | Centralized logs/metrics for runner ACA Environments across projects |
| Container-Run UAMI       | `azurerm_user_assigned_identity`  | Identity used by runner containers to pull from ACR and write logs   |

### `org_governance` — Abstract Module

```hcl
module "org_governance" {
  source       = "./modules/org_governance"
  vcs_provider = var.vcs_provider   # "github" | "azuredevops"

  # Uniform inputs
  default_branch_rules = var.org_default_branch_rules
  # ...
}
```

Internally dispatches to:

- `modules/org_governance/github.tf` — GitHub org rulesets + default settings
- `modules/org_governance/azuredevops.tf` — ADO branch policies + project settings

> [!NOTE]
> Runner groups (GitHub) and agent pools (ADO) are **not** created at the org level.
> Since all resources reside in a single subscription (no billing separation between org/project),
> runner groups/agent pools are created by `project_runner` (Layer 2) as part of project provisioning.
> Each project is fully self-contained — runner isolation is achieved per-project without org-level pre-provisioning.

**Deployed resources (GitHub):**

| Resource            | Terraform Type                            | Purpose                                                   |
| ------------------- | ----------------------------------------- | --------------------------------------------------------- |
| Org-level rulesets  | `github_organization_ruleset`             | Enforce branch protection and required workflows org-wide |
| Repository defaults | `github_actions_organization_permissions` | Default Actions permissions for new repositories          |

**Deployed resources (Azure DevOps):**

| Resource         | Terraform Type                 | Purpose                               |
| ---------------- | ------------------------------ | ------------------------------------- |
| Branch policies  | `azuredevops_branch_policy_*`  | Enforce branch protection org-wide    |
| Project settings | `azuredevops_project_features` | Default project feature configuration |

### `org_devcenter`

Creates the organization-wide Dev Center and Dev Box catalog.

**Deployed resources:**

| Resource              | Terraform Type                          | Purpose                                                  |
| --------------------- | --------------------------------------- | -------------------------------------------------------- |
| Dev Center            | `azurerm_dev_center`                    | Org-wide control plane for developer Dev Boxes           |
| Dev Box Definitions   | `azurerm_dev_center_dev_box_definition` | Per-image/per-SKU Dev Box definitions (catalog)          |
| DevBox RG             | `azurerm_resource_group`                | Hosts the Dev Center and definitions                     |
| KV secrets (VCS PATs) | `azurerm_key_vault_secret`              | VCS PATs stored in bootstrap KV for project provisioning |

---

## 5. Layer 2: Project LZ Sub-Modules (devops-project-lz)

The Project LZ provisions per-project infrastructure. It does **not** create repositories or environments — those belong to Layer 3.

### Layer 2 — Consolidated Resource Inventory (per project)

| #   | Resource                             | Azure Type / Terraform Type                              | Resource Group | Sub-Module         |
| --- | ------------------------------------ | -------------------------------------------------------- | -------------- | ------------------ |
| 1   | Project Resource Group               | `azurerm_resource_group`                                 | _(self)_       | `project_state`    |
| 2   | Layer 2 Storage Account              | `azurerm_storage_account`                                | Project RG     | `project_state`    |
| 3   | Layer 2 blob containers              | `azurerm_storage_container`                              | Project RG     | `project_state`    |
| 4   | Project Key Vault                    | `azurerm_key_vault`                                      | Project RG     | `project_state`    |
| 5   | Layer 2 Private Endpoint             | `azurerm_private_endpoint`                               | Project RG     | `project_state`    |
| 6   | Layer 2 PE DNS zone link             | `azurerm_private_dns_zone_virtual_network_link`          | Project RG     | `project_state`    |
| 7   | 7 Project UAMIs                      | `azurerm_user_assigned_identity` (×7)                    | Project RG     | `project_identity` |
| 8   | OIDC Federated Credentials (×7)      | `azurerm_federated_identity_credential`                  | Project RG     | `project_identity` |
| 9   | Subscription role assignments        | `azurerm_role_assignment` (conditional)                  | _(sub scope)_  | `project_identity` |
| 10  | Project ACA subnet _(platform mode)_ | `azurerm_subnet`                                         | Network RG     | `project_network`  |
| 11  | ACA Environment                      | `azurerm_container_app_environment`                      | Project RG     | `project_runner`   |
| 12  | ACA Environment DNS zone link        | `azurerm_private_dns_zone_virtual_network_link`          | Project RG     | `project_runner`   |
| 13  | DevCenter Project                    | `azurerm_dev_center_project`                             | Project RG     | `project_devbox`   |
| 14  | Dev Box Pool                         | `azurerm_dev_center_project_pool`                        | Project RG     | `project_devbox`   |
| 15  | Network Connection                   | `azurerm_dev_center_network_connection`                  | Project RG     | `project_devbox`   |
| 16  | Dev Box role assignments             | `azurerm_role_assignment`                                | Project RG     | `project_devbox`   |
| 17  | ACA Job (GitHub runner or ADO agent) | `azurerm_container_app_job`                              | Project RG     | `project_runner`   |
| 18  | Runner group/agent pool              | `github_actions_runner_group` / `azuredevops_agent_pool` | —              | `project_runner`   |

**Total: 1 Resource Group (Project RG), ~18 resources per project.**

### Sub-Modules

| Sub-Module         | Responsibility                                                                                                       | Platform-Agnostic? | Status |
| ------------------ | -------------------------------------------------------------------------------------------------------------------- | ------------------ | ------ |
| `project_state`    | Layer 2 Storage Account + Project Key Vault + Project RG                                                             | Yes                | New    |
| `project_identity` | 7 UAMIs + OIDC federated credentials + subscription RBAC                                                             | Yes                | New    |
| `project_network`  | Subnet slice (platform mode) or BYO VNet validation                                                                  | Yes                | New    |
| `project_devbox`   | DevCenter Project + Dev Box Pool + Network Connection                                                                | Yes                | New    |
| `project_runner`   | ACA Environment + ACA Job + runner group (GitHub) or agent pool (ADO) — complete runner compute platform per project | No (dispatches)    | New    |

### `project_state`

Creates per-project state infrastructure.

**Deployed resources:**

| Resource                 | Terraform Type                                  | Purpose                                                                                      |
| ------------------------ | ----------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Project Resource Group   | `azurerm_resource_group`                        | Houses all project-owned resources (state, identities, secrets) in the platform subscription |
| Layer 2 Storage Account  | `azurerm_storage_account`                       | Stores Layer 2 tfstate for project's own app IaC (LRS default, selectable replication)       |
| Layer 2 blob containers  | `azurerm_storage_container`                     | Per-workspace tfstate containers for the project team                                        |
| Project Key Vault        | `azurerm_key_vault`                             | Project-owned secrets and keys (distinct from bootstrap KV)                                  |
| Layer 2 Private Endpoint | `azurerm_private_endpoint`                      | Private connectivity to the Layer 2 SA from the project's runner network                     |
| Layer 2 PE DNS zone link | `azurerm_private_dns_zone_virtual_network_link` | Links the project's VNet to platform DNS zones for PE resolution                             |

### `project_identity`

Creates the 7 project-scoped UAMIs inside the **Project Resource Group** (created by `project_state`).

**Deployed resources:**

| Resource                        | Terraform Type                          | Purpose                                                                                                                             |
| ------------------------------- | --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 7 Project UAMIs                 | `azurerm_user_assigned_identity`        | Per-environment, per-job-type identities (`feat-plan`, `dev-plan`, `stg-plan`, `prod-plan`, `dev-apply`, `stg-apply`, `prod-apply`) |
| OIDC Federated Credentials (×7) | `azurerm_federated_identity_credential` | Trust VCS environment to mint Azure tokens per (env × job)                                                                          |
| Subscription role assignments   | `azurerm_role_assignment`               | Conditional RBAC on env subscription (only when subscription is declared)                                                           |

> [!NOTE]
> All UAMIs are created in the Project RG (Layer 2), **not** in a separate org-level Identity RG.
> This keeps each project self-contained: Layer 2 does not need write access to any Layer 1 resource group,
> and deleting the Project RG cleanly removes all project-owned identities.

Each UAMI gets:

- OIDC federated credentials (bound to VCS environment)
- Conditional subscription RBAC (only if subscription is declared)

### `project_network`

Handles the project's DevOps network context.

**Deployed resources (platform mode):**

| Resource                | Terraform Type          | Purpose                                                           |
| ----------------------- | ----------------------- | ----------------------------------------------------------------- |
| Project ACA subnet      | `azurerm_subnet`        | Project-dedicated subnet slice within the shared Platform LZ VNet |
| Subnet delegation (ACA) | subnet delegation block | Delegates the subnet to `Microsoft.App/environments`              |

**Deployed resources (BYO mode):**

| Resource                           | Terraform Type | Purpose                                                               |
| ---------------------------------- | -------------- | --------------------------------------------------------------------- |
| _(none created — validation only)_ | data sources   | Validates externally-provided VNet/subnet against 7 consistency rules |

### `project_devbox`

Creates DevCenter project resources.

**Deployed resources:**

| Resource                 | Terraform Type                          | Purpose                                                                  |
| ------------------------ | --------------------------------------- | ------------------------------------------------------------------------ |
| DevCenter Project        | `azurerm_dev_center_project`            | Project-scoped Dev Box catalog reference (links to org-level Dev Center) |
| Dev Box Pool             | `azurerm_dev_center_project_pool`       | Pool for the project's developer Dev Boxes                               |
| Network Connection       | `azurerm_dev_center_network_connection` | Binds the pool to the project's runner network context                   |
| Dev Box role assignments | `azurerm_role_assignment`               | Grants project team access to provision and manage Dev Boxes             |

### `project_runner` — Abstract Module

Creates the complete runner compute platform for a project. This module provisions the runner group (GitHub) or agent pool (ADO), the ACA Environment (the compute surface), **and** registers an ACA Job as a self-hosted runner. Each project is fully self-contained — no dependency on org-level runner containers.

> [!NOTE]
> **Runner architecture:** `project_runner` (Layer 2) owns the entire runner lifecycle for a project:
> runner group/agent pool creation + ACA Environment + ACA Job registration.
> `repo_runner` (Layer 3, optional) creates dedicated ACA Jobs for repos needing isolated runners,
> reusing the project's ACA Environment and runner group/agent pool.
>
> **Cost model:** ACA Environment has no cost when idle. ACA Jobs are event-driven (scale-to-zero) and
> only incur cost when CI jobs are actually running. This makes per-project runner provisioning practical
> with near-zero idle cost.

**Deployed resources (GitHub):**

| Resource                      | Terraform Type                                  | Purpose                                                                     |
| ----------------------------- | ----------------------------------------------- | --------------------------------------------------------------------------- |
| Runner group                  | `github_actions_runner_group`                   | Per-project runner isolation — controls which repos can use these runners   |
| ACA Environment               | `azurerm_container_app_environment`             | Runs the project's self-hosted runner Jobs in the project's network context |
| ACA Environment DNS zone link | `azurerm_private_dns_zone_virtual_network_link` | Links the ACA internal DNS to the project's VNet                            |
| ACA Job (GitHub runner)       | `azurerm_container_app_job`                     | Self-hosted runner job pulling image from shared ACR                        |

**Deployed resources (Azure DevOps):**

| Resource                      | Terraform Type                                  | Purpose                                                                    |
| ----------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------- |
| Agent pool                    | `azuredevops_agent_pool`                        | Per-project agent pool isolation — scoped to the project's pipelines       |
| ACA Environment               | `azurerm_container_app_environment`             | Runs the project's self-hosted agent Jobs in the project's network context |
| ACA Environment DNS zone link | `azurerm_private_dns_zone_virtual_network_link` | Links the ACA internal DNS to the project's VNet                           |
| ACA Job (ADO agent)           | `azurerm_container_app_job`                     | Self-hosted agent job pulling image from shared ACR                        |

---

## 6. Layer 3: Repo LZ Sub-Modules (devops-repo-lz)

The Repo LZ provisions individual repositories and their environments. Each repository gets its own Terraform state, enabling independent lifecycle management.

### Layer 3 — Consolidated Resource Inventory (per repository)

| #   | Resource                                     | Terraform Type / Platform                                                        | Sub-Module          |
| --- | -------------------------------------------- | -------------------------------------------------------------------------------- | ------------------- |
| 1   | GitHub Repository / ADO Git Repository       | `github_repository` / `azuredevops_git_repository`                               | `repo_repository`   |
| 2   | Branch protection / policies                 | `github_branch_protection_v3` / `azuredevops_branch_policy_*`                    | `repo_repository`   |
| 3   | GitHub Environment / ADO Environment (×N)    | `github_repository_environment` / `azuredevops_environment`                      | `repo_environment`  |
| 4   | Deployment protection rules / approvals (×N) | `github_repository_environment_deployment_policy` / `azuredevops_check_approval` | `repo_environment`  |
| 5   | Environment secrets / service connections    | `github_actions_environment_secret` / `azuredevops_serviceendpoint_azurerm`      | `repo_environment`  |
| 6   | Workflow YAML / pipeline definitions         | `github_repository_file` / `azuredevops_build_definition`                        | `repo_workflow_gen` |
| 7   | ACA Job (dedicated runner, optional)         | `azurerm_container_app_job`                                                      | `repo_runner`       |

**Total: 0 Resource Groups (uses VCS APIs + optionally Project RG from Layer 2), ~7+ resources per repository (N = number of environments).**

### Sub-Modules

| Sub-Module          | Responsibility                                                         | Platform-Agnostic? | Status |
| ------------------- | ---------------------------------------------------------------------- | ------------------ | ------ |
| `repo_repository`   | Abstract: Repository creation + branch protection                      | No (dispatches)    | New    |
| `repo_environment`  | Abstract: Environment creation + protection rules + UAMI binding       | No (dispatches)    | New    |
| `repo_runner`       | Abstract: Per-repo runner registration (optional, for dedicated pools) | No (dispatches)    | New    |
| `repo_workflow_gen` | CI/CD workflow/pipeline generation (profile-driven)                    | No (dispatches)    | New    |

### `repo_repository` — Abstract Module

Creates a repository with uniform interface regardless of VCS platform:

```hcl
module "repo_repository" {
  source       = "./modules/repo_repository"
  vcs_provider = var.vcs_provider   # "github" | "azuredevops"

  # Uniform inputs
  project_name       = var.project_name
  repo_name          = var.repo_name
  visibility         = var.visibility           # "private" | "internal" | "public"
  profile            = var.profile              # "infra" | "app" | "library" | "docs"
  default_branch     = var.default_branch       # "main"
  branch_protection  = var.branch_protection    # rules object
}
```

Internally dispatches to:

- `modules/repo_repository/github.tf` — `github_repository` + `github_branch_protection_v3`
- `modules/repo_repository/azuredevops.tf` — `azuredevops_git_repository` + branch policies

**Deployed resources (GitHub):**

| Resource            | Terraform Type                 | Purpose                                                  |
| ------------------- | ------------------------------ | -------------------------------------------------------- |
| GitHub Repository   | `github_repository`            | Project's source repository with standard file layout    |
| Branch protection   | `github_branch_protection_v3`  | Enforce branch protection rules (reviews, status checks) |
| Repository settings | `github_repository` attributes | Visibility, merge settings, features, template config    |

**Deployed resources (Azure DevOps):**

| Resource           | Terraform Type                | Purpose                                                 |
| ------------------ | ----------------------------- | ------------------------------------------------------- |
| ADO Git Repository | `azuredevops_git_repository`  | Project's source repository                             |
| Branch policies    | `azuredevops_branch_policy_*` | Enforce branch protection (reviewers, build validation) |

**Outputs:** `repo_id`, `repo_url`, `repo_full_name`

### `repo_environment` — Abstract Module

Creates deployment environments with protection rules:

```hcl
module "repo_environment" {
  source       = "./modules/repo_environment"
  vcs_provider = var.vcs_provider

  # Uniform inputs
  project_name     = var.project_name
  repo_name        = var.repo_name
  environment_name = each.key           # "dev", "staging", "prod"
  subscription_id  = each.value.subscription_id
  uami_plan_id     = each.value.uami_plan_id
  uami_apply_id    = each.value.uami_apply_id
  reviewers        = each.value.reviewers       # list of reviewer team/user IDs
  wait_timer       = each.value.wait_timer      # minutes (0 = no wait)
}
```

Internally dispatches to:

- `modules/repo_environment/github.tf` — `github_repository_environment` + deployment protection rules
- `modules/repo_environment/azuredevops.tf` — `azuredevops_environment` + approvals + checks

**Deployed resources (GitHub):**

| Resource                    | Terraform Type                                    | Purpose                                                    |
| --------------------------- | ------------------------------------------------- | ---------------------------------------------------------- |
| GitHub Environment          | `github_repository_environment`                   | Deployment target bound to repo (dev, staging, prod, etc.) |
| Deployment protection rules | `github_repository_environment_deployment_policy` | Reviewer requirements, wait timer, branch restrictions     |
| Environment secrets         | `github_actions_environment_secret`               | OIDC client ID and subscription ID for the env UAMI        |

**Deployed resources (Azure DevOps):**

| Resource           | Terraform Type                        | Purpose                                             |
| ------------------ | ------------------------------------- | --------------------------------------------------- |
| ADO Environment    | `azuredevops_environment`             | Deployment target for ADO pipelines                 |
| Approval checks    | `azuredevops_check_approval`          | Reviewer requirements before deployment             |
| Service connection | `azuredevops_serviceendpoint_azurerm` | OIDC-based service connection bound to the env UAMI |

**Outputs:** `environment_id`, `environment_name`

### `repo_workflow_gen`

Generates profile-driven CI/CD workflow or pipeline files.

**Deployed resources (GitHub):**

| Resource            | Terraform Type           | Purpose                                                            |
| ------------------- | ------------------------ | ------------------------------------------------------------------ |
| Workflow YAML files | `github_repository_file` | Standardized plan/apply workflows targeting the (env × job) matrix |

**Deployed resources (Azure DevOps):**

| Resource             | Terraform Type                 | Purpose                                                    |
| -------------------- | ------------------------------ | ---------------------------------------------------------- |
| Pipeline definitions | `azuredevops_build_definition` | YAML pipeline definitions targeting the (env × job) matrix |

### `repo_runner` (optional) — Abstract Module

For repos that need a dedicated runner (rather than sharing the project-level runner):

```hcl
module "repo_runner" {
  source       = "./modules/repo_runner"
  vcs_provider = var.vcs_provider

  project_name  = var.project_name
  repo_name     = var.repo_name
  aca_env_id    = var.aca_environment_id
  runner_labels = ["self-hosted", var.project_name, var.repo_name]
}
```

**Deployed resources:** Dedicated ACA Job scoped to a single repository, registered in the project's runner group/agent pool (uses the ACA Environment and runner group/agent pool created by `project_runner` in Layer 2).

---

## 7. Abstract Module Pattern

All abstract (VCS-dispatching) modules (e.g., `repo_repository`, `repo_environment`, `repo_runner`, `project_runner`) follow this pattern:

```text
modules/<module_name>/
├── _variables.tf         # Uniform input contract (includes vcs_provider)
├── _outputs.tf           # Uniform output contract
├── main.tf               # Dispatch logic (count/for_each on vcs_provider)
├── github.tf             # GitHub implementation (count = vcs_provider == "github" ? 1 : 0)
└── azuredevops.tf        # ADO implementation (count = vcs_provider == "azuredevops" ? 1 : 0)
```

**Key rules:**

- The caller sees **only** `_variables.tf` inputs and `_outputs.tf` outputs.
- GitHub-specific and ADO-specific resources use `count` gated on `vcs_provider`.
- No provider block inside sub-modules — providers are passed by the root module.
- Output values are unified: e.g., `repo_id` returns the GitHub repo ID or the ADO repo ID depending on which was created.

---

## 8. Module Composition Diagram

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ bootstrap (Layer 0 Root Module — once per organization)                  │
│                                                                         │
│  ┌──────────┐                                                           │
│  │bootstrap │                                                           │
│  └──────────┘                                                           │
└─────────────────────────────────────────────────────────────────────────┘
                              │ bootstrap.config.json
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ devops-org-lz (Layer 1 Root Module)                                         │
│                                                                              │
│  ┌─────────┐ ┌─────────┐ ┌───────────────┐ ┌──────────────┐               │
│  │org_vnet  │ │org_acr  │ │org_governance │ │org_devcenter │               │
│  └─────────┘ └─────────┘ └───────────────┘ └──────────────┘               │
└──────────────────────────────────────────────────────────────────────────────┘
                              │ remote_state
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-project-lz (Layer 2 Root Module — one per project)                │
│                                                                         │
│  ┌─────────────┐ ┌────────────────┐ ┌───────────────┐                 │
│  │project_state│ │project_identity│ │project_network│                 │
│  └─────────────┘ └────────────────┘ └───────────────┘                 │
│  ┌──────────────┐ ┌────────────────┐                                   │
│  │project_devbox│ │ project_runner │                                    │
│  └──────────────┘ └────────────────┘                                   │
└─────────────────────────────────────────────────────────────────────────┘
                              │ remote_state
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-repo-lz (Layer 3 Root Module — one per repository)                │
│                                                                         │
│  ┌───────────────┐ ┌────────────────┐ ┌───────────────┐ ┌─────────────────────┐ │
│  │repo_repository│ │repo_environment│ │repo_workflow_gen│ │repo_runner (optional)│ │
│  └───────────────┘ └────────────────┘ └───────────────┘ └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. Implementation Plan

### Phase 1 — Platform-agnostic project sub-modules

| Priority | Module             | Dependencies                   |
| -------- | ------------------ | ------------------------------ |
| 1        | `project_state`    | None (pure Azure)              |
| 2        | `project_identity` | None (pure Azure)              |
| 3        | `project_network`  | Org LZ VNet outputs            |
| 4        | `project_devbox`   | `project_network`              |
| 5        | `project_runner`   | `project_network`, VCS context |

### Phase 2 — Abstract repo/environment sub-modules

| Priority | Module              | Dependencies                            |
| -------- | ------------------- | --------------------------------------- |
| 1        | `repo_repository`   | VCS provider config                     |
| 2        | `repo_environment`  | `project_identity` (UAMIs)              |
| 3        | `repo_runner`       | `project_runner` (repo-level, optional) |
| 4        | `repo_workflow_gen` | `repo_repository`                       |

### Phase 3 — Org-level governance

| Priority | Module           | Dependencies        |
| -------- | ---------------- | ------------------- |
| 1        | `org_governance` | VCS provider config |

### Sequencing

1. Implement `project_state` + `project_identity` + `project_network` first (pure Azure, no VCS dependency).
2. Implement `project_devbox` + `project_runner` (project-level compute; `project_runner` includes ACA Environment).
3. Implement `repo_repository` + `repo_environment` + `repo_workflow_gen` (abstract VCS modules for Layer 3).
4. Implement `org_governance` (abstract governance for Layer 1).
5. Compose into root modules (`project_github`, `project_azuredevops`, `repo_github`, `repo_azuredevops`).

---

> **Related documents:**
>
> - [Target Architecture Spec](./Target-Architecture-Spec.md) — overall architecture overview
> - [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md) — resource scoping decisions
> - [ADR-003](./adr/ADR-003-project-multi-repo-model.md) — project model and identity
> - [ADR-004](./adr/ADR-004-github-ado-abstraction.md) — GitHub/ADO abstraction
