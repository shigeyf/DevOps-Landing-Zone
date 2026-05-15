# Module Design Specification

[English](./Module-Design.md) | [日本語](./Module-Design.ja.md)

> **Status:** Draft — planning phase.
>
> **Purpose:** Define the reusable sub-module (building block) design for the three-layer DevOps Landing Zone deployment model. Each deployment layer (`devops-org-lz`, `devops-project-lz`, `devops-repo-lz`) composes abstract, domain-level sub-modules that encapsulate resources and VCS-specific implementations behind uniform interfaces.

---

## Table of Contents

1. [Three-Layer Deployment Model](#1-three-layer-deployment-model)
2. [Module Design Principles](#2-module-design-principles)
3. [Layer 1: Organization LZ Sub-Modules (devops-org-lz)](#3-layer-1-organization-lz-sub-modules-devops-org-lz)
4. [Layer 2: Project LZ Sub-Modules (devops-project-lz)](#4-layer-2-project-lz-sub-modules-devops-project-lz)
5. [Layer 3: Repo LZ Sub-Modules (devops-repo-lz)](#5-layer-3-repo-lz-sub-modules-devops-repo-lz)
6. [Abstract Module Pattern](#6-abstract-module-pattern)
7. [Module Composition Diagram](#7-module-composition-diagram)
8. [Implementation Plan](#8-implementation-plan)

---

## 1. Three-Layer Deployment Model

The DevOps Landing Zone uses three separate Terraform deployments (each with its own state), layered on top of a bootstrap:

| Tier | Deployment            | Directory                  | Scope                                                | State Key                                  |
| ---- | --------------------- | -------------------------- | ---------------------------------------------------- | ------------------------------------------ |
| 0    | Bootstrap             | `infra/bootstrap/`         | Layer 1 Storage Account + Key Vault                  | `bootstrap.terraform.tfstate`              |
| 1    | **devops-org-lz**     | `infra/devops-org-lz/`     | Organization-wide shared infrastructure              | `devops-lz.terraform.tfstate`              |
| 2    | **devops-project-lz** | `infra/devops-project-lz/` | Per-project infra (identity, runner, state, network) | `projects/<name>.terraform.tfstate`        |
| 3    | **devops-repo-lz**    | `infra/devops-repo-lz/`    | Per-repo resources + environments                    | `repos/<project>/<repo>.terraform.tfstate` |

Each layer reads the previous layer's outputs via `terraform_remote_state`.

---

## 2. Module Design Principles

1. **Abstract over VCS platform** — Sub-modules like `project_repo`, `environment`, and `runner` accept a `vcs_provider` input (`"github"` or `"azuredevops"`) and internally dispatch to the correct implementation. Callers get a uniform input/output contract.

2. **Single responsibility** — Each sub-module owns exactly one domain concept (e.g., project state storage, project identity, repository provisioning, environment binding).

3. **Platform-agnostic where possible** — Modules dealing with pure Azure resources (`project_state`, `project_identity`, `project_network`, `aca_env`) work identically for both GitHub and Azure DevOps projects.

4. **VCS-specific only where necessary** — Modules that interact with VCS APIs (`project_repo`, `environment`, `runner`) use the abstract dispatch pattern.

5. **Composable, not nested** — Sub-modules do not call each other. Root modules (`project_github`, `repo_github`, etc.) compose sub-modules and pass outputs between them.

6. **Consistent interface** — All abstract modules share a common variable pattern: `vcs_provider`, `project_name`, and domain-specific inputs.

---

## 3. Layer 1: Organization LZ Sub-Modules (devops-org-lz)

The Org LZ is a single root module that uses existing and new sub-modules to provision organization-wide shared infrastructure.

| Sub-Module           | Responsibility                                                | Platform-Agnostic? | Status   |
| -------------------- | ------------------------------------------------------------- | ------------------ | -------- |
| `bootstrap`          | RG + Storage Account + Key Vault + CMK + UAMI (Layer 1 state) | Yes                | Existing |
| `vnet`               | Platform VNet + subnets + NAT Gateway + Private DNS zones     | Yes                | Existing |
| `acr`                | Azure Container Registry + image build tasks                  | Yes                | Existing |
| `resource_providers` | Azure resource provider registrations                         | Yes                | Existing |
| `org_governance`     | Org-level rulesets, runner groups, agent pools                | No (dispatches)    | New      |

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

---

## 4. Layer 2: Project LZ Sub-Modules (devops-project-lz)

The Project LZ provisions per-project infrastructure. It does **not** create repositories or environments — those belong to Tier 3.

| Sub-Module         | Responsibility                                                           | Platform-Agnostic? | Status   |
| ------------------ | ------------------------------------------------------------------------ | ------------------ | -------- |
| `project_state`    | Layer 2 Storage Account + Project Key Vault + Project RG                 | Yes                | New      |
| `project_identity` | 7 UAMIs + OIDC federated credentials + subscription RBAC                 | Yes                | New      |
| `project_network`  | Subnet slice (platform mode) or BYO VNet validation                      | Yes                | New      |
| `aca_env`          | ACA Environment bound to project's network context                       | Yes                | Existing |
| `devbox_project`   | DevCenter Project + Dev Box Pool + Network Connection                    | Yes                | New      |
| `runner`           | ACA job definition registered with GitHub runner group or ADO agent pool | No (dispatches)    | New      |

### `project_state`

Creates per-project state infrastructure:

- Project-scoped Resource Group (inside platform subscription)
- Layer 2 Storage Account (LRS default, selectable replication)
- Project-owned Key Vault (distinct from bootstrap KV)

### `project_identity`

Creates the 7 project-scoped UAMIs:

- `feat-plan`, `dev-plan`, `stg-plan`, `prod-plan` (plan-only, read access)
- `dev-apply`, `stg-apply`, `prod-apply` (apply, write access)

Each UAMI gets:

- OIDC federated credentials (bound to VCS environment)
- Conditional subscription RBAC (only if subscription is declared)

### `project_network`

Handles the project's DevOps network context:

- **Platform mode:** Creates a project-dedicated subnet slice within the shared Platform LZ VNet
- **BYO mode:** Validates the externally-provided VNet/subnet against consistency rules

### `aca_env`

Creates a project-scoped ACA Environment:

- Bound to the project's network context (platform subnet or BYO subnet)
- Zone redundancy configurable
- Consumes Log Analytics workspace from Org LZ outputs

### `devbox_project`

Creates DevCenter project resources:

- DevCenter Project (references org-level Dev Center)
- Dev Box Pool
- Network Connection (project-scoped, bound to project's network context)

### `runner`

Abstract module for CI/CD runner registration:

- **GitHub:** Registers ACA job as a GitHub Actions runner in the project's runner group
- **Azure DevOps:** Registers ACA job as an ADO agent in the project's agent pool

---

## 5. Layer 3: Repo LZ Sub-Modules (devops-repo-lz)

The Repo LZ provisions individual repositories and their environments. Each repository gets its own Terraform state, enabling independent lifecycle management.

| Sub-Module     | Responsibility                                                         | Platform-Agnostic? | Status |
| -------------- | ---------------------------------------------------------------------- | ------------------ | ------ |
| `project_repo` | Abstract: Repository creation + branch protection                      | No (dispatches)    | New    |
| `environment`  | Abstract: Environment creation + protection rules + UAMI binding       | No (dispatches)    | New    |
| `runner`       | Abstract: Per-repo runner registration (optional, for dedicated pools) | No (dispatches)    | New    |

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

**Outputs:** `environment_id`, `environment_name`

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

---

## 6. Abstract Module Pattern

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

## 7. Module Composition Diagram

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-org-lz (Tier 1 Root Module)                                      │
│                                                                         │
│  ┌──────────┐ ┌──────┐ ┌─────┐ ┌──────────────────┐ ┌───────────────┐ │
│  │bootstrap │ │ vnet │ │ acr │ │resource_providers│ │org_governance │ │
│  └──────────┘ └──────┘ └─────┘ └──────────────────┘ └───────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                              │ remote_state
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-project-lz (Tier 2 Root Module — one per project)                │
│                                                                         │
│  ┌─────────────┐ ┌────────────────┐ ┌───────────────┐ ┌─────────────┐ │
│  │project_state│ │project_identity│ │project_network│ │   aca_env   │ │
│  └─────────────┘ └────────────────┘ └───────────────┘ └─────────────┘ │
│  ┌─────────────┐ ┌────────────────┐                                    │
│  │devbox_project│ │    runner      │                                    │
│  └─────────────┘ └────────────────┘                                    │
└─────────────────────────────────────────────────────────────────────────┘
                              │ remote_state
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-repo-lz (Tier 3 Root Module — one per repository)                │
│                                                                         │
│  ┌────────────┐ ┌─────────────┐ ┌────────────────────┐                 │
│  │project_repo│ │ environment │ │ runner (optional)  │                 │
│  └────────────┘ └─────────────┘ └────────────────────┘                 │
│                                                                         │
│  Includes: CI/CD workflow/pipeline generation (profile-driven)          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 8. Implementation Plan

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
