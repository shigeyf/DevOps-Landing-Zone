[English](./ADR-006-organization-governance.md) | [日本語](./ADR-006-organization-governance.ja.md)

# ADR-006: Organization-Level Governance (GitHub and Azure DevOps)

> **Status:** Accepted
> **Context:** [Target Architecture Spec](../Target-Architecture-Spec.md)

## Summary

Platform-agnostic governance variables defined at the Platform LZ level drive both GitHub org-level rulesets and Azure DevOps project-level branch policies, achieving governance parity from a single declarative source.

---

> **Note:** This entire section describes **proposed governance features**. No governance resources (rulesets, runner groups, agent pools, repository defaults) are currently created by `devops/lz`. The current LZ only stores GitHub PATs and Azure DevOps PATs in the bootstrap Key Vault as secrets. Branch protection rules are created at the project level by the `github_workflows` module.

### 9.1 Current gaps

- Branch protection rules are only defined at the project level inside `github_workflows`.
- Runner groups are created per project only if `use_runner_group = true`.
- No org-level repository settings baseline.
- **No Azure DevOps governance is managed at all** — ADO policies/pools are configured manually.

### 9.2 Target: Platform-agnostic governance variables

The LZ defines governance settings that are **platform-agnostic** and then mapped to both GitHub and Azure DevOps:

```hcl
# devops/lz/_variables.governance.tf

variable "org_default_branch_rules" {
  description = "Default branch protection rules applied to all project repositories (GitHub + Azure DevOps)"
  type = object({
    require_pull_request   = optional(bool, true)
    required_review_count  = optional(number, 1)
    require_status_checks  = optional(bool, true)
    dismiss_stale_reviews  = optional(bool, true)
    require_code_owners    = optional(bool, false)
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

### 9.3 GitHub governance implementation

```hcl
# devops/lz/governance.github.tf

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
    bypass_mode = "pull_request"  # admins must use PRs but can bypass in emergencies
  }
}

variable "org_runner_groups" {
  description = "Runner groups to create at the GitHub organization level"
  type = map(object({
    visibility          = optional(string, "selected")
    allows_public_repos = optional(bool, false)
  }))
  default = {}
}

resource "github_actions_runner_group" "org" {
  for_each                   = var.enable_github ? var.org_runner_groups : {}
  name                       = each.key
  visibility                 = each.value.visibility
  allows_public_repositories = each.value.allows_public_repos
}
```

### 9.4 Azure DevOps governance implementation

Azure DevOps governance maps to different resource types, but addresses the same policy intent:

```hcl
# devops/lz/governance.azuredevops.tf

# Org-level agent pools (equivalent to GitHub runner groups)
variable "org_agent_pools" {
  description = "Agent pools to create at the Azure DevOps organization level"
  type = map(object({
    auto_provision = optional(bool, false)
    auto_update    = optional(bool, true)
  }))
  default = {}
}

resource "azuredevops_agent_pool" "org" {
  for_each       = var.enable_azuredevops ? var.org_agent_pools : {}
  name           = each.key
  auto_provision = each.value.auto_provision
  auto_update    = each.value.auto_update
}

# Note: Azure DevOps branch policies are project-scoped, not org-scoped.
# The org_default_branch_rules are applied at the PROJECT level during
# project_azuredevops module execution, where they map to:
#   - azuredevops_branch_policy_min_reviewers
#   - azuredevops_branch_policy_build_validation
#   - azuredevops_branch_policy_auto_reviewers (for CODEOWNERS equivalent)
```

### 9.5 Governance parity matrix

| Governance Intent                  | GitHub (Org-level)                         | Azure DevOps (Org-level)       | Azure DevOps (Project-level)                 |
| ---------------------------------- | ------------------------------------------ | ------------------------------ | -------------------------------------------- |
| **Require PRs for default branch** | `github_organization_ruleset`              | N/A                            | `azuredevops_branch_policy_min_reviewers`    |
| **Min review count**               | Ruleset: `required_approving_review_count` | N/A                            | Branch policy: `minimum_reviewer_count`      |
| **Dismiss stale reviews**          | Ruleset: `dismiss_stale_reviews_on_push`   | N/A                            | (Not directly supported)                     |
| **Require status checks**          | Ruleset: `required_status_checks`          | N/A                            | `azuredevops_branch_policy_build_validation` |
| **Agent/Runner pools**             | `github_actions_runner_group` (org)        | `azuredevops_agent_pool` (org) | `azuredevops_agent_queue` (project)          |
| **Repository defaults**            | Org-level settings via API                 | N/A                            | Project-level settings                       |

> **Key architectural difference:** GitHub allows org-level rulesets that cascade to all repos. Azure DevOps does not have org-level branch policies — they must be applied per-project. The DevOps LZ handles this by applying the `org_default_branch_rules` at project creation time in the `project_azuredevops` module.

---

## Related Decisions

- [ADR-004: GitHub vs. Azure DevOps Abstraction](./ADR-004-github-ado-abstraction.md)
