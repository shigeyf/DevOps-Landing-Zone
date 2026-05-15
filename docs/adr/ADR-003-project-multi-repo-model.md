[English](./ADR-003-project-multi-repo-model.md) | [日本語](./ADR-003-project-multi-repo-model.ja.md)

# ADR-003: Project Definition and Multi-Repository Model

> **Status:** Accepted
> **Context:** [Target Architecture Spec](../Target-Architecture-Spec.md)

## Summary

A DevOps LZ 'Project' is a logical grouping of repositories, identities, runners, and network context. Projects support multiple repositories with different CI/CD profiles (`infra`, `app`, `library`, `docs`), per-repo or shared identities, and declarative subset environments.

---

> **Note:** Sections 6.3–6.7 describe the **target design** for multi-repo support, repository profiles, per-repo identities, and subset environments. **Currently**, the `project_github` module supports only a single main repo + optional templates repo (Section 6.2), with a single hardcoded `infra`-style workflow profile and one UAMI per environment × job type (plan/apply) shared across repos.

### 6.1 Design philosophy: Separation is a recommendation, not a mandate

Repository profiles (`infra`, `app`, `library`, `docs`) are **recommended patterns** that map to different CI/CD workflow shapes. They are not a mandate to split every project into multiple repos.

**A single repository containing both infra and app code is fully supported.** In that case, the user assigns the `infra` profile (which includes the most comprehensive branch/environment strategy) and the single repo gets the full `validate → plan → apply` pipeline. The multi-repo pattern is offered for teams who prefer separation of concerns, independent release cadences, or fine-grained RBAC.

| Scenario                        | Configuration                                            | Result                                                               |
| ------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------- |
| Single repo (current behavior)  | `repositories = []` or single entry with profile `infra` | Identical to today                                                   |
| Separated infra + app           | Two entries: `profile = "infra"` + `profile = "app"`     | Separate workflow shapes, optionally separate UAMIs                  |
| Monorepo with multiple concerns | Single entry with profile `infra`                        | One repo gets the full pipeline; internal structure is user's choice |

### 6.2 Current design (single repo)

```hcl
# Today
project_name = "my-project"
# → creates 1 repo: "my-project"
# → creates 1 templates repo: "my-project-templates" (optional)
```

### 6.3 Target design (multi-repo)

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

### 6.4 Repository profiles

Profiles define the **workflow shape** for a repository. They are defined in the `github_workflows` module and control which CI/CD workflows and branch strategies are generated.

| Profile   | Branches                               | CI Workflow               | CD Workflow                | Environments                                       |
| --------- | -------------------------------------- | ------------------------- | -------------------------- | -------------------------------------------------- |
| `infra`   | `features/*`, `dev`, `staging`, `main` | `validate` + `plan` on PR | `plan` + `apply` on push   | `features`, `development`, `staging`, `production` |
| `app`     | `features/*`, `dev`, `staging`, `main` | `build` + `test` on PR    | `build` + `deploy` on push | `development`, `staging`, `production`             |
| `library` | `features/*`, `main`                   | `build` + `test` on PR    | `publish` on tag           | —                                                  |
| `docs`    | `main`                                 | —                         | —                          | —                                                  |

> **Note:** The `docs` profile generates **no CI/CD workflows**. It creates the repository with default branch protection only. This profile is intended for documentation-only repos (wikis, ADRs, runbooks) that don't need build or deployment pipelines.

### 6.5 Identity (UAMI) allocation strategy

#### Where identities are created

UAMIs are **created at project deployment time** (Tier 2), not pre-registered at the Platform LZ level. The Platform LZ (Tier 1) only provides the **identity resource group** where UAMIs are placed.

The subscription-to-environment mapping is defined in each project's `terraform.tfvars` via the `subscriptions` variable. The Platform LZ does **not** maintain a global subscription registry. Each project declares which Azure subscriptions it needs for its environments, and the project module creates UAMIs and federated identity credentials accordingly.

**Identity model:** The `github_workflows` module generates a `github_environments` map keyed by `{branch_key}-{job_type}` (e.g., `feat-plan`, `dev-apply`, `stg-plan`, `prod-apply`). The project module creates one UAMI per entry — 7 UAMIs per project (4 environments × plan + 3 environments × apply, since `features` has no `apply` job). Each UAMI receives a single federated identity credential for GitHub OIDC.

```text
Platform LZ (Tier 1)                Project (Tier 2)
┌─────────────────────┐             ┌──────────────────────────────┐
│ Provides:           │             │ Creates (in Project RG):     │
│ • Shared infra      │────────────►│ • 7 UAMIs (env × job type)   │
│   (ACR, Log, UAMI)  │             │   feat-plan, dev-plan,       │
│                     │             │   stg-plan, prod-plan,       │
│                     │             │   dev-apply, stg-apply,      │
│                     │             │   prod-apply                 │
│                     │             │ • 7 Federated identity creds │
│                     │             │ • Role assignments on subs   │
│                     │             │   (only for envs in          │
│                     │             │    subscriptions map)         │
│                     │             │                              │
│                     │             │ Subscription map comes from: │
│                     │             │ • project's terraform.tfvars │
└─────────────────────┘             └──────────────────────────────┘
```

#### Shared vs per-repository identities

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

#### UAMI naming

UAMIs use a mixed naming pattern that keeps project and repo human-readable while hashing env/job details:

```
uami-<project>-<repo>-<hash>          # per-repo identities (shared_identities = false)
uami-<project>-<hash>                 # shared identities (shared_identities = true)
```

See [Section 11.3](#113-uami-naming-convention) for the full naming convention, hash derivation, and examples.

### 6.6 Sample `terraform.tfvars` — multi-repo project

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

### 6.7 Sample `terraform.tfvars` — subset environments (dev + prod only)

```hcl
# terraform.tfvars — Project with only development and production environments

target_subscription_id = "00000000-0000-0000-0000-000000000000"
project_name           = "contoso-internal-tool"
location               = "japaneast"

tags = {
  appTag     = "contoso-internal-tool"
  envTag     = "prod"
  projectTag = "devops"
}

# Single repository (backward-compatible; repositories = [] uses project_name as repo name)

# Only two environments — no features or staging
subscriptions = {
  "development" = {
    id = "22222222-2222-2222-2222-222222222222"
  },
  "production" = {
    id = "44444444-4444-4444-4444-444444444444"
  },
}

network_mode = "platform"
use_self_hosted_runners = true
self_hosted_runners_type = "aca"
```

> **Note (target behavior):** This sample shows the intended subset environment support described in Decision #7. The target architecture supports creating only the environments present in the `subscriptions` map — the matching GitHub Actions Environments, UAMIs, branches, and federated credentials.

---

## Related Decisions

- [ADR-004: GitHub vs. Azure DevOps Abstraction](./ADR-004-github-ado-abstraction.md)
- [ADR-008: Naming, State Key, and Collision Resistance](./ADR-008-naming-collision-resistance.md)
