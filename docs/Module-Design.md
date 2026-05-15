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

1. **Abstract over VCS platform** — Sub-modules like `project_repo`, `environment`, and `runner` accept a `vcs_provider` input (`"github"` or `"azuredevops"`) and internally dispatch to the correct implementation. Callers get a uniform input/output contract.

2. **Single responsibility** — Each sub-module owns exactly one domain concept (e.g., project state storage, project identity, repository provisioning, environment binding).

3. **Platform-agnostic where possible** — Modules dealing with pure Azure resources (`project_state`, `project_identity`, `project_network`, `aca_env`) work identically for both GitHub and Azure DevOps projects.

4. **VCS-specific only where necessary** — Modules that interact with VCS APIs (`project_repo`, `environment`, `runner`) use the abstract dispatch pattern.

5. **Composable, not nested** — Sub-modules do not call each other. Root modules (`project_github`, `repo_github`, etc.) compose sub-modules and pass outputs between them.

6. **Consistent interface** — All abstract modules share a common variable pattern: `vcs_provider`, `project_name`, and domain-specific inputs.

---

## 3. Layer 0: Bootstrap Sub-Modules (bootstrap)

The Bootstrap layer creates the foundational state backend and secret store for the entire DevOps Landing Zone. It is applied **once** per organization (rarely re-applied) and uses a local state file that is migrated to the Storage Account it creates.

| Sub-Module  | Responsibility                                | Platform-Agnostic? | Status   |
| ----------- | --------------------------------------------- | ------------------ | -------- |
| `bootstrap` | RG + Storage Account + Key Vault + CMK + UAMI | Yes                | Existing |

### `bootstrap`

Creates the Layer 1 state backend and its protection chain.

**Deployed resources:**

| Resource                         | Terraform Type                   | Purpose                                                                                                |
| -------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Bootstrap Resource Group         | `azurerm_resource_group`         | Container for all bootstrap resources; lifecycle anchor for Layer 1 state backend                      |
| Layer 1 Storage Account          | `azurerm_storage_account`        | Stores Layer 1 tfstate for bootstrap, Org LZ, Project LZ, and Repo LZ (blob versioning + immutability) |
| `tfstate` blob containers        | `azurerm_storage_container`      | Per-module tfstate containers (bootstrap, lz, project\_\*, repos/\*)                                   |
| Bootstrap Key Vault              | `azurerm_key_vault`              | Holds the CMK used to encrypt the Layer 1 SA; purge-protected, RBAC authorization                      |
| `tfbackend_cmk` Key              | `azurerm_key_vault_key`          | RSA key encrypting the Layer 1 Storage Account (defense in depth for tfstate)                          |
| Bootstrap UAMI                   | `azurerm_user_assigned_identity` | Identity granted CMK access (`Storage Account → Key Vault` encryption chain)                           |
| `azurerm.tfbackend` config files | `local_file`                     | Generated Terraform backend config templates for all downstream layers                                 |

**Outputs:** `storage_account_name`, `storage_account_id`, `key_vault_id`, `key_vault_uri`, `resource_group_name`, `bootstrap_config_json` (consumed by all downstream layers).

---

## 4. Layer 1: Organization LZ Sub-Modules (devops-org-lz)

The Org LZ is a single root module that uses existing and new sub-modules to provision organization-wide shared infrastructure.

| Sub-Module           | Responsibility                                            | Platform-Agnostic? | Status   |
| -------------------- | --------------------------------------------------------- | ------------------ | -------- |
| `vnet`               | Platform VNet + subnets + NAT Gateway + Private DNS zones | Yes                | Existing |
| `acr`                | Azure Container Registry + image build tasks              | Yes                | Existing |
| `org_governance`     | Org-level rulesets, runner groups, agent pools            | No (dispatches)    | New      |
| `devcenter`          | Dev Center + Dev Box Definitions (org catalog)            | Yes                | New      |

> [!NOTE]
> `resource_providers` is intentionally **not** modularized in the target design.
> Resource provider registrations are managed separately (outside reusable sub-modules) to avoid cross-project state ownership conflicts.

### `vnet`

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

