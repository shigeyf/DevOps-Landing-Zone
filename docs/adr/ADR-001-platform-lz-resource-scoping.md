[English](./ADR-001-platform-lz-resource-scoping.md) | [日本語](./ADR-001-platform-lz-resource-scoping.ja.md)

# ADR-001: Platform Landing Zone Resource Scoping

> **Status:** Accepted
> **Context:** [Target Architecture Spec](../Target-Architecture-Spec.md)

## Summary

The Platform Landing Zone (`devops/lz`) owns organization-shared infrastructure. The key finding is that the ACA Environment should be project-scoped, not org-scoped, because each project's runners must operate in the project's own network context.

---

### 5.1 Role: Platform Bootstrap (Tier 1 within Layer 1)

The Landing Zone serves as the **organizational platform bootstrap**. It is the first Terraform layer applied after Tier 0 (`_bootstrap`), and it creates all shared Azure and VCS resources that projects depend on.

Operationally:

- **Tier 0** (`_bootstrap`) is applied once and very rarely updated. Creates the Layer 1 Storage Account.
- **Tier 1** (`devops/lz`) is applied whenever the organization's platform configuration changes (e.g., new subnets, new DevBox definitions, governance policy changes).
- Both tiers store their state in the same Layer 1 Storage Account, under different state keys.

### 5.2 Platform LZ resource review — org vs. project scoping

Each resource created by the Platform LZ must be evaluated for whether it truly belongs at the organization level (shared across all projects) or should be moved to the project level (created per project). The following table summarizes the review:

| Resource                          | Current Scope                | Correct Scope         | Verdict & Rationale                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| --------------------------------- | ---------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Identity RG**                   | Platform (org)               | **Platform (org)** ✅ | The identity RG is a shared resource container. It creates no identities itself — UAMIs are created at project deployment time (Tier 2) inside this RG. Keeping a shared RG at the org level is valid: it provides a predictable, centrally-managed location for all project UAMIs, simplifies RBAC, and avoids per-project RG sprawl.                                                                                                                         |
| **Agents RG**                     | Platform (org)               | **Needs split** ⚠️    | The agents RG currently hosts ACR, ACA Environment, Log Analytics, and container-run UAMI. ACR and Log Analytics are correctly org-scoped (shared image registry and centralized logging). However, the ACA Environment (runner compute) should be project-scoped — see below. The agents RG should be retained for org-scoped resources (ACR, Log Analytics, container-run UAMI), but runner compute should move to the project level.                        |
| **ACR (Container Registry)**      | Platform (org)               | **Platform (org)** ✅ | Shared container image registry for runner images. All projects pull runner images from the same ACR. This is correctly scoped at the org level.                                                                                                                                                                                                                                                                                                               |
| **Log Analytics Workspace**       | Platform (org)               | **Platform (org)** ✅ | Centralized logging for agent/runner operations. Org-level scoping provides a single pane of glass for platform operations. Correctly shared.                                                                                                                                                                                                                                                                                                                  |
| **Container-run UAMI**            | Platform (org)               | **Platform (org)** ✅ | A shared identity used for pulling container images from ACR and reading Key Vault secrets during runner execution. Correctly scoped at the org level since it accesses org-level resources (ACR, Key Vault).                                                                                                                                                                                                                                                  |
| **ACA Environment**               | Platform (org) → **Project** | **Project** ✅        | The ACA Environment should be moved from the Platform LZ to the project level. Each project creates its own ACA Environment inside its effective runner subnet (`platform` mode = project-dedicated ACA subnet in the Platform LZ VNet; `byo` mode = user-provided BYO subnet). The Platform LZ continues to provide shared infrastructure (ACR, Log Analytics, container-run UAMI, private DNS zones) consumed by project-level ACA Environments. See §5.4.1. |
| **Network RG + Platform VNet**    | Platform (org)               | **Platform (org)** ✅ | The platform-managed VNet with subnets, DNS zones, and NAT gateway is correctly org-scoped. It provides shared network infrastructure for projects using `network_mode = "platform"`. BYO VNet projects bypass this entirely.                                                                                                                                                                                                                                  |
| **Private DNS Zones**             | Platform (org)               | **Platform (org)** ✅ | Shared DNS zones for private endpoint resolution. BYO VNet projects link their VNet to these zones. Correctly org-scoped.                                                                                                                                                                                                                                                                                                                                      |
| **Private Endpoints (bootstrap)** | Platform (org)               | **Platform (org)** ✅ | Private endpoints to the bootstrap Storage Account and Key Vault are org-level resources. Correctly scoped.                                                                                                                                                                                                                                                                                                                                                    |
| **Dev Center**                    | Platform (org)               | **Platform (org)** ✅ | The Dev Center is a singleton org-level resource. DevBox definitions (images, SKUs) are defined here and shared across all projects. DevBox project pools are created at the project level referencing the org-level Dev Center. Correctly scoped.                                                                                                                                                                                                             |
| **Container image build tasks**   | Platform (org)               | **Platform (org)** ✅ | ACR tasks for building runner container images. Shared across all projects. Correctly scoped.                                                                                                                                                                                                                                                                                                                                                                  |
| **VCS governance resources**      | Platform (org)               | **Platform (org)** ⚠️ | Org-level rulesets (GitHub) and agent pools (Azure DevOps) belong at the platform level. Governance is part of the target architecture (Section 9).                                                                                                                                                                                                                                                                                                            |

