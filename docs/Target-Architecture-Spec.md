# Target Architecture Specification (DRAFT)

> **Status:** Draft v0.1 — for discussion and feedback
>
> **Scope:** Redesign of the DevOps Landing Zone to support real-world organizations, multi-repo projects, and Bring Your Own VNet.

---

## Table of Contents

1. [Motivation & Problem Summary](#1-motivation--problem-summary)
2. [Target Hierarchy & Vocabulary](#2-target-hierarchy--vocabulary)
3. [Module & Directory Structure (Target)](#3-module--directory-structure-target)
4. [Organization-Level Landing Zone (`devops/lz`)](#4-organization-level-landing-zone-devopslz)
5. [Project Definition & Multi-Repo Model (`devops/project_github`)](#5-project-definition--multi-repo-model-devopsproject_github)
6. [Bring Your Own VNet (BYO VNet)](#6-bring-your-own-vnet-byo-vnet)
7. [Organization-Level Governance](#7-organization-level-governance)
8. [Operational Model — Portfolio Onboarding](#8-operational-model--portfolio-onboarding)
9. [Naming, State & Collision Resistance](#9-naming-state--collision-resistance)
10. [Migration Path from Current Design](#10-migration-path-from-current-design)
11. [Open Questions](#11-open-questions)

---

## 1. Motivation & Problem Summary

### Current state

| Area | Today | Gap |
|------|-------|-----|
| **Organization concept** | GitHub org name is passed as a string; no governance boundary | No formalized org-level resources, policies, or runner governance |
| **Project model** | 1 project = 1 main repo + optional templates repo | Real projects often have multiple repos (infra, app, data, ops, shared libs) |
| **Network / VNet** | Platform always creates a new VNet from address-prefix inputs | No option to plug into an existing (enterprise-provided) VNet |
| **Portfolio onboarding** | Each project provisioned via separate `terraform apply` | No catalog / definition pattern for repeated onboarding |
| **Documentation** | Paths reference `infra/terraform/…` while code lives under `infra/…` | Confusing for adopters |

### Goals

1. Define a clear **Organization → Project → Repository Set → Environments** hierarchy.
2. Allow a project to own **multiple repositories** with different profiles.
3. Support **"Bring Your Own VNet"** alongside the existing platform-managed VNet.
4. Strengthen **organization-level governance** (policies, rulesets, runner governance).
5. Provide a repeatable **portfolio onboarding** pattern.
6. Keep backward compatibility for current single-repo users.

---

## 2. Target Hierarchy & Vocabulary

```text
┌────────────────────────────────────────────────────────────────────┐
│  Organization (GitHub Org / Azure DevOps Org)                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Platform Landing Zone  (devops/lz)                         │  │
│  │  • Bootstrap (storage, key vault)                           │  │
│  │  • Shared identity RG                                       │  │
│  │  • Shared agents RG (ACR, ACA env, Log Analytics)           │  │
│  │  • Network RG  (platform-managed VNet OR hub resources)     │  │
│  │  • DevBox Dev Center                                        │  │
│  │  • Org-level GitHub rulesets, runner groups, team baselines  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌── Project A ──────────────────────────────────────────────────┐ │
│  │  project_name = "project-a"                                   │ │
│  │  repositories = [                                             │ │
│  │    { name="project-a-infra",  profile="infra"  },             │ │
│  │    { name="project-a-app",    profile="app"    },             │ │
│  │    { name="project-a-data",   profile="app"    },             │ │
│  │  ]                                                            │ │
│  │  network_mode = "platform"  (use LZ-managed VNet)             │ │
│  │  subscriptions = { features, dev, staging, prod }             │ │
│  │  identities (UAMI per env × job)                              │ │
│  │  runners  (ACA jobs or ACI)                                   │ │
│  │  DevBox project pool                                          │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  ┌── Project B ──────────────────────────────────────────────────┐ │
│  │  project_name = "project-b"                                   │ │
│  │  repositories = [                                             │ │
│  │    { name="project-b", profile="infra" },                     │ │
│  │  ]                                                            │ │
│  │  network_mode = "byo"                                         │ │
│  │  byo_vnet = { vnet_id, private_endpoint_subnet_id, ... }      │ │
│  │  subscriptions = { dev, prod }                                │ │
│  └───────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### Key terms

| Term | Definition |
|------|-----------|
| **Organization** | The top-level governance boundary — maps to a GitHub Organization (or Azure DevOps Org). Owns shared infrastructure and policies. |
| **Platform Landing Zone** | The shared infrastructure layer (`devops/lz`) provisioned once per organization: bootstrap resources, identity RG, agents/runners RG, network RG, Dev Center. |
| **Project** | A logical grouping of repositories, environments, identities, and runner jobs that together deliver one product or workload. A project maps to one `terraform apply` of `devops/project_github`. |
| **Repository Set** | The ordered list of Git repositories that belong to a project. Each repo has a **profile** that determines its CI/CD workflow shape. |
| **Repository Profile** | A template that defines the branch strategy, workflow files, environments, and identity needs for a class of repository (e.g., `infra`, `app`, `library`). |
| **Environment** | A deployment target — maps 1:1 to an Azure subscription and a GitHub Actions Environment with OIDC-federated UAMI. |
| **Network Mode** | How the project connects to Azure networking: `platform` (use the LZ-managed VNet) or `byo` (Bring Your Own VNet). |

---

## 3. Module & Directory Structure (Target)

```text
infra/
├── _bootstrap/                         # (unchanged) Storage + Key Vault
├── _setup_subscriptions/               # (unchanged) resource provider registration
├── devops/
│   ├── lz/                             # Organization-level Landing Zone
│   │   ├── _variables.tf
│   │   ├── _variables.network.tf
│   │   ├── _variables.vcs.github.tf
│   │   ├── _variables.governance.tf    # ← NEW: org-level policies & rulesets
│   │   ├── _outputs.tf
│   │   ├── network.vnet.tf             # platform-managed VNet (unchanged)
│   │   ├── governance.tf               # ← NEW: org-level rulesets, runner groups
│   │   └── ...
│   │
│   └── project_github/                 # Per-project resources
│       ├── _variables.tf               # CHANGED: add repositories list, network_mode
│       ├── _variables.network.tf       # ← NEW: BYO VNet inputs
│       ├── _variables.repositories.tf  # ← NEW: multi-repo definition
│       ├── github.tf                   # CHANGED: iterate over repositories
│       ├── github.workflow.tf          # CHANGED: per-repo workflow generation
│       ├── uami.tf                     # CHANGED: per-repo × per-env identities
│       ├── uami.federation.tf
│       ├── network.tf                  # ← NEW: BYO VNet data lookups & validation
│       └── ...
│
└── modules/
    ├── github/                         # CHANGED: accept list of repositories
    │   ├── repo.main.tf                # → repo.tf  (for_each over repositories)
    │   ├── repo.templates.tf           # (unchanged; still one templates repo per project)
    │   └── ...
    ├── github_workflows/               # CHANGED: generate per-profile workflows
    │   ├── _variables.tf               # add repository_profiles input
    │   └── ...
    ├── vnet/                           # (unchanged)
    └── ...                             # (other modules unchanged)
```

---

## 4. Organization-Level Landing Zone (`devops/lz`)

### 4.1 What stays the same

- Bootstrap resources (Storage Account, Key Vault)
- Identity resource group (shared across projects)
- Agents resource group (ACR, ACA environment, Log Analytics)
- Network resource group and platform-managed VNet creation
- Dev Center and DevBox definitions
- Container image build tasks

### 4.2 What changes

#### 4.2.1 Governance outputs (NEW)

The LZ will expose organizational governance settings that projects inherit:

```hcl
# New file: devops/lz/_variables.governance.tf

variable "org_default_branch_rules" {
  description = "Default branch protection rules applied to all project repositories"
  type = object({
    require_pull_request   = optional(bool, true)
    required_review_count  = optional(number, 1)
    require_status_checks  = optional(bool, true)
    dismiss_stale_reviews  = optional(bool, true)
    require_code_owners    = optional(bool, false)
  })
  default = {}
}

variable "org_runner_group_defaults" {
  description = "Default runner group configuration for the organization"
  type = object({
    visibility             = optional(string, "selected")
    allows_public_repos    = optional(bool, false)
  })
  default = {}
}

variable "org_repository_defaults" {
  description = "Default settings for all repositories in the organization"
  type = object({
    default_visibility            = optional(string, "private")
    delete_branch_on_merge        = optional(bool, true)
    allow_squash_merge            = optional(bool, true)
    allow_merge_commit            = optional(bool, true)
    allow_rebase_merge            = optional(bool, false)
    vulnerability_alerts_enabled  = optional(bool, true)
  })
  default = {}
}
```

#### 4.2.2 New outputs for project consumption

```hcl
# Additions to devops/lz/_outputs.tf

output "org_governance" {
  value = {
    default_branch_rules    = var.org_default_branch_rules
    runner_group_defaults   = var.org_runner_group_defaults
    repository_defaults     = var.org_repository_defaults
  }
  description = "Organization-level governance defaults inherited by projects"
}

output "network_mode_info" {
  value = {
    platform_vnet_id                = length(module.vnet) > 0 ? module.vnet[0].output.vnet_id : null
    platform_vnet_name              = length(module.vnet) > 0 ? local.vnet_name : null
    platform_vnet_resource_group    = local.enable_network_resources ? local.network_resource_group_name : null
    platform_private_endpoint_subnet_id  = local.private_endpoint_subnet_id
    platform_aca_subnet_id               = local.container_app_subnet_id
    platform_aci_subnet_id               = local.container_instance_subnet_id
    platform_devbox_subnet_id            = local.devbox_subnet_id
    private_dns_zone_ids            = { for index, z in azurerm_private_dns_zone.this : index => z.id }
  }
  description = "Network information for projects using platform or BYO networking"
}
```

---

## 5. Project Definition & Multi-Repo Model (`devops/project_github`)

### 5.1 Current design (single repo)

```hcl
# Today
project_name = "my-project"
# → creates 1 repo: "my-project"
# → creates 1 templates repo: "my-project-templates" (optional)
```

### 5.2 Target design (multi-repo)

```hcl
# New variable: _variables.repositories.tf

variable "repositories" {
  description = "List of repositories for this project"
  type = list(object({
    name        = string
    profile     = string          # "infra" | "app" | "library" | "docs"
    description = optional(string, "")
    visibility  = optional(string) # null → inherit org default
    settings    = optional(object({
      allow_merge_commit     = optional(bool)
      allow_squash_merge     = optional(bool)
      allow_rebase_merge     = optional(bool)
      delete_branch_on_merge = optional(bool)
      has_issues             = optional(bool, true)
      has_projects           = optional(bool, true)
      vulnerability_alerts   = optional(bool, true)
    }))
    branch_overrides = optional(map(object({
      required_review_count = optional(number)
      require_code_owners   = optional(bool)
    })))
    environments = optional(list(string))  # subset of project environments; null → all
  }))

  # Backward-compatible default: if empty, fall back to single-repo behavior
  default = []

  validation {
    condition = length(var.repositories) == 0 || length(var.repositories) == length(distinct([for r in var.repositories : r.name]))
    error_message = "Repository names must be unique within a project."
  }
}
```

#### Backward compatibility

When `repositories = []` (default), the module falls back to the current single-repo behavior using `project_name` as the repository name. This ensures zero breaking changes for existing users.

```hcl
# In _locals.tf

locals {
  # If repositories list is provided, use it; otherwise fall back to current behavior
  _repositories = length(var.repositories) > 0 ? var.repositories : [
    {
      name               = local._project_name
      profile            = "infra"
      description        = local._project_name
      visibility         = null
      settings           = null
      branch_overrides   = null
      environments       = null
    }
  ]
}
```

### 5.3 Repository profiles

Profiles define the **workflow shape** for a repository. They are defined in the `github_workflows` module and control which CI/CD workflows and branch strategies are generated.

| Profile | Branches | CI Workflow | CD Workflow | Environments |
|---------|----------|-------------|-------------|-------------|
| `infra` | `features/*`, `dev`, `staging`, `main` | `validate` + `plan` on PR | `plan` + `apply` on push | `features`, `development`, `staging`, `production` |
| `app` | `features/*`, `dev`, `staging`, `main` | `build` + `test` on PR | `build` + `deploy` on push | `development`, `staging`, `production` |
| `library` | `features/*`, `main` | `build` + `test` on PR | `publish` on tag | — |
| `docs` | `main` | — | — | — |

### 5.4 Identity (UAMI) allocation strategy

Today: one UAMI per environment × job type (plan/apply) per project.

Target: one UAMI per environment × job type (plan/apply) **per repository** (or shared per project if the user opts in).

```hcl
variable "shared_identities" {
  description = "Whether to share UAMI across all repositories in the project (true) or create per-repository identities (false)"
  type        = bool
  default     = true   # backward compatible
}
```

When `shared_identities = true`: behavior is identical to today — one set of UAMIs covers all repos in the project.

When `shared_identities = false`: each repository gets its own set of UAMIs, enabling fine-grained RBAC (e.g., the `infra` repo has `Contributor`, the `app` repo has only `AcrPush` + `Web Apps Contributor`).

### 5.5 Sample `terraform.tfvars` — multi-repo project

```hcl
# terraform.tfvars — Project "contoso-ecommerce"

target_subscription_id = "00000000-0000-0000-0000-000000000000"
project_name           = "contoso-ecommerce"
location               = "japaneast"

tags = {
  appTag     = "contoso-ecommerce"
  envTag     = "prod"
  projectTag = "devops"
  purposeTag = "alz"
}

# Multiple repositories for this project
repositories = [
  {
    name    = "contoso-ecommerce-infra"
    profile = "infra"
    description = "Azure infrastructure for the Contoso e-commerce platform"
  },
  {
    name    = "contoso-ecommerce-api"
    profile = "app"
    description = "Backend API services"
  },
  {
    name    = "contoso-ecommerce-web"
    profile = "app"
    description = "Frontend web application"
    environments = ["development", "staging", "production"]  # no features env
  },
  {
    name    = "contoso-ecommerce-shared"
    profile = "library"
    description = "Shared libraries and utilities"
  },
]

subscriptions = {
  "features" = {
    id = "11111111-1111-1111-1111-111111111111"
  },
  "development" = {
    id = "22222222-2222-2222-2222-222222222222"
  },
  "staging" = {
    id = "33333333-3333-3333-3333-333333333333"
  },
  "production" = {
    id = "44444444-4444-4444-4444-444444444444"
  },
}

# Network mode
network_mode = "platform"  # use LZ-managed VNet

# Runner options
use_templates_repository = true
use_self_hosted_runners  = true
self_hosted_runners_type = "aca"
```

---

## 6. Bring Your Own VNet (BYO VNet)

### 6.1 Problem

Today the Landing Zone always creates a fresh VNet with all required subnets. Enterprise customers often:
- Have a **hub-and-spoke** topology managed by a central networking team.
- Need DevOps resources to land in a **pre-provisioned spoke VNet** with corporate firewall rules, DNS forwarding, and peering already configured.
- Cannot use arbitrary address spaces.

### 6.2 Design

Add a `network_mode` variable that selects between two modes:

| Mode | Description | Who creates VNet? | Who provides subnet IDs? |
|------|-------------|-------------------|--------------------------|
| `platform` | Current behavior (default). The LZ creates and manages the VNet. | `devops/lz` module | `devops/lz` outputs |
| `byo` | Enterprise-provided VNet. User supplies existing subnet IDs. | External (networking team) | User input at **project level** |

### 6.3 Landing Zone changes (`devops/lz`)

No changes needed at the LZ level for the BYO mode itself — the LZ continues to create its platform VNet when `enable_private_network = true`. BYO is a **project-level** decision.

However, the LZ should export its private DNS zone IDs so BYO projects can link their VNet to the same DNS zones:

```hcl
# Already partially present in _outputs.tf:
output "devops_network" {
  value = {
    ...
    private_dns_zone_ids = { for index, z in azurerm_private_dns_zone.this : index => z.id }
    ...
  }
}
```

### 6.4 Project-level changes (`devops/project_github`)

```hcl
# New file: _variables.network.tf

variable "network_mode" {
  description = "Network mode for the project: 'platform' (use LZ-managed VNet) or 'byo' (Bring Your Own VNet)"
  type        = string
  default     = "platform"

  validation {
    condition     = contains(["platform", "byo"], var.network_mode)
    error_message = "network_mode must be 'platform' or 'byo'."
  }
}

variable "byo_vnet" {
  description = "BYO VNet configuration. Required when network_mode = 'byo'."
  type = object({
    vnet_id                          = string
    vnet_resource_group_name         = string
    private_endpoint_subnet_id       = optional(string)
    container_app_subnet_id          = optional(string)
    container_instance_subnet_id     = optional(string)
    devbox_subnet_id                 = optional(string)
    link_to_platform_private_dns     = optional(bool, true)
  })
  default = null

  validation {
    condition = (
      var.network_mode == "platform" ? var.byo_vnet == null :
      var.byo_vnet != null
    )
    error_message = "byo_vnet must be provided when network_mode is 'byo' and must be null when network_mode is 'platform'."
  }
}
```

#### BYO VNet subnet prerequisite validations

When `network_mode = "byo"`, the project module validates that:

1. If `use_self_hosted_runners = true` and `self_hosted_runners_type = "aca"`, then `byo_vnet.container_app_subnet_id` must be provided, and the subnet must have the `Microsoft.App/environments` delegation.
2. If `use_self_hosted_runners = true` and `self_hosted_runners_type = "aci"`, then `byo_vnet.container_instance_subnet_id` must be provided, and the subnet must have the `Microsoft.ContainerInstance/containerGroups` delegation.
3. If `use_devbox = true`, then `byo_vnet.devbox_subnet_id` must be provided.

```hcl
# New file: network.tf (in project_github)

locals {
  # Resolve subnet IDs based on network mode
  effective_private_endpoint_subnet_id = (
    var.network_mode == "byo"
    ? var.byo_vnet.private_endpoint_subnet_id
    : local._devops_outputs.devops_network.private_endpoint_subnet_id
  )

  effective_aca_subnet_id = (
    var.network_mode == "byo"
    ? var.byo_vnet.container_app_subnet_id
    : local.container_app_environment_id != null ? local._devops_outputs.devops_network.aca_subnet_id : null
  )

  effective_aci_subnet_id = (
    var.network_mode == "byo"
    ? var.byo_vnet.container_instance_subnet_id
    : local.container_instance_subnet_id
  )

  effective_devbox_subnet_id = (
    var.network_mode == "byo"
    ? var.byo_vnet.devbox_subnet_id
    : local._devops_outputs.devops_devbox.devbox_subnet_id
  )
}

# Optionally link BYO VNet to platform private DNS zones
resource "azurerm_private_dns_zone_virtual_network_link" "byo" {
  for_each = (
    var.network_mode == "byo" && var.byo_vnet.link_to_platform_private_dns
    ? local._devops_outputs.devops_network.private_dns_zone_ids
    : {}
  )

  name                  = "link-${var.project_name}-${each.key}"
  resource_group_name   = local._devops_outputs.devops_network.resource_group_name
  private_dns_zone_name = each.key
  virtual_network_id    = var.byo_vnet.vnet_id
  registration_enabled  = false
}
```

### 6.5 Sample `terraform.tfvars` — BYO VNet project

```hcl
# terraform.tfvars — Project "contoso-payments" with BYO VNet

target_subscription_id = "00000000-0000-0000-0000-000000000000"
project_name           = "contoso-payments"
location               = "japaneast"

tags = {
  appTag     = "contoso-payments"
  envTag     = "prod"
  projectTag = "devops"
  purposeTag = "alz"
}

repositories = [
  {
    name    = "contoso-payments-infra"
    profile = "infra"
  },
  {
    name    = "contoso-payments-svc"
    profile = "app"
  },
]

subscriptions = {
  "development" = { id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" },
  "production"  = { id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" },
}

# Bring Your Own VNet
network_mode = "byo"
byo_vnet = {
  vnet_id                      = "/subscriptions/.../resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-spoke-payments"
  vnet_resource_group_name     = "rg-network"
  private_endpoint_subnet_id   = "/subscriptions/.../subnets/snet-pe"
  container_app_subnet_id      = "/subscriptions/.../subnets/snet-aca"
  link_to_platform_private_dns = true
}

use_self_hosted_runners  = true
self_hosted_runners_type = "aca"
use_devbox               = false
```

### 6.6 Architecture Diagram — BYO VNet Flow

```text
┌─────────────────────────────────────────────────────────────────┐
│ Azure — Enterprise Hub-Spoke Network                            │
│                                                                 │
│  ┌─────────────┐      peering      ┌─────────────────────────┐ │
│  │  Hub VNet    │◄────────────────► │  Spoke VNet             │ │
│  │  (Firewall,  │                   │  (BYO — contoso-pays)   │ │
│  │   DNS, VPN)  │                   │  ┌──────────────────┐   │ │
│  └─────────────┘                    │  │ snet-pe          │   │ │
│                                     │  │ snet-aca         │   │ │
│       peering                       │  │ snet-aci         │   │ │
│  ┌─────────────┐                    │  └──────────────────┘   │ │
│  │  Platform LZ │                   └─────────────────────────┘ │
│  │  VNet        │                                               │
│  │  (managed by │      DNS zone links                           │
│  │   devops/lz) │◄──────────────── (linked at project level)    │
│  └─────────────┘                                                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. Organization-Level Governance

### 7.1 Current gaps

- Branch protection rules are only defined at the project level inside `github_workflows`.
- Runner groups are created per project only if `use_runner_group = true`.
- No org-level repository settings baseline.

### 7.2 Target additions

#### 7.2.1 Org-level ruleset baseline

The LZ should optionally manage a GitHub **organization ruleset** that applies to all repositories:

```hcl
# devops/lz/governance.tf

resource "github_organization_ruleset" "baseline" {
  count       = var.enable_github ? 1 : 0
  name        = "org-baseline"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      dismiss_stale_reviews_on_push     = var.org_default_branch_rules.dismiss_stale_reviews
      require_code_owner_review         = var.org_default_branch_rules.require_code_owners
      required_approving_review_count   = var.org_default_branch_rules.required_review_count
      required_review_thread_resolution = true
    }
  }

  bypass_actors {
    actor_id    = 0   # Organization admin
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
  }
}
```

#### 7.2.2 Org-level runner group management

```hcl
# devops/lz/governance.tf (continued)

variable "org_runner_groups" {
  description = "Runner groups to create at the organization level"
  type = map(object({
    visibility          = optional(string, "selected")
    allows_public_repos = optional(bool, false)
  }))
  default = {}
}

resource "github_actions_runner_group" "org" {
  for_each                = var.enable_github ? var.org_runner_groups : {}
  name                    = each.key
  visibility              = each.value.visibility
  allows_public_repositories = each.value.allows_public_repos
}
```

#### 7.2.3 Governance output consumed by projects

Projects will read the `org_governance` output from LZ remote state and merge it with their own overrides. This ensures:

- **Defaults flow down**: a project that doesn't specify review counts inherits the org default.
- **Overrides are explicit**: a project can override specific settings with a clear audit trail in its tfvars.

---

## 8. Operational Model — Portfolio Onboarding

### 8.1 Problem

Today, onboarding a new project requires:
1. Copy `terraform.tfvars.sample` → `terraform.tfvars`
2. Fill in all values manually
3. Run `terraform init` + `terraform apply`

For organizations with many projects (10+), this is error-prone and hard to audit.

### 8.2 Proposed: Project Catalog Pattern

Instead of one-off tfvars files, introduce a **project catalog** — a directory of YAML or HCL definitions:

```text
infra/
└── devops/
    └── projects/                        # ← NEW catalog directory
        ├── _catalog.tf                  # reads all .yaml files and calls project module
        ├── contoso-ecommerce.yaml
        ├── contoso-payments.yaml
        └── contoso-analytics.yaml
```

Each YAML file is a project definition:

```yaml
# contoso-ecommerce.yaml
project_name: contoso-ecommerce
location: japaneast
network_mode: platform
tags:
  appTag: contoso-ecommerce
  envTag: prod
repositories:
  - name: contoso-ecommerce-infra
    profile: infra
  - name: contoso-ecommerce-api
    profile: app
  - name: contoso-ecommerce-web
    profile: app
subscriptions:
  features:
    id: "11111111-..."
  development:
    id: "22222222-..."
  staging:
    id: "33333333-..."
  production:
    id: "44444444-..."
runners:
  use_self_hosted: true
  type: aca
```

The catalog controller:

```hcl
# _catalog.tf

locals {
  project_definitions = {
    for f in fileset("${path.module}", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/${f}"))
  }
}

module "project" {
  source   = "../project_github"
  for_each = local.project_definitions

  project_name           = each.value.project_name
  location               = each.value.location
  tags                   = each.value.tags
  repositories           = each.value.repositories
  subscriptions          = each.value.subscriptions
  network_mode           = lookup(each.value, "network_mode", "platform")
  byo_vnet               = lookup(each.value, "byo_vnet", null)
  use_self_hosted_runners = lookup(each.value.runners, "use_self_hosted", true)
  self_hosted_runners_type = lookup(each.value.runners, "type", "aca")
  target_subscription_id  = var.target_subscription_id
}
```

> **Note:** The catalog approach is **optional and additive**. Individual `terraform apply` of `project_github` continues to work as today. The catalog is a convenience layer for organizations managing many projects.

### 8.3 State isolation consideration

Each project in the catalog could use a separate Terraform workspace or backend key to maintain state isolation:

```hcl
terraform {
  backend "azurerm" {
    # key is set dynamically per project
  }
}
```

However, this adds complexity. An alternative is a single state file for the catalog with all projects. The trade-off:

| Approach | Pros | Cons |
|----------|------|------|
| **Separate state per project** (current) | Blast-radius isolation; independent apply cycles | Manual per-project init; harder to audit portfolio |
| **Single catalog state** | One apply for all projects; easy audit | Larger blast radius; slower plan/apply; lock contention |
| **Hybrid: catalog + per-project workspaces** | Per-project isolation + catalog convenience | Workspace management overhead |

**Recommendation:** Keep the current **separate state per project** approach as the primary mode. Offer the catalog as documentation and a generator (e.g., a script that reads YAML definitions and runs `terraform apply` for each), not as a single Terraform root module.

---

## 9. Naming, State & Collision Resistance

### 9.1 Current naming

Resources use a random 4-character suffix (`rand_id`) to avoid collisions. The naming pattern is:

```
<resource_type>-<project_name>-devops-<region_short>-<rand_id>
```

### 9.2 Improvements

1. **Portfolio-safe naming**: Add a configurable `org_prefix` (from LZ `naming_suffix`) to all resource names so that multiple DevOps Landing Zones in the same tenant don't collide:

   ```
   <resource_type>-<org_prefix>-<project_name>-<region_short>-<rand_id>
   ```

2. **Tfstate key convention**: Standardize the backend key format:

   ```
   projects/<project_name>.terraform.tfstate
   ```

   This keeps project states organized under a known prefix in the blob container.

3. **Repository naming convention**: Default repository names follow `<project_name>-<repo_role>`:

   ```
   contoso-ecommerce-infra
   contoso-ecommerce-api
   contoso-ecommerce-templates
   ```

   Users can override names in the `repositories` variable.

---

## 10. Migration Path from Current Design

### 10.1 Backward compatibility guarantees

| Feature | Current behavior | New behavior | Breaking? |
|---------|-----------------|--------------|-----------|
| `repositories = []` | N/A | Falls back to single-repo using `project_name` | No |
| `network_mode = "platform"` | Implicit | Explicit default | No |
| `byo_vnet = null` | N/A | Ignored when `network_mode = "platform"` | No |
| `shared_identities = true` | Implicit | Explicit default, same UAMI-per-env behavior | No |
| LZ governance outputs | N/A | New outputs; projects can ignore them | No |

### 10.2 Suggested migration steps

1. **Phase 1 — Non-breaking additions:**
   - Add `repositories` variable with default `[]`.
   - Add `network_mode` / `byo_vnet` variables with defaults.
   - Add governance variables and outputs to LZ.
   - No existing tfvars files need to change.

2. **Phase 2 — Module refactoring:**
   - Refactor `modules/github` to iterate over a list of repositories.
   - Refactor `modules/github_workflows` to generate per-profile workflows.
   - Existing single-repo projects continue to work via the fallback in `_locals.tf`.

3. **Phase 3 — Documentation & examples:**
   - Add multi-repo example tfvars.
   - Add BYO VNet example tfvars.
   - Add architecture diagrams for both modes.
   - Fix path references (`infra/terraform/…` → `infra/…`).

4. **Phase 4 — Optional catalog layer:**
   - Add `devops/projects/` catalog directory.
   - Add onboarding script.
   - Document portfolio onboarding workflow.

---

## 11. Open Questions

| # | Question | Options | Recommendation |
|---|----------|---------|----------------|
| 1 | Should BYO VNet be supported at the **LZ level** (the LZ itself uses an external VNet) or only at the **project level**? | LZ-level BYO / Project-level BYO / Both | Start with project-level BYO. LZ-level BYO is a larger change and can be added later. |
| 2 | Should the catalog be a Terraform root module or a script-based generator? | Terraform `for_each` / Shell/Python script / Both | Script-based generator (avoids single-state risks). |
| 3 | How should per-repo identities be named to stay within Azure naming limits? | `uami-<project>-<repo>-<env>-<job>-<rand>` / Hash-based short names | Use hash-based short names when the full name exceeds 128 chars. |
| 4 | Should repository profiles be extensible by users or fixed? | Fixed set / User-defined profiles via HCL | Start with a fixed set (`infra`, `app`, `library`, `docs`), allow extension later. |
| 5 | Should the org-level ruleset be enforced or advisory? | `active` / `evaluate` (audit-only) | Default to `active` with bypass for org admins. |
| 6 | Should BYO VNet projects share the platform ACA Environment or create their own? | Shared / Per-project / Configurable | Per-project ACA Environment in the BYO VNet (required for subnet delegation). |
| 7 | How to handle projects that need only a subset of environments (e.g., just dev + prod)? | Allow `subscriptions` to be a subset / Require all 4 | Allow subset — only create environments for provided subscriptions. |
| 8 | Should Azure DevOps project support follow the same multi-repo pattern? | Yes / Later | Yes, design the interfaces now; implement Azure DevOps support in a follow-up phase. |

---

> **Next steps:** Review this spec with stakeholders, resolve open questions, and then proceed with Phase 1 implementation (non-breaking variable additions).