### `acr`

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
  runner_group_name    = var.runner_group_name
  # ...
}
```

Internally dispatches to:

- `modules/org_governance/github.tf` — GitHub org rulesets + runner groups
- `modules/org_governance/azuredevops.tf` — ADO branch policies + agent pools

**Deployed resources (GitHub):**

| Resource            | Terraform Type                            | Purpose                                                   |
| ------------------- | ----------------------------------------- | --------------------------------------------------------- |
| Org-level rulesets  | `github_organization_ruleset`             | Enforce branch protection and required workflows org-wide |
| Runner groups       | `github_actions_runner_group`             | Per-project runner isolation at the organization level    |
| Repository defaults | `github_actions_organization_permissions` | Default Actions permissions for new repositories          |

**Deployed resources (Azure DevOps):**

| Resource         | Terraform Type                 | Purpose                               |
| ---------------- | ------------------------------ | ------------------------------------- |
| Agent pools      | `azuredevops_agent_pool`       | Per-project agent pool isolation      |
| Branch policies  | `azuredevops_branch_policy_*`  | Enforce branch protection org-wide    |
| Project settings | `azuredevops_project_features` | Default project feature configuration |

### `devcenter`

Creates the organization-wide Dev Center and Dev Box catalog.

**Deployed resources:**

| Resource              | Terraform Type                          | Purpose                                                     |
| --------------------- | --------------------------------------- | ----------------------------------------------------------- |
| Dev Center            | `azurerm_dev_center`                    | Org-wide control plane for developer Dev Boxes              |
| Dev Box Definitions   | `azurerm_dev_center_dev_box_definition` | Per-image/per-SKU Dev Box definitions (catalog)             |
| DevBox RG             | `azurerm_resource_group`                | Hosts the Dev Center and definitions                        |
| Identity RG           | `azurerm_resource_group`                | Org-level container for project UAMIs (populated at Tier 2) |
| KV secrets (VCS PATs) | `azurerm_key_vault_secret`              | VCS PATs stored in bootstrap KV for project provisioning    |

---

## 5. Layer 2: Project LZ Sub-Modules (devops-project-lz)

The Project LZ provisions per-project infrastructure. It does **not** create repositories or environments — those belong to Layer 3.

| Sub-Module         | Responsibility                                                           | Platform-Agnostic? | Status   |
| ------------------ | ------------------------------------------------------------------------ | ------------------ | -------- |
| `project_state`    | Layer 2 Storage Account + Project Key Vault + Project RG                 | Yes                | New      |
| `project_identity` | 7 UAMIs + OIDC federated credentials + subscription RBAC                 | Yes                | New      |
| `project_network`  | Subnet slice (platform mode) or BYO VNet validation                      | Yes                | New      |
| `aca_env`          | ACA Environment bound to project's network context                       | Yes                | Existing |
| `devbox_project`   | DevCenter Project + Dev Box Pool + Network Connection                    | Yes                | New      |
| `runner`           | ACA job definition registered with GitHub runner group or ADO agent pool | No (dispatches)    | New      |

### `project_state`

Creates per-project state infrastructure.

**Deployed resources:**

| Resource                 | Terraform Type                                  | Purpose                                                                                |
| ------------------------ | ----------------------------------------------- | -------------------------------------------------------------------------------------- |
| Project Resource Group   | `azurerm_resource_group`                        | Houses all project-owned resources in the platform subscription                        |
| Layer 2 Storage Account  | `azurerm_storage_account`                       | Stores Layer 2 tfstate for project's own app IaC (LRS default, selectable replication) |
| Layer 2 blob containers  | `azurerm_storage_container`                     | Per-workspace tfstate containers for the project team                                  |
| Project Key Vault        | `azurerm_key_vault`                             | Project-owned secrets and keys (distinct from bootstrap KV)                            |
| Layer 2 Private Endpoint | `azurerm_private_endpoint`                      | Private connectivity to the Layer 2 SA from the project's runner network               |
| Layer 2 PE DNS zone link | `azurerm_private_dns_zone_virtual_network_link` | Links the project's VNet to platform DNS zones for PE resolution                       |

### `project_identity`

Creates the 7 project-scoped UAMIs.

**Deployed resources:**

| Resource                        | Terraform Type                          | Purpose                                                                                                                             |
| ------------------------------- | --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 7 Project UAMIs                 | `azurerm_user_assigned_identity`        | Per-environment, per-job-type identities (`feat-plan`, `dev-plan`, `stg-plan`, `prod-plan`, `dev-apply`, `stg-apply`, `prod-apply`) |
| OIDC Federated Credentials (×7) | `azurerm_federated_identity_credential` | Trust VCS environment to mint Azure tokens per (env × job)                                                                          |
| Subscription role assignments   | `azurerm_role_assignment`               | Conditional RBAC on env subscription (only when subscription is declared)                                                           |

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

### `aca_env`

Creates a project-scoped ACA Environment.

**Deployed resources:**

| Resource                      | Terraform Type                                  | Purpose                                                                     |
| ----------------------------- | ----------------------------------------------- | --------------------------------------------------------------------------- |
| ACA Environment               | `azurerm_container_app_environment`             | Runs the project's self-hosted runner Jobs in the project's network context |
| ACA Environment DNS zone link | `azurerm_private_dns_zone_virtual_network_link` | Links the ACA internal DNS to the project's VNet                            |

### `devbox_project`

Creates DevCenter project resources.

**Deployed resources:**

| Resource                 | Terraform Type                          | Purpose                                                                  |
| ------------------------ | --------------------------------------- | ------------------------------------------------------------------------ |
| DevCenter Project        | `azurerm_dev_center_project`            | Project-scoped Dev Box catalog reference (links to org-level Dev Center) |
| Dev Box Pool             | `azurerm_dev_center_project_pool`       | Pool for the project's developer Dev Boxes                               |
| Network Connection       | `azurerm_dev_center_network_connection` | Binds the pool to the project's runner network context                   |
| Dev Box role assignments | `azurerm_role_assignment`               | Grants project team access to provision and manage Dev Boxes             |

### `runner` — Abstract Module

Abstract module for CI/CD runner registration.

**Deployed resources (GitHub):**

| Resource                | Terraform Type                | Purpose                                                  |
| ----------------------- | ----------------------------- | -------------------------------------------------------- |
| ACA Job (GitHub runner) | `azurerm_container_app_job`   | Self-hosted runner job pulling image from shared ACR     |
| Runner group membership | `github_actions_runner_group` | Routes project CI jobs to the project's own runner group |

**Deployed resources (Azure DevOps):**

| Resource                | Terraform Type                       | Purpose                                                  |
| ----------------------- | ------------------------------------ | -------------------------------------------------------- |
| ACA Job (ADO agent)     | `azurerm_container_app_job`          | Self-hosted agent job pulling image from shared ACR      |
| Agent pool registration | `azuredevops_agent_pool` (reference) | Routes project pipelines to the project's own agent pool |

---

## 6. Layer 3: Repo LZ Sub-Modules (devops-repo-lz)

The Repo LZ provisions individual repositories and their environments. Each repository gets its own Terraform state, enabling independent lifecycle management.

| Sub-Module     | Responsibility                                                         | Platform-Agnostic? | Status |
| -------------- | ---------------------------------------------------------------------- | ------------------ | ------ |
| `project_repo` | Abstract: Repository creation + branch protection                      | No (dispatches)    | New    |
| `environment`  | Abstract: Environment creation + protection rules + UAMI binding       | No (dispatches)    | New    |
| `runner`       | Abstract: Per-repo runner registration (optional, for dedicated pools) | No (dispatches)    | New    |
| `workflow_gen` | CI/CD workflow/pipeline generation (profile-driven)                    | No (dispatches)    | New    |

### `project_repo` — Abstract Module

Creates a repository with uniform interface regardless of VCS platform:

```hcl
module "repo" {
  source       = "./modules/project_repo"
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

- `modules/project_repo/github.tf` — `github_repository` + `github_branch_protection_v3`
- `modules/project_repo/azuredevops.tf` — `azuredevops_git_repository` + branch policies

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

### `environment` — Abstract Module

Creates deployment environments with protection rules:

```hcl
module "env" {
  source       = "./modules/environment"
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

- `modules/environment/github.tf` — `github_repository_environment` + deployment protection rules
- `modules/environment/azuredevops.tf` — `azuredevops_environment` + approvals + checks

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

### `workflow_gen`

Generates profile-driven CI/CD workflow or pipeline files.

**Deployed resources (GitHub):**

| Resource            | Terraform Type           | Purpose                                                            |
| ------------------- | ------------------------ | ------------------------------------------------------------------ |
| Workflow YAML files | `github_repository_file` | Standardized plan/apply workflows targeting the (env × job) matrix |

**Deployed resources (Azure DevOps):**

| Resource             | Terraform Type                 | Purpose                                                    |
| -------------------- | ------------------------------ | ---------------------------------------------------------- |
| Pipeline definitions | `azuredevops_build_definition` | YAML pipeline definitions targeting the (env × job) matrix |

### `runner` (Repo-level, optional)

For repos that need a dedicated runner (rather than sharing the project-level runner group):

```hcl
module "runner" {
  source       = "./modules/runner"
  vcs_provider = var.vcs_provider