#### Key finding: ACA Environment should be project-scoped

The most significant finding is that the **ACA Environment** (Azure Container Apps Environment for self-hosted runners) should be **moved from Platform LZ to the project module**:

1. **Network isolation requirement:** Self-hosted runners must operate in the project's network context. For BYO VNet projects, the runner's ACA Environment must be in the project's VNet (with `Microsoft.App/environments` subnet delegation). The platform VNet's ACA Environment cannot be shared because ACA Environments are bound to a single VNet.

2. **Current inconsistency:** The document's Section 8 (BYO VNet) already notes that BYO VNet projects create their own ACA Environment (Decision #6), but Section 5.2 still lists the ACA Environment as a shared platform resource. This is contradictory.

3. **Recommended design:**
   - **Platform LZ** provides: ACR, Log Analytics, container-run UAMI, container image build tasks — _shared infrastructure_ that all runner environments consume.
   - **Project module** creates: ACA Environment (in the project's VNet or the platform VNet subnet), ACA runner jobs — _per-project runner compute_.
   - For `network_mode = "platform"`: the project module creates its ACA Environment in the platform VNet's ACA subnet (subnet ID provided by LZ output).
   - For `network_mode = "byo"`: the project module creates its ACA Environment in the BYO VNet's ACA subnet (subnet ID provided by user input).

```text
Platform LZ (Tier 1)                    Project (Tier 2)
┌───────────────────────────┐           ┌──────────────────────────────────┐
│ Provides (shared):        │           │ Creates (per project):           │
│ • ACR (runner images)     │──────────►│ • ACA Environment               │
│ • Log Analytics           │           │   (in platform VNet or BYO VNet) │
│ • Container-run UAMI      │           │ • ACA runner jobs                │
│ • Container image tasks   │           │ • ACI runner instances (if ACI)  │
│ • Platform VNet + subnets │           │                                  │
│                           │           │ Consumes from LZ:                │
│ No longer creates:        │           │ • ACR login server               │
│ • ACA Environment ← moved│           │ • Log Analytics workspace ID     │
│                           │           │ • Container-run UAMI ID          │
│                           │           │ • Subnet IDs (platform or BYO)   │
└───────────────────────────┘           └──────────────────────────────────┘
```

#### Identity RG rationale

The Identity RG pattern (empty org-level RG, populated at project time) is valid and useful for the following reasons:

- **Centralized RBAC:** A single identity RG allows platform administrators to set consistent access policies for all UAMIs in one place.
- **Discoverability:** All project UAMIs are co-located, making auditing and lifecycle management straightforward.
- **No per-project RG overhead:** Avoids creating a separate identity RG per project, which would increase management surface.
- **The RG itself is not empty at runtime** — it contains all project UAMIs after projects are provisioned.

### 5.3 What stays the same (revised)

- Bootstrap resources (Storage Account, Key Vault)
- Identity resource group (shared container for project UAMIs)
- Agents resource group for org-scoped resources (ACR, Log Analytics, container-run UAMI) — the ACA Environment moves out of this RG at the project level per Section 5.4.1
- Network resource group and platform-managed VNet creation
- Dev Center and DevBox definitions
- Container image build tasks

> **Note:** "What stays the same" refers to resources that remain at the organization level.

### 5.4 What changes (target architecture)

> **Note:** The subsections below describe the **target architecture**. §5.4.1 is the formalized target for the ACA Environment refactor; §5.4.2 and §5.4.3 are also part of the target architecture.

#### 5.4.1 ACA Environment moved to project level (TARGET ARCHITECTURE)

**Target design.** The ACA Environment (runner compute plane) is a **project-level** resource. It is created by the project module (`project_github` / `project_azuredevops`) inside the **project's DevOps VNet** — either the platform VNet (when `network_mode = "platform"`) or the BYO VNet (when `network_mode = "byo"`). The Platform LZ no longer creates an ACA Environment.

**Why this is correct:**

1. An Azure Container Apps Environment is bound to **exactly one VNet** at creation time. A single org-level ACA Environment cannot serve projects whose BYO VNets are disjoint from the platform VNet. Making the ACA Environment project-scoped removes this structural conflict.
2. Self-hosted runners that execute Terraform against the project's target subscriptions need network line-of-sight to the Azure resources they deploy (private endpoints on Storage, Key Vault, SQL, private-linked PaaS services, peered application VNets). Those network paths are defined by the **project's DevOps VNet**, so the runner compute must live there.
3. Cross-project compute isolation: A runner outage, scaling limit, or misconfiguration in one project's ACA Environment does not affect another project.

**Responsibility split (target):**

| Layer                 | Provides                                                                                                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Platform LZ           | ACR (runner images), Log Analytics Workspace (logging sink), container-run UAMI (image pull + KV secret access), container image build tasks, platform VNet + subnets, private DNS zones    |
| Project (LZ-consumer) | ACA Environment (in project DevOps VNet), ACA Jobs / ACI runner resources, runner group / agent pool registration, project-level private endpoints, Layer 2 Storage Account for project IaC |

**Subnet resolution (target):**

```text
network_mode = "platform"                network_mode = "byo"
─────────────────────────                ────────────────────
ACA Environment subnet:                  ACA Environment subnet:
  devops_network.aca_subnet_id             byo_vnet.container_app_subnet_id
  (from LZ remote state)                   (from user input, must have
                                            Microsoft.App/environments
                                            delegation)
```

**LZ output changes required:**

- **Remove:** `container_app_environment_id` (and related ACA Environment fields) from `devops_agents` output.
- **Add (or keep):** `aca_subnet_id` on `devops_network` output so platform-mode projects can place their own ACA Environment in the correct subnet.
- **Keep:** `acr_login_server`, Log Analytics workspace ID, container-run UAMI principal/client ID — these are the shared dependencies that project-level ACA Environments bind to.

**Migration note.** This is a **breaking change** for existing deployments: the ACA Environment resource identity moves from the LZ state file to each project's state file. The migration step is:

1. `terraform state rm` the ACA Environment resource from the LZ state.
2. Delete the org-level ACA Environment in Azure (or leave it for decommissioning after all projects migrate).
3. Apply the project module, which creates a new ACA Environment in the project's DevOps VNet and re-registers runners.
4. Re-issue runner registration tokens (PATs/OIDC) since runner identity is rebound to the new environment.

The current code path (ACA Environment at LZ, consumed via `container_app_environment_id`) works for `network_mode = "platform"` projects; BYO VNet projects cannot use it and require this refactor.

#### 5.4.2 Governance outputs (PROPOSED)

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

#### 5.4.3 Proposed new outputs for project consumption

> **Note:** The outputs below are **target additions** to `devops/lz/_outputs.tf`.

```hcl
# Proposed additions to devops/lz/_outputs.tf

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
    private_endpoint_subnet_id  = local.private_endpoint_subnet_id
    aca_subnet_id               = local.container_app_subnet_id
    aci_subnet_id               = local.container_instance_subnet_id
    devbox_subnet_id            = local.devbox_subnet_id
    private_dns_zone_ids            = { for index, z in azurerm_private_dns_zone.this : index => z.id }
  }
  description = "Network information for projects using platform or BYO networking"
}
```

---

## Related Decisions

- [ADR-002: Runner Compute Model](./ADR-002-runner-compute-model.md)
- [ADR-005: VNet Architecture](./ADR-005-vnet-architecture.md)
