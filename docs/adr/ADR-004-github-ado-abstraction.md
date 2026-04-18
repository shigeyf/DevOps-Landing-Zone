[English](./ADR-004-github-ado-abstraction.md) | [日本語](./ADR-004-github-ado-abstraction.ja.md)

# ADR-004: GitHub vs. Azure DevOps Structural Differences and Abstraction

> **Status:** Accepted
> **Context:** [Target Architecture Spec](../Target-Architecture-Spec.md)

## Summary

GitHub and Azure DevOps have fundamentally different organizational hierarchies. The DevOps LZ introduces a platform-agnostic 'Project' concept with a unified input interface (`project_github` / `project_azuredevops`) that maps to each platform's native primitives.

---

> **Note:** The unified interface described in Sections 7.2–7.4 is the **target design**. The `project_azuredevops` module will implement the same interface as `project_github`.

### 7.1 The structural mismatch

GitHub and Azure DevOps have fundamentally different organizational hierarchies:

```text
GitHub                              Azure DevOps
──────                              ──────────────
Organization                        Organization
├── Repository A                    ├── Project X
├── Repository B                    │   ├── Repository A
├── Repository C                    │   ├── Repository B
├── Teams (org-wide)                │   ├── Pipelines
├── Runner Groups (org-wide)        │   ├── Environments
├── Org Rulesets (org-wide)         │   ├── Service Connections
└── Environments (per-repo)         │   ├── Agent Pools (project-scoped)
                                    │   └── Teams/Groups (project-scoped)
                                    ├── Project Y
                                    │   └── ...
                                    └── Org-level Agent Pools
```

Key differences:

| Aspect                  | GitHub                                          | Azure DevOps                                                      |
| ----------------------- | ----------------------------------------------- | ----------------------------------------------------------------- |
| **"Project" concept**   | No native project; repos are flat under the org | First-class `Project` container with its own security boundary    |
| **Environments**        | Defined per repository                          | Defined per project                                               |
| **Pipelines**           | Defined in repo (GitHub Actions workflows)      | Defined in project, pointing to repo files                        |
| **Teams/permissions**   | Org-wide teams with per-repo access             | Project-scoped teams + org-level groups                           |
| **Agent/Runner pools**  | Org-level runner groups                         | Both org-level and project-scoped pools                           |
| **Branch protection**   | Per-repo rulesets OR org-level rulesets         | Per-repo branch policies within a project                         |
| **Service Connections** | N/A (OIDC federation per environment)           | Project-scoped service connections (workload identity federation) |

### 7.2 The abstraction: DevOps LZ "Project"

The DevOps Landing Zone introduces a **logical "Project"** concept that maps differently to each VCS platform:

```text
DevOps LZ Project                    GitHub Mapping                Azure DevOps Mapping
──────────────────                    ──────────────                ────────────────────
project_name = "contoso-ecommerce"    Naming convention:            ADO Project:
                                      repos prefixed with           "contoso-ecommerce"
                                      "contoso-ecommerce-*"

repositories = [                      GitHub repos:                 ADO repos inside project:
  { name="...-infra", ... },          contoso-ecommerce-infra       contoso-ecommerce-infra
  { name="...-app",   ... },          contoso-ecommerce-app         contoso-ecommerce-app
]

environments = {                      GitHub Environments            ADO Environments:
  development, staging, production    (per repo, with env prefix)    (per project)
}

identities = {                        OIDC federation                Workload identity federation
  UAMI per env × job                  (per environment)              (via service connections)
}
```

### 7.3 Unified interface design

Both `project_github` and `project_azuredevops` modules share the same **input interface** for project-level configuration:

```hcl
# Shared input interface (both project_github and project_azuredevops)

variable "project_name"    { ... }   # → GitHub: naming prefix  │ ADO: project name
variable "repositories"    { ... }   # → GitHub: org-level repos │ ADO: project-scoped repos
variable "subscriptions"   { ... }   # → Both: Azure subscription per environment
variable "network_mode"    { ... }   # → Both: platform or byo
variable "byo_vnet"        { ... }   # → Both: BYO VNet config
variable "shared_identities" { ... } # → Both: shared vs per-repo UAMIs
```

Platform-specific variables are additive:

```hcl
# GitHub-specific
variable "use_runner_group"          { ... }
variable "use_templates_repository"  { ... }

# Azure DevOps-specific
variable "create_project"            { ... }   # create or reference existing ADO project
variable "use_separate_repo_for_pipeline_templates" { ... }
```

### 7.4 Governance consistency

For governance to be consistent across both platforms, the Platform LZ defines **platform-agnostic governance defaults** that are then mapped to platform-specific resources:

| DevOps LZ Governance Setting   | GitHub Implementation                          | Azure DevOps Implementation                                 |
| ------------------------------ | ---------------------------------------------- | ----------------------------------------------------------- |
| `require_pull_request = true`  | Org ruleset: `pull_request` block              | Branch policy: `azuredevops_branch_policy_min_reviewers`    |
| `required_review_count = 1`    | Org ruleset: `required_approving_review_count` | Branch policy: `minimum_reviewer_count`                     |
| `dismiss_stale_reviews = true` | Org ruleset: `dismiss_stale_reviews_on_push`   | (Not directly available; approximated via policy settings)  |
| `require_status_checks = true` | Org ruleset: `required_status_checks`          | Branch policy: `azuredevops_branch_policy_build_validation` |
| `runner_group / agent_pool`    | `github_actions_runner_group`                  | `azuredevops_agent_pool` (org-level)                        |

This mapping is implemented in separate files (`governance.github.tf` and `governance.azuredevops.tf`) within the LZ module, driven by the same governance variables.

---

## Related Decisions

- [ADR-003: Project Definition and Multi-Repository Model](./ADR-003-project-multi-repo-model.md)
- [ADR-006: Organization-Level Governance](./ADR-006-organization-governance.md)