  project_name  = var.project_name
  repo_name     = var.repo_name
  aca_env_id    = var.aca_environment_id
  runner_labels = ["self-hosted", var.project_name, var.repo_name]
}
```

**Deployed resources:** Same as the Layer 2 `runner` module (ACA Job + runner group/agent pool registration) but scoped to a single repository.

---

## 7. Abstract Module Pattern

All abstract (VCS-dispatching) modules follow this pattern:

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
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-org-lz (Layer 1 Root Module)                                      │
│                                                                         │
│  ┌──────┐ ┌─────┐ ┌───────────────┐ ┌──────────┐                      │
│  │ vnet │ │ acr │ │org_governance │ │devcenter │                      │
│  └──────┘ └─────┘ └───────────────┘ └──────────┘                      │
└─────────────────────────────────────────────────────────────────────────┘
                              │ remote_state
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-project-lz (Layer 2 Root Module — one per project)                │
│                                                                         │
│  ┌─────────────┐ ┌────────────────┐ ┌───────────────┐ ┌─────────────┐ │
│  │project_state│ │project_identity│ │project_network│ │   aca_env   │ │
│  └─────────────┘ └────────────────┘ └───────────────┘ └─────────────┘ │
│  ┌──────────────┐ ┌────────────────┐                                   │
│  │devbox_project│ │    runner      │                                    │
│  └──────────────┘ └────────────────┘                                   │
└─────────────────────────────────────────────────────────────────────────┘
                              │ remote_state
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-repo-lz (Layer 3 Root Module — one per repository)                │
│                                                                         │
│  ┌────────────┐ ┌─────────────┐ ┌────────────┐ ┌────────────────────┐ │
│  │project_repo│ │ environment │ │workflow_gen│ │ runner (optional)  │ │
│  └────────────┘ └─────────────┘ └────────────┘ └────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. Implementation Plan

### Phase 1 — Platform-agnostic project sub-modules

| Priority | Module             | Dependencies           |
| -------- | ------------------ | ---------------------- |
| 1        | `project_state`    | None (pure Azure)      |
| 2        | `project_identity` | None (pure Azure)      |
| 3        | `project_network`  | Org LZ VNet outputs    |
| 4        | `aca_env`          | `project_network`      |
| 5        | `devbox_project`   | `project_network`      |
| 6        | `runner`           | `aca_env`, VCS context |

### Phase 2 — Abstract repo/environment sub-modules

| Priority | Module         | Dependencies                     |
| -------- | -------------- | -------------------------------- |
| 1        | `project_repo` | VCS provider config              |
| 2        | `environment`  | `project_identity` (UAMIs)       |
| 3        | `runner`       | `aca_env` (repo-level, optional) |

### Phase 3 — Org-level governance

| Priority | Module           | Dependencies        |
| -------- | ---------------- | ------------------- |
| 1        | `org_governance` | VCS provider config |

### Sequencing

1. Implement `project_state` + `project_identity` + `project_network` first (pure Azure, no VCS dependency).
2. Implement `aca_env` + `devbox_project` + `runner` (project-level compute).
3. Implement `project_repo` + `environment` (abstract VCS modules for Tier 3).
4. Implement `org_governance` (abstract governance for Tier 1).
5. Compose into root modules (`project_github`, `project_azuredevops`, `repo_github`, `repo_azuredevops`).

---

> **Related documents:**
>
> - [Target Architecture Spec](./Target-Architecture-Spec.md) — overall architecture overview
> - [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md) — resource scoping decisions
> - [ADR-003](./adr/ADR-003-project-multi-repo-model.md) — project model and identity
> - [ADR-004](./adr/ADR-004-github-ado-abstraction.md) — GitHub/ADO abstraction
