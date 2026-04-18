# Target Architecture Specification (DRAFT)

[English](./Target-Architecture-Spec.md) | [日本語](./Target-Architecture-Spec.ja.md)

> **Status:** Draft — planning phase (target architecture definition).
>
> **Main Purpose:** Define and refine the correct **Organization → Project → Repository → Environment** (Org-Project-Repo-Env) resource hierarchy for the DevOps Landing Zone. Every gap, goal, and design decision in this document exists to achieve a clear, consistent mapping of this hierarchy to Azure resources, VCS platforms (GitHub / Azure DevOps), and Terraform state management.
>
> **Scope:** Based on the Org-Project-Repo-Env hierarchy, redesign the DevOps Landing Zone to correctly scope resources at each layer — organization-level shared infrastructure, project-level isolation, repository-level CI/CD workflows, and environment-level identity and deployment targets.
>
> **Reading guide:** This document covers the architecture overview (as-is state, gaps, target goals, resource tables, module structure, and migration path). Detailed design decisions are documented in separate [Architecture Decision Records (ADRs)](#architecture-decision-records-adrs) — one per topic area.

---

## Table of Contents

1. [Motivation & Problem Summary](#1-motivation--problem-summary)
2. [Target Hierarchy & Vocabulary](#2-target-hierarchy--vocabulary)
3. [Bootstrap & State Management (Two-Layer)](#3-bootstrap--state-management-two-layer)
4. [Module & Directory Structure (Target)](#4-module--directory-structure-target)
5. [Architecture Decision Records (ADRs)](#architecture-decision-records-adrs)
6. [Migration Path from Current Design](#5-migration-path-from-current-design)
7. [Decision Log (Resolved Questions)](#6-decision-log-resolved-questions)

---

## 1. Motivation & Problem Summary

### Main purpose: Defining the Org-Project-Repo-Env hierarchy

The primary objective of this document is to **define and refine the correct Organization → Project → Repository → Environment (Org-Project-Repo-Env) resource hierarchy** for the DevOps Landing Zone. Each layer in this hierarchy has a distinct responsibility:

| Layer            | Responsibility                                                                                   | Terraform Scope                |
| ---------------- | ------------------------------------------------------------------------------------------------ | ------------------------------ |
| **Organization** | Shared infrastructure and governance used by all projects (ACR, Dev Center, VNet, DNS, rulesets) | `devops/lz` (Tier 1)           |
| **Project**      | Logical grouping of repos, identities, runners, and network context for one product/workload     | `project_github` etc. (Tier 2) |
| **Repository**   | Individual Git repo with profile-driven CI/CD workflows and optional per-repo identity           | Within project module          |
| **Environment**  | Deployment target mapping 1:1 to an Azure subscription, UAMI, and GitHub/ADO environment         | Within project module          |

Every gap identified below, every goal, and every design decision in subsequent sections exists to ensure resources are **correctly scoped** to the right layer of this hierarchy.

### Current state and gaps (analyzed by hierarchy layer)

| Hierarchy Layer   | Area                       | Today                                                                                                                   | Gap (hierarchy violation or missing capability)                                                                                                                                                                                                                              |
| ----------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Organization**  | Org governance             | GitHub org name is passed as a string; no governance boundary                                                           | No formalized org-level rulesets, runner groups, or repository defaults. Governance is ad-hoc at the project level.                                                                                                                                                          |
| **Organization**  | ACA Environment scoping    | ACA Environment created at Platform LZ level                                                                            | ACA Environment should be project-scoped. Each project should create its own ACA Environment in its runner network context. See [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md).                                                                                    |
| **Organization**  | Identity RG                | Empty RG created at Platform LZ                                                                                         | RG-only deployment is valid — it serves as a shared container for project UAMIs. Verified correct. See [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md).                                                                                                             |
| **Organization**  | Shared agents resources    | ACR, Log Analytics, container-run UAMI at platform level                                                                | Correctly scoped. These are consumed by all projects.                                                                                                                                                                                                                        |
| **Organization**  | Dev Center                 | Dev Center + definitions at platform level                                                                              | Correctly scoped. DevBox project pools are created per project referencing org-level Dev Center.                                                                                                                                                                             |
| **Project**       | Project model              | 1 project = 1 main repo + optional templates repo                                                                       | Real projects often have multiple repos (infra, app, data, ops, shared libs). No multi-repo support.                                                                                                                                                                         |
| **Project**       | Network / VNet             | Platform always creates a new VNet from address-prefix inputs                                                           | No option to plug into an existing (enterprise-provided) VNet at the project level. Self-hosted runners need to be in the project's VNet.                                                                                                                                    |
| **Project**       | Layer 2 state storage      | Project creates blob containers in Layer 1 Storage Account                                                              | Per-project Storage Account (LRS by default, selectable replication) in a project-scoped RG inside the platform subscription. Includes a project-owned Key Vault. See §3.2.                                                                                                  |
| **Project**       | Azure DevOps module        | No `project_azuredevops` root module in the codebase                                                                    | Only `project_github` exists. `project_azuredevops` is referenced in the document and will implement the same interface.                                                                                                                                                     |
| **Repository**    | Repo → workflow mapping    | Single repo gets a fixed set of workflows                                                                               | No concept of repository profiles. All repos get the same CI/CD shape regardless of purpose (infra vs app vs library).                                                                                                                                                       |
| **Repository**    | Per-repo identity          | One UAMI set per project (shared across repos)                                                                          | No option for per-repo UAMI for fine-grained RBAC (e.g., infra repo gets Contributor, app repo gets only AcrPush).                                                                                                                                                           |
| **Environment**   | Env → subscription mapping | Subscriptions variable is flexible (`default = {}`); subscription-level role assignments are conditional via `lookup()` | The target architecture supports subset environments: only create GitHub Actions Environments, UAMIs, branches, and federated credentials for the environments present in the `subscriptions` map.                                                                           |
| **Environment**   | Identity strategy          | UAMIs created per environment × job type                                                                                | Strategy now documented in [ADR-003](./adr/ADR-003-project-multi-repo-model.md) (UAMIs are project-scoped, created at Tier 2 in the org-level identity RG; no global subscription registry at the LZ). Per-repo UAMI isolation is still a target (see Repository row above). |
| **Cross-cutting** | Bootstrap state            | Single bootstrap creates Storage Account + Key Vault for tfstate                                                        | Two-layer model: Layer 1 platform storage (bootstrap SA) and Layer 2 per-project storage (project-scoped SA with LRS-by-default, selectable replication).                                                                                                                    |
| **Cross-cutting** | GitHub vs Azure DevOps     | Separate code paths, no unified abstraction                                                                             | GitHub lacks a "Project" concept that Azure DevOps has; no consistent governance model across both.                                                                                                                                                                          |
| **Cross-cutting** | Portfolio onboarding       | Each project provisioned via separate `terraform apply`                                                                 | No self-service or GitOps-driven onboarding pattern.                                                                                                                                                                                                                         |
| **Cross-cutting** | Documentation              | Paths reference `infra/terraform/…` while code lives under `infra/…`                                                    | Confusing for adopters.                                                                                                                                                                                                                                                      |

### Goals (to achieve correct Org-Project-Repo-Env hierarchy)

1. Define a clear **Organization → Platform LZ → Project → Repository Set → Environments** hierarchy, with each resource correctly scoped to its layer.
2. Introduce a **two-layer state management** model: Layer 1 for platform/DevOps LZ state (bootstrap, LZ, project provisioning) and Layer 2 for per-project application IaC state (created during project provisioning as a separate Storage Account).
3. Allow a project to own **multiple repositories** with different profiles, while keeping single-repo as a valid option.
4. Design a **unified abstraction layer** that accommodates both GitHub (no Project concept) and Azure DevOps (Org → Project → Repos).
5. Support **"Bring Your Own VNet"** at the project level, with self-hosted runners in the project's VNet.
6. Move **ACA Environment** from org level to project level so that runner compute operates in the correct network context.
7. Strengthen **organization-level governance** for both GitHub and Azure DevOps with platform-agnostic governance variables.
8. Provide a **GitOps-driven project/repository onboarding** pattern (issue → PR → provisioning).
9. Clarify the **identity and subscription mapping** strategy — UAMIs are project-scoped, subscriptions are declared per project, with optional per-repo identity isolation.
10. Implement the `project_azuredevops` root module to achieve parity with `project_github`.
11. Provide a simple migration guide for V1 users to adopt the redesigned V2 architecture.

### Architecture goals (target at a glance)

> **Purpose of this subsection.** Before the rest of the document dives into the as-is state, the gaps, the to-be design, and how each gap is closed, this subsection summarizes **where we are going** so readers have the target architecture in mind throughout. Each bullet below is realized by the section referenced in parentheses; no new decisions are introduced here.

**1. Four-layer resource hierarchy — Organization → Project → Repository → Environment** (§2)

- **Organization (Platform LZ, `devops/lz`)** — shared, org-wide infrastructure: bootstrap Storage Account (Layer 1 state), ACR, Log Analytics, container-run UAMI, Platform VNet, private DNS zones, Dev Center, container image build tasks.
- **Project (`project_github` / `project_azuredevops`)** — the unit of team ownership and billing isolation. Owns per-project UAMIs, OIDC credentials, Layer 2 state Storage Account, ACA Environment, project DevOps VNet (platform-provided or BYO), and DevBox pool.
- **Repository** — one or more repos per project, each driven by a CI/CD profile (e.g., `terraform-env`, `container-image`).
- **Environment** — 1:1 mapping of a GitHub/ADO environment to an Azure subscription plus its plan/apply UAMI pair. Environments are declarative (a subset of {features, development, staging, production} is allowed).

**2. Two-layer state management** (§3.2)

- **Layer 1 — Platform state** (single Storage Account, created by `_bootstrap`): stores tfstate for bootstrap, Platform LZ, and project provisioning (`project_github` / `project_azuredevops`).
- **Layer 2 — Per-project application state** (one Storage Account per project, created during project provisioning): stores tfstate for the project team's own application IaC (e.g., workload VNets, AKS, app resources). Layer 2 is fully owned by the project and is reached over private endpoint from the project DevOps VNet.

**3. Three-tier VNet model** ([ADR-005](./adr/ADR-005-vnet-architecture.md))

- **Platform LZ VNet** (org-scoped, `devops/lz`) — private endpoints for bootstrap SA/KV, NAT egress, shared DNS zones.
- **Project DevOps network context** (project-scoped: a project-dedicated subnet slice within the shared Platform LZ VNet in `platform` mode, or a BYO VNet in `byo` mode) — hosts the runner ACA Environment, Layer 2 tfstate private endpoint, and DevBox pool.
- **Application / Workload VNet** (per-environment, owned by the project team's own IaC) — where actual app workloads deploy. Peering between the project's DevOps network context and the Application VNet is an enterprise hub-and-spoke concern and is **not** created by the LZ.

**4. Project-scoped ACA Environment for self-hosted runners** ([ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md))

- ACA Environment is created by the **project module** and bound to a subnet of the project's DevOps network context, because an ACA Environment is bound to exactly one VNet and therefore cannot serve BYO-VNet projects from a shared platform location.
- Platform LZ continues to provide the shared prerequisites: ACR, Log Analytics, container-run UAMI, container image build tasks, and private DNS zones.

**5. Identity and subscription mapping** ([ADR-003](./adr/ADR-003-project-multi-repo-model.md), [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md))

- Each project gets **7 UAMIs** created at project time: `feat-plan`, `dev-plan`, `stg-plan`, `prod-plan`, `dev-apply`, `stg-apply`, `prod-apply`. All UAMIs live in the org-level Identity RG (centralized RBAC and discoverability) but are project-scoped in naming and lifecycle.
- Subscriptions are declared per project; role assignments on subscriptions are conditional on the subscription being present, so a project can opt into a subset of environments.
- OIDC federated credentials bind each UAMI to the matching GitHub environment / ADO service connection.

**6. Unified GitHub / Azure DevOps abstraction** ([ADR-004](./adr/ADR-004-github-ado-abstraction.md))

- A DevOps LZ "Project" is a platform-agnostic concept. For GitHub, a Project is a naming prefix + a repository set + 7 UAMIs. For Azure DevOps, a Project maps 1:1 to an `azuredevops_project`. Governance variables (rulesets, runner groups, repository defaults) are defined once and applied to the correct primitive on each platform.

**7. Organization-level governance** ([ADR-006](./adr/ADR-006-organization-governance.md))

- Platform-agnostic governance inputs drive GitHub rulesets + runner groups + repository defaults, and Azure DevOps branch policies + agent pools + project settings, so both platforms reach governance parity from the same declarative source.

**8. GitOps-driven project / repository onboarding** ([ADR-007](./adr/ADR-007-gitops-onboarding.md))

- New projects and new repositories are requested via a governance repository (issue → YAML PR → automated `project_*` apply), so Platform LZ and project team interactions are auditable and reviewable.

**9. Two intentional network modes — `platform` and `byo` — with consistency rules** ([ADR-005](./adr/ADR-005-vnet-architecture.md))

- `network_mode = "platform"` is the **low-friction default** for projects that do not (yet) own an enterprise spoke VNet: the Platform LZ pre-provisions the VNet, NAT egress, private DNS zones, and bootstrap private endpoints once at the org level, and the project consumes a project-dedicated subnet slice via LZ outputs. All seven BYO consistency rules are satisfied automatically with no peering or DNS-link work for the project team.
- `network_mode = "byo"` is the **enterprise integration mode** for projects that must land in a pre-provisioned hub-and-spoke spoke (corporate firewall, DNS forwarding, address-plan governance). The project supplies an existing VNet/subnet IDs and must satisfy the seven consistency rules vs. the Platform LZ VNet (private DNS zone linkage, bootstrap SA/KV reachability via peering, ACR pull path, ACA subnet delegation, address-space non-overlap, split-horizon DNS isolation, cross-environment VNet consistency).
- Both modes are first-class and complementary — `platform` mode is **not** retained for backward compatibility (see [ADR-005](./adr/ADR-005-vnet-architecture.md) for the rationale). A project may also start in `platform` mode and migrate to `byo` later without changing the project module contract.

**10. `project_azuredevops` at parity with `project_github`** ([ADR-003](./adr/ADR-003-project-multi-repo-model.md), [ADR-004](./adr/ADR-004-github-ado-abstraction.md))

- The Azure DevOps root module implements the same Project → Repo → Environment contract, the same 7-UAMI identity model, the same Layer 2 state storage, and the same ACA Environment binding as `project_github`.

> **Reading the rest of the document.** Sections 2–3 define hierarchy and state layering; Section 4 gives the target module layout. Detailed design decisions are documented in separate ADR documents (see the [ADR index](#architecture-decision-records-adrs) below). Section 5 covers migration and Section 6 the decision log.

### Architecture diagrams (target at a glance)

> **Purpose of this subsection.** The following three diagrams visualize the architecture goals above so readers can see the destination at a glance before reading the as-is / gaps / to-be discussion. They depict the **target** state, not the current code — detailed design per topic is in the ADR documents.

#### Diagram 1 — Org-Project-Repo-Env hierarchy + two-layer state ownership (Goals 1, 2, 5, 6, 7)

Shows the four-layer resource hierarchy and which layer owns which tfstate (Layer 1 platform vs. Layer 2 per-project), plus the platform-agnostic Project abstraction over GitHub and Azure DevOps.

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ ORGANIZATION  (GitHub Org │ Azure DevOps Org)                              │
│                                                                             │
│  ┌─ Bootstrap (infra/_bootstrap) ────────────────────────────────────────┐ │
│  │  Layer 1 Storage Account  ◄── tfstate: bootstrap, LZ, project_*       │ │
│  │  Bootstrap Key Vault       (VCS PATs)                                 │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                  │                                          │
│  ┌─ Platform LZ (devops/lz) ─────▼───────────────────────────────────────┐ │
│  │  ACR  •  Log Analytics  •  container-run UAMI                         │ │
│  │  Identity RG (org container for project UAMIs)                        │ │
│  │  Platform VNet  •  Private DNS zones  •  NAT  •  Dev Center           │ │
│  │  Org-level governance (rulesets / runner groups / agent pools — §9)   │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                  │ remote_state outputs                     │
│        ┌─────────────────────────┴────────────────────────┐                 │
│        ▼                                                  ▼                 │
│  ┌─ PROJECT A (project_github) ──────┐   ┌─ PROJECT B (project_azuredevops)┐│
│  │  7 UAMIs  (feat-plan, dev/stg/prod│   │  7 UAMIs (same shape)           ││
│  │           plan+apply)              │   │  ADO Project = boundary         ││
│  │  Layer 2 Storage Account ◄── app  │   │  Layer 2 SA ◄── app tfstate     ││
│  │  ACA Environment (project runner  │   │  ACA Environment (project runner││
│  │  network context)                 │   │  network context)               ││
│  │  Subscriptions: { dev, stg, prod }│   │  Subscriptions: { dev, prod }   ││
│  │  ┌─ REPOSITORIES ────────────────┐│   │  ┌─ REPOSITORIES ──────────────┐││
│  │  │  repo-infra  (profile=infra)  ││   │  │  repo-infra (profile=infra) │││
│  │  │  repo-app    (profile=app)    ││   │  └─────────────────────────────┘││
│  │  └───────────────────────────────┘│   │  ┌─ ENVIRONMENTS ──────────────┐││
│  │  ┌─ ENVIRONMENTS ────────────────┐│   │  │  dev → sub-dev  (UAMIs)     │││
│  │  │  features → sub-feat (UAMI)   ││   │  │  prod → sub-prod (UAMIs)    │││
│  │  │  dev / staging / prod → subs  ││   │  └─────────────────────────────┘││
│  │  └───────────────────────────────┘│   └─────────────────────────────────┘│
│  └────────────────────────────────────┘                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Diagram 2 — Three-tier VNet model + BYO consistency rules (Goals 3, 9)

Shows the three VNet tiers, who owns each, and the consistency contract a BYO project VNet must satisfy with respect to the Platform LZ VNet.

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ TIER 1 — Platform LZ VNet  (org-scoped, devops/lz)                         │
│  • Private endpoints: bootstrap SA, bootstrap KV                           │
│  • Private DNS zones (linked to project VNets)                             │
│  • NAT egress                                                              │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ peering + DNS-zone link
                                   │ (7 consistency rules — [ADR-005](./adr/ADR-005-vnet-architecture.md))
        ┌──────────────────────────┴───────────────────────────┐
        ▼                                                      ▼
┌─ TIER 2 — Project DevOps network context ┐   ┌─ TIER 2 — Project DevOps network ┐
│  Mode: platform (project subnet slice in │   │  context                         │
│  shared Platform LZ VNet)                │   │  Mode: byo (project-supplied)   │
│  • ACA Environment subnet (delegated)   │   │  • ACA Environment subnet     │
│    └─ self-hosted runner Jobs           │   │    (delegated, BYO-validated) │
│  • Layer 2 SA private endpoint subnet   │   │  • Layer 2 SA private endpoint│
│  • DevBox network connection            │   │  • DevBox network connection  │
└────────────────────┬────────────────────┘   └─────────────┬─────────────────┘
                     │ hub-and-spoke peering (NOT created by LZ — [ADR-005](./adr/ADR-005-vnet-architecture.md))
                     ▼                                      ▼
┌─ TIER 3 — Application / Workload VNet (per-environment, project team's IaC)─┐
│  • Owned and deployed by the project's own Layer 2 Terraform                │
│  • Hosts AKS / App Service / VMs / databases / app private endpoints        │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Diagram 3 — Project module composition (Goals 4, 5, 8, 10)

Shows what a single project module deploys at apply time, how it consumes Platform LZ outputs, and how the GitOps onboarding repository drives provisioning. This is the project-scoped view of the project-scoped ACA Environment goal ([ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md)).

```text
                ┌──────────────────────────────────┐
                │ GitOps onboarding repo ([ADR-007](./adr/ADR-007-gitops-onboarding.md))     │
                │  issue → YAML PR → CI apply      │
                └───────────────┬──────────────────┘
                                │ project YAML
                                ▼
┌── PROJECT MODULE  (project_github | project_azuredevops) ──────────────────┐
│                                                                             │
│  Inputs ─────────────────────────────────────────────────────────────────┐  │
│  • remote_state(devops/lz) → ACR id, Log Analytics id, container-run     │  │
│    UAMI id, Identity RG id, Platform VNet/subnet ids, DNS zone ids       │  │
│  • project YAML: name, repos[], subscriptions{}, network_mode, byo_vnet  │  │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  Project-scoped Azure resources ────────────────────────────────────────┐   │
│  ┌─────────────────────────┐  ┌──────────────────────────────────────┐ │   │
│  │ Identity (in org RG)    │  │ Layer 2 Storage Account              │ │   │
│  │  7 UAMIs:               │  │  • app-tfstate container             │ │   │
│  │   feat-plan             │  │  • private endpoint in runner network│ │   │
│  │   dev/stg/prod plan     │  │    context; DNS zone link to         │ │   │
│  │   dev/stg/prod apply    │  │    platform zones                    │ │   │
│  └─────────────────────────┘  └──────────────────────────────────────┘ │   │
│  ┌─────────────────────────┐  ┌──────────────────────────────────────┐ │   │
│  │  + OIDC fed creds       │  │ ACA Environment (PROJECT-SCOPED)     │ │   │
│  └─────────────────────────┘  │  • bound to the project's runner     │ │   │
│  ┌─────────────────────────┐  │    network context                   │ │   │
│  │ Subscription role asgmt │  │  • runs Jobs from shared ACR image   │ │   │
│  │  per env (conditional)  │  │  • logs → shared Log Analytics       │ │   │
│  └─────────────────────────┘  └──────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  VCS-scoped resources (per platform) ───────────────────────────────────┐   │
│  • Repositories (with profile-driven workflow files)                    │   │
│  • Environments × {features, dev, staging, prod} ↔ subscriptions        │   │
│  • OIDC trust to UAMIs    • Per-project runner / agent group reference  │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Resource list by layer (target architecture)

The following tables enumerate the Azure / VCS resources the DevOps Landing Zone provisions, grouped by the layer that owns them. Each table answers: **what is the resource, and what is it for?** This is the authoritative resource-by-resource definition referenced by the architecture goals (§1) and elaborated in Sections 3–10.

#### Table A — Root bootstrap layer (`infra/_bootstrap` → `modules/bootstrap`)

Provisions only the resources required to manage the DevOps platform itself (Layer 1 tfstate backend and its protection). Run once per organization, before Platform LZ. State is stored locally on the operator workstation and then migrated to the platform Storage Account it creates.

| Resource                                                | What is it                                                          | What is it for                                                                                                       |
| ------------------------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Bootstrap Resource Group                                | Azure Resource Group hosting all bootstrap resources                | Container for the Layer 1 backend Storage Account, Key Vault, and CMK identity; lifecycle anchor for tfstate backend |
| Layer 1 Storage Account (tfbackend)                     | Azure Storage Account with blob versioning + immutability           | Stores **Layer 1** tfstate for `_bootstrap`, `devops/lz`, and `project_github` / `project_azuredevops`               |
| `tfstate` blob containers (one per consumer)            | Blob containers inside the Layer 1 SA                               | Per-module tfstate containers (bootstrap, lz, project\_\*)                                                           |
| Bootstrap Key Vault                                     | Azure Key Vault (purge-protected, RBAC)                             | Holds the Customer-Managed Key (CMK) used to encrypt the Layer 1 Storage Account at rest                             |
| `tfbackend_cmk` Key                                     | RSA key in the bootstrap Key Vault                                  | CMK that encrypts the Layer 1 Storage Account (defense in depth for tfstate)                                         |
| Bootstrap UAMI                                          | User-Assigned Managed Identity                                      | Identity granted CMK access on the Storage Account (`Storage Account → Key Vault` encryption chain)                  |
| `azurerm.tfbackend` config files (`local_file` outputs) | Generated Terraform backend config templates on the operator's disk | Wires `_bootstrap`, `devops/lz`, and project modules to the Layer 1 SA / containers without manual editing           |

#### Table B — Organization-wide Platform Landing Zone (`infra/devops/lz`)

Provisions shared infrastructure consumed by **all** projects in the organization. One deployment per organization. Outputs are read by every project module via `terraform_remote_state`.

| Category   | Resource                                                                                                         | What is it                                                                       | What is it for                                                                                                                                                                                                                                                  |
| ---------- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| RGs        | Agents RG                                                                                                        | Resource Group                                                                   | Hosts shared agents/runner infrastructure (ACR, Log Analytics, container-run UAMI; ACA Environment in current code, see [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md))                                                                               |
| RGs        | Identity RG                                                                                                      | Resource Group (empty at LZ time)                                                | Org-level container that **project modules** populate with the 7 per-project UAMIs at Tier 2 (centralized RBAC and discoverability — see [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md) Identity RG rationale)                                        |
| RGs        | Network RG                                                                                                       | Resource Group                                                                   | Hosts the Platform LZ VNet, subnets, NAT, Private DNS Zones, and Private Endpoints                                                                                                                                                                              |
| RGs        | DevBox RG                                                                                                        | Resource Group                                                                   | Hosts the org-level Dev Center and Dev Box definitions                                                                                                                                                                                                          |
| Agents     | Azure Container Registry (ACR)                                                                                   | Premium ACR with private endpoint                                                | Stores the self-hosted runner container image used by every project's ACA Jobs (one shared image, many project-scoped runners)                                                                                                                                  |
| Agents     | ACR Build Task                                                                                                   | `azurerm_container_registry_task`                                                | Builds and refreshes the runner container image inside the platform (no external CI required)                                                                                                                                                                   |
| Agents     | Log Analytics Workspace                                                                                          | Shared LA workspace                                                              | Centralized logs/metrics for runner ACA Environments and Jobs across all projects                                                                                                                                                                               |
| Agents     | Container-Run UAMI                                                                                               | UAMI assigned to ACA Jobs                                                        | Identity used by runner containers to pull from ACR and write logs to Log Analytics (shared across projects)                                                                                                                                                    |
| Agents     | ~~ACA Environment~~ _(target: move to project level — [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md))_ | _(target: no longer created at LZ level)_                                        | The ACA Environment is a project-scoped resource in the target architecture. The LZ continues to host shared infra (ACR, Log Analytics, container-run UAMI) consumed by project-level ACA Environments. See Table C for the project-scoped ACA Environment row. |
| Network    | Platform LZ VNet                                                                                                 | Azure Virtual Network                                                            | Hub VNet for the platform: hosts bootstrap SA / KV Private Endpoints, runner subnet (used by project-scoped ACA in `platform` mode), DevBox subnet, and Private DNS Zone links                                                                                  |
| Network    | Subnets (runner, devbox, private-endpoint, etc.)                                                                 | VNet subnets with delegations as needed                                          | Provide the project-dedicated address slices (in `platform` mode) and platform-shared service slices                                                                                                                                                            |
| Network    | NAT Gateway _(if configured)_                                                                                    | Azure NAT Gateway                                                                | Deterministic egress for runner Jobs (so customers can allow-list the egress IPs in private endpoints / firewalls)                                                                                                                                              |
| Network    | Private DNS Zones                                                                                                | Azure Private DNS Zones for `blob`, `vault`, `azurecr.io`, `containerapps`, etc. | Resolve the platform's Private Endpoints from the platform VNet and from BYO project VNets that link to these zones (see [ADR-005](./adr/ADR-005-vnet-architecture.md))                                                                                         |
| Network    | Private Endpoints (Layer 1 SA, KV)                                                                               | Private Endpoints into the platform VNet                                         | Make the bootstrap Storage Account and Key Vault reachable only over private connectivity                                                                                                                                                                       |
| KV secrets | VCS PAT secrets (GitHub / Azure DevOps)                                                                          | Secrets stored in the bootstrap Key Vault                                        | Securely surface VCS Personal Access Tokens to project modules (`project_github` / `project_azuredevops`) via Key Vault data source — never persisted in tfvars                                                                                                 |
| Dev Center | Azure Dev Center                                                                                                 | Microsoft Dev Box service root                                                   | Org-wide control plane for developer Dev Boxes used across projects                                                                                                                                                                                             |
| Dev Center | Dev Box Definitions                                                                                              | Per-image / per-SKU Dev Box definitions                                          | Catalog of Dev Box images that project teams can attach to their projects                                                                                                                                                                                       |
| Dev Center | Dev Center Network Connection                                                                                    | Network connection bound to the Platform LZ VNet                                 | Anchors Dev Box pools to platform networking so Dev Boxes share the same private DNS / egress posture as runners                                                                                                                                                |
| Governance | Org-level rulesets / runner groups _(target — [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md))_         | GitHub org rulesets, Azure DevOps agent pools / groups (planned)                 | Enforce branch protection, required workflows, and per-project runner isolation at the organization level (parity for both VCS platforms)                                                                                                                       |

#### Table C — Per-project (`infra/devops/project_github`, future `infra/devops/project_azuredevops`)

Provisions one project's Azure resources, identities, and VCS-side configuration. Run once per project. Consumes Platform LZ outputs (Table B) via `terraform_remote_state`. The same resource set will be created by `project_azuredevops` so GitHub and Azure DevOps projects are functionally equivalent.

| Category     | Resource                                                                   | What is it                                                                                                                   | What is it for                                                                                                                                                                                                                                         |
| ------------ | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Identity     | 7 Project UAMIs                                                            | UAMIs created in the org-level Identity RG (Table B)                                                                         | Per-environment, per-job-type identities: `feat-plan`, `dev-plan`, `stg-plan`, `prod-plan`, `dev-apply`, `stg-apply`, `prod-apply` — one identity per (env × job) for least-privilege workflows ([ADR-003](./adr/ADR-003-project-multi-repo-model.md)) |
| Identity     | OIDC Federated Credentials                                                 | `azurerm_federated_identity_credential` per UAMI                                                                             | Trust the project's GitHub repo / Azure DevOps service connection to mint Azure tokens for each (env × job) without storing client secrets                                                                                                             |
| Identity     | Subscription role assignments _(conditional, per env)_                     | Built-in / custom RBAC role assignments on the env subscription                                                              | Grant `*-plan` UAMIs read-only and `*-apply` UAMIs deploy-time scopes against the subscription mapped to that environment (only when a subscription is provided for the env)                                                                           |
| State        | Layer 2 Storage Account                                                    | Per-project Storage Account (LRS by default, selectable replication) in a project-scoped RG inside the platform subscription | Stores **Layer 2** tfstate for the project team's own application IaC, isolated from the Layer 1 platform SA                                                                                                                                           |
| State        | Layer 2 Project Resource Group                                             | New project-scoped Resource Group inside the platform subscription                                                           | Houses the Layer 2 Storage Account, Project Key Vault, and Layer 2 Private Endpoint — all project-owned resources in a single RG                                                                                                                       |
| Secrets      | Project Key Vault ([ADR-005](./adr/ADR-005-vnet-architecture.md) rule #3)  | Per-project Key Vault (deployed in the project's runner VNet)                                                                | Stores the project team's own secrets and keys (e.g., app config, DB passwords, signing keys). Distinct from the org-level bootstrap Key Vault (which only holds VCS PATs used at provisioning time).                                                  |
| State        | Layer 2 Private Endpoint + DNS link                                        | Private Endpoint for the Layer 2 SA in the project's runner network context                                                  | Keep app-tfstate access on the private network used by the project's runners                                                                                                                                                                           |
| Compute      | ACA Environment ([ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md)) | Project-scoped Azure Container Apps Environment                                                                              | Runs the project's self-hosted runner Jobs. Bound to the project's runner network context (project-dedicated subnet in the Platform LZ VNet for `platform` mode, BYO VNet for `byo` mode)                                                              |
| Compute      | ACA Jobs / ACI Jobs                                                        | Self-hosted runner job definitions                                                                                           | Pull the runner image from the shared ACR and execute CI workflows for the project's repositories                                                                                                                                                      |
| Dev Box      | Dev Center Project + Pool                                                  | Dev Center Project bound to the org Dev Center, plus a Pool                                                                  | Lets the project's developers provision Dev Boxes from the org-wide catalog (Table B), scoped to this project                                                                                                                                          |
| Dev Box      | Dev Box role assignments                                                   | RBAC for Dev Box admin / user on the Dev Center Project                                                                      | Grants the project's team appropriate access to provision and manage their Dev Boxes                                                                                                                                                                   |
| Custom RBAC  | Custom roles (e.g., blob container reader)                                 | Project-scoped custom RBAC role definitions / assignments                                                                    | Fine-grained access from runner UAMIs to the project's tfstate container(s) and to other project resources                                                                                                                                             |
| VCS — GitHub | Repositories (one per profile)                                             | GitHub repositories provisioned by the module                                                                                | Project's source repositories with the standard branch / file layout the workflow templates expect                                                                                                                                                     |
| VCS — GitHub | GitHub Environments × {features, dev, staging, prod}                       | GitHub deployment environments per repo                                                                                      | Bind each (env × job) to the corresponding UAMI via OIDC + protection rules (reviewers, branch policies)                                                                                                                                               |
| VCS — GitHub | Workflow files (profile-driven)                                            | YAML workflows materialized from the `github_workflows` module                                                               | Standardized plan/apply pipelines targeting the 7 (env × job) combinations and the project's runner ACA Environment                                                                                                                                    |
| VCS — GitHub | Per-project runner reference                                               | GitHub runner group / labels referencing the project ACA runner                                                              | Routes the project's CI jobs to its own runners (no cross-project runner sharing)                                                                                                                                                                      |
| VCS — ADO    | Azure DevOps Project + repos + pipelines                                   | Azure DevOps Project + Git repos + YAML pipelines                                                                            | Functional equivalent of the GitHub stack above, so the abstraction in [ADR-004](./adr/ADR-004-github-ado-abstraction.md) holds end-to-end                                                                                                             |

---

## 2. Target Hierarchy & Vocabulary

```text
┌────────────────────────────────────────────────────────────────────┐
│  Organization (GitHub Org / Azure DevOps Org)                     │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Bootstrap  (infra/_bootstrap)                              │  │
│  │  • Storage Account (Layer 1: platform tfstate container)    │  │
│  │  • Key Vault (secrets for VCS PATs, etc.)                   │  │
│  │  • Terraform state: local file → then migrated to azurerm   │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                        ▼ (tfstate → azurerm)       │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Platform Landing Zone  (devops/lz)                         │  │
│  │  • Shared Azure resources for the org:                      │  │
│  │    – Identity RG (shared container for project UAMIs)       │  │
│  │    – Agents RG (ACR, Log Analytics, container-run UAMI)     │  │
│  │    – Network RG (platform-managed VNet, subnets, DNS, NAT)  │  │
│  │    – DevBox Dev Center + definitions                        │  │
│  │    – Bootstrap KV secrets (VCS PATs)                        │  │
│  │  • VCS governance:                                            │  │
│  │    – GitHub: Org-level rulesets, runner groups               │  │
│  │    – Azure DevOps: Org-level agent pools                    │  │
│  │  * ACA Environment is a project-level resource — [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md)     │  │
│  │  • Tfstate key: "devops-lz.terraform.tfstate"               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                        ▼ (remote_state)            │
│  ┌── Project A (GitHub) ─────────────────────────────────────────┐ │
│  │  DevOps LZ "Project" = logical grouping                       │ │
│  │  (GitHub: repos in a flat org │ ADO: repos inside ADO Project)│ │
│  │  repositories = [                                             │ │
│  │    { name="project-a-infra",  profile="infra"  },             │ │
│  │    { name="project-a-app",    profile="app"    },             │ │
│  │  ]                                                            │ │
│  │  network_mode = "platform"                                    │ │
│  │  subscriptions = { features, dev, staging, prod }             │ │
│  │  identities (UAMI per env × job — created at project time)   │ │
│  │  runners (ACA jobs or ACI)                                    │ │
│  │  DevBox project pool                                          │ │
│  │  Tfstate key: "projects/project-a.terraform.tfstate"          │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  ┌── Project B (Azure DevOps) ───────────────────────────────────┐ │
│  │  DevOps LZ "Project" = Azure DevOps Project boundary          │ │
│  │  project_name = "project-b"                                   │ │
│  │  repositories = [                                             │ │
│  │    { name="project-b-infra", profile="infra" },               │ │
│  │  ]                                                            │ │
│  │  network_mode = "byo"                                         │ │
│  │  byo_vnet = { vnet_id, private_endpoint_subnet_id, ... }      │ │
│  │  subscriptions = { dev, prod }                                │ │
│  └───────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### Key terms

| Term                      | Definition                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Organization**          | The top-level governance boundary — maps to a GitHub Organization or Azure DevOps Organization. Owns shared infrastructure and policies.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **Bootstrap**             | The foundational `_bootstrap` layer that creates the Storage Account (for tfstate) and Key Vault (for secrets). Runs once, produces a `bootstrap.config.json` consumed by all subsequent layers.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **Platform Landing Zone** | The shared infrastructure layer (`devops/lz`) provisioned once per organization. Creates Azure resource groups (identity, agents, network, DevBox) and shared compute/registry resources. Org-scoped resources include: ACR, Log Analytics, container-run UAMI, Dev Center, platform VNet, and private DNS zones. VCS governance resources (org-level rulesets, runner groups) are part of the target architecture (see [ADR-006](./adr/ADR-006-organization-governance.md)). The ACA Environment is a **project-level** resource in the target architecture ([ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md)). Its own tfstate is stored in the bootstrap Storage Account. |
| **Project**               | A logical grouping of repositories, environments, identities, and runner jobs that together deliver one product or workload. In GitHub, a project is a naming-convention-based grouping of repos within the flat org. In Azure DevOps, a project maps to an actual Azure DevOps Project container.                                                                                                                                                                                                                                                                                                                                                                                   |
| **Repository Set**        | The ordered list of Git repositories that belong to a project. Each repo has a **profile** that determines its CI/CD workflow shape.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **Repository Profile**    | A template that defines the branch strategy, workflow files, environments, and identity needs for a class of repository (e.g., `infra`, `app`, `library`). Profiles are a **recommendation** — users can place infra and app code in a single repo if they prefer.                                                                                                                                                                                                                                                                                                                                                                                                                   |
| **Environment**           | A deployment target — maps 1:1 to an Azure subscription and a GitHub Actions Environment (or Azure DevOps Environment) with OIDC-federated UAMI.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **Network Mode**          | How the project connects to Azure networking: `platform` (use the LZ-managed VNet) or `byo` (Bring Your Own VNet).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

---

## 3. Bootstrap & State Management (Two-Layer)

### 3.1 Problem

The current `_bootstrap` layer creates a Storage Account and Key Vault for managing Terraform state files. This storage (Layer 1) holds the state for the bootstrap itself, the Platform Landing Zone, and project provisioning modules (`project_github`, `project_azuredevops`).

However, projects provisioned via the DevOps Landing Zone may also use Terraform for their own application infrastructure (e.g., deploying Azure resources for the app). These project-level IaC states should **not** be stored in the platform's Layer 1 storage — they need their own per-project state storage (Layer 2), which is created during project provisioning.

Today this two-layer relationship is not made explicit.

### 3.2 Two-layer state management model

```text
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: Platform State Storage                                  │
│ (Created by _bootstrap — single Storage Account for the org)     │
│                                                                 │
│  Stores tfstate for:                                             │
│    • Bootstrap itself      ("bootstrap.terraform.tfstate")       │
│    • Platform LZ           ("devops-lz.terraform.tfstate")       │
│    • Project provisioning  ("projects/<name>.terraform.tfstate") │
│                                                                 │
│  Also contains:                                                  │
│    • Key Vault (PATs and secrets for LZ & project provisioning) │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2: Per-Project State Storage  (one per project)            │
│ (Created during project provisioning — project_github /          │
│  project_azuredevops modules)                                    │
│                                                                 │
│  Stores tfstate for:                                             │
│    • Project's own application IaC (e.g., Azure resources        │
│      deployed by the project team via Terraform)                 │
│                                                                 │
│  Each project gets its own Storage Account (LRS by default,      │
│  selectable replication) inside a new project-scoped RG in       │
│  the platform subscription. The project-owned Key Vault for      │
│  secrets is also housed in this RG.                              │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 Operational tiers within Layer 1

Within Layer 1, there are three operational tiers that determine the order of Terraform operations and state dependencies:

```text
┌─────────────────────────────────────────────────────────────────┐
│ Tier 0: Tfstate Bootstrap  (infra/_bootstrap)                    │
│                                                                 │
│  terraform apply (local state → then migrate to azurerm)        │
│  Creates:                                                       │
│    • Resource Group for bootstrap                               │
│    • Storage Account + "tfstate" container  (= Layer 1 storage) │
│    • Key Vault (for PATs and secrets)                           │
│  Outputs:                                                       │
│    • bootstrap.config.json (storage_account_name, etc.)         │
│    • devops.azurerm.tfbackend (backend config template)         │
│                                                                 │
│  State key: "bootstrap.terraform.tfstate"  (in Layer 1)         │
├─────────────────────────────────────────────────────────────────┤
│ Tier 1: Platform Landing Zone  (devops/lz)                      │
│                                                                 │
│  terraform init -backend-config=devops.azurerm.tfbackend        │
│  terraform apply                                                │
│  Creates:                                                       │
│    • Identity RG + container-run UAMI                           │
│    • Agents RG + ACR + Log Analytics                            │
│    • Network RG + VNet + subnets + DNS zones + NAT GW           │
│    • DevBox Dev Center + definitions                            │
│    • Bootstrap KV secrets (VCS PATs)                            │
│    • VCS governance (org-level rulesets, runner groups)          │
│  Outputs:                                                       │
│    • devops_agents, devops_identity, devops_network,            │
│      devops_devbox, container_specs, options                    │
│                                                                 │
│  State key: "devops-lz.terraform.tfstate"  (in Layer 1)         │
│  Reads: bootstrap.config.json from Tier 0                       │
├─────────────────────────────────────────────────────────────────┤
│ Tier 2: Projects  (devops/project_github or project_azuredevops)│
│                                                                 │
│  terraform init -backend-config=...                             │
│  terraform apply                                                │
│  Reads: remote_state of Tier 1 (devops/lz)                     │
│  Creates:                                                        │
│    • VCS resources (repos, workflows, environments, etc.)       │
│    • UAMIs + federated identity credentials                     │
│    • ACA Environment per project ([ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md))                       │
│    • Runners (ACA jobs using project ACA Env, or ACI)            │
│    • Layer 2 Storage Account (separate per-project SA)          │
│    • Project Key Vault                                          │
│    • DevBox project pool                                        │
│                                                                 │
│  State key: "projects/<project_name>.terraform.tfstate" (Layer 1)│
└─────────────────────────────────────────────────────────────────┘
```

### 3.4 What stays the same

- The `_bootstrap` module (`infra/_bootstrap`) is unchanged. It already creates exactly the right resources for Layer 1.
- The LZ (`devops/lz`) already reads `bootstrap.config.json` and stores its state in the Layer 1 Storage Account.
- Projects already read LZ outputs via `terraform_remote_state`.

### 3.5 What changes

The **conceptual documentation** should make the two-layer storage model explicit:

1. **Layer 1** = Platform state storage — a single Storage Account (created by `_bootstrap`) that holds the tfstate for:
   - Bootstrap itself (`bootstrap.terraform.tfstate`)
   - Platform LZ (`devops-lz.terraform.tfstate`)
   - Project provisioning (`projects/<project_name>.terraform.tfstate`)

2. **Layer 2** = Per-project state storage — a separate Storage Account per project (LRS by default, with selectable replication), created during project provisioning by `project_github` / `project_azuredevops`, that holds:
   - The project team's own application IaC state (e.g., Terraform state for Azure resources deployed by the project)
   - Deployed inside a new project-scoped Resource Group in the platform subscription, alongside the project-owned Key Vault

Layer 1 is managed by the DevOps LZ platform team. Layer 2 is consumed by the project teams for their own infrastructure-as-code workflows.

> **Note:** Within Layer 1, the operational tiers (Tier 0 → Tier 1 → Tier 2) determine the order of `terraform apply` operations and state dependencies. Tier 0 should be applied very rarely (essentially once), Tier 1 is applied when the organization's platform configuration changes, and Tier 2 is applied when a new project is onboarded or modified. All three tiers store their state in the **same** Layer 1 Storage Account. Layer 2 is a separate Storage Account created per project during Tier 2 provisioning, intended for the project team's own use.

---

## 4. Module & Directory Structure (Target)

```text
infra/
├── _bootstrap/                         # Tier 0: Layer 1 state storage + Key Vault
├── _setup_subscriptions/               # (unchanged) resource provider registration
├── devops/
│   ├── lz/                             # Tier 1: Organization-level Platform LZ
│   │   ├── _variables.tf
│   │   ├── _variables.network.tf
│   │   ├── _variables.vcs.github.tf
│   │   ├── _variables.vcs.azuredevops.tf
│   │   ├── _variables.governance.tf    # ← NEW: org-level policies & rulesets (GitHub + ADO)
│   │   ├── _outputs.tf
│   │   ├── network.vnet.tf             # platform-managed VNet (unchanged)
│   │   ├── governance.github.tf        # ← NEW: GitHub org-level rulesets, runner groups
│   │   ├── governance.azuredevops.tf   # ← NEW: Azure DevOps org-level policies
│   │   └── ...
│   │
│   ├── project_github/                 # Tier 2: Per-project resources (GitHub)
│   │   ├── _variables.tf               # CHANGED: add repositories list, network_mode
│   │   ├── _variables.network.tf       # ← NEW: BYO VNet inputs
│   │   ├── _variables.repositories.tf  # ← NEW: multi-repo definition
│   │   ├── github.tf                   # CHANGED: iterate over repositories
│   │   ├── github.workflow.tf          # CHANGED: per-repo workflow generation
│   │   ├── uami.tf                     # CHANGED: per-repo × per-env identities
│   │   ├── uami.federation.tf
│   │   ├── network.tf                  # ← NEW: BYO VNet data lookups & validation
│   │   └── ...
│   │
│   └── project_azuredevops/            # Tier 2: Per-project resources (Azure DevOps)
│       ├── _variables.tf               # CHANGED: add repositories list, network_mode
│       ├── _variables.repositories.tf  # ← NEW: multi-repo definition
│       └── ...                         # (mirrors project_github where applicable)
│
└── modules/
    ├── github/                         # CHANGED: accept list of repositories
    │   ├── repo.tf                     # (for_each over repositories)
    │   ├── repo.templates.tf           # (unchanged; still one templates repo per project)
    │   └── ...
    ├── azure_devops/                   # CHANGED: accept list of repositories
    │   ├── repo.main.tf                # CHANGED: for_each over repositories
    │   └── ...
    ├── github_workflows/               # CHANGED: generate per-profile workflows
    │   ├── _variables.tf               # add repository_profiles input
    │   └── ...
    ├── vnet/                           # (unchanged)
    └── ...                             # (other modules unchanged)
```

Additionally, the **GitOps governance repository** (for issue-driven project/repository onboarding) lives as a **separate repo** in the GitOps governance organization, set up independently as a **template repository** (not provisioned via Terraform). This repo contains **both** the project definitions (YAML) **and** the IaC modules (`project_github`, `project_azuredevops`) needed to provision them. This ensures the GitOps repo is self-contained — it does not depend on cloning the DevOps Landing Zone repo at apply time.

```text
<org>/<gitops-governance-repo>/         # Separate repo for GitOps onboarding
├── .github/
│   ├── CODEOWNERS                      # Defines approval teams per project area
│   ├── ISSUE_TEMPLATE/
│   │   └── project-request.yaml        # Issue template for new project requests
│   └── workflows/
│       ├── project-request-to-pr.yaml  # Converts issues to PRs with YAML definitions
│       └── project-create.yaml         # On PR merge: runs terraform apply for projects
│
├── projects/                           # Project definitions (source of truth)
│   ├── contoso-ecommerce.yaml          # Project definition (repos, subs, network, etc.)
│   ├── contoso-payments.yaml
│   └── ...
│
├── infra/                              # IaC modules for project provisioning
│   ├── project_github/                 # Terraform root module for GitHub projects
│   │   ├── _variables.tf
│   │   ├── _variables.repositories.tf
│   │   ├── _variables.network.tf
│   │   ├── github.tf
│   │   ├── uami.tf
│   │   └── ...
│   ├── project_azuredevops/            # Terraform root module for Azure DevOps projects
│   │   ├── _variables.tf
│   │   ├── _variables.repositories.tf
│   │   └── ...
│   └── modules/                        # Shared Terraform modules
│       ├── github/
│       ├── azure_devops/
│       ├── github_workflows/
│       └── ...
│
└── README.md
```

> **Note:** The `infra/` directory in the GitOps governance repo contains the **same** `project_github`, `project_azuredevops`, and shared modules from the DevOps Landing Zone repo. Organizations can keep them in sync via:
>
> - **Git submodule**: referencing the DevOps Landing Zone repo as a submodule under `infra/`.
> - **Terraform module registry**: publishing modules to a private registry and referencing them by version.
> - **Direct copy with version pinning**: copying the modules and tracking the upstream version in a `VERSION` file.
>
> The recommended approach is **Git submodule** or **Terraform module registry** for traceability.

---

## Architecture Decision Records (ADRs)

The following ADR documents contain detailed design decisions for each topic area. Each ADR includes context, the decision made, full technical detail, and related decisions.

| ADR                                                      | Topic                              | Summary                                                                                                        |
| -------------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.md) | Platform LZ Resource Scoping       | Which resources belong at org level vs. project level. Key finding: ACA Environment should be project-scoped.  |
| [ADR-002](./adr/ADR-002-runner-compute-model.md)         | Runner Compute Model               | Self-hosted runners on ACA chosen over GitHub-hosted + APES for five architectural reasons.                    |
| [ADR-003](./adr/ADR-003-project-multi-repo-model.md)     | Project & Multi-Repo Model         | Project definition, multi-repo support with CI/CD profiles, identity allocation strategy, subset environments. |
| [ADR-004](./adr/ADR-004-github-ado-abstraction.md)       | GitHub / Azure DevOps Abstraction  | Unified platform-agnostic "Project" concept with a shared input interface.                                     |
| [ADR-005](./adr/ADR-005-vnet-architecture.md)            | VNet Architecture (Platform & BYO) | Three-tier VNet model, `platform` and `byo` network modes, seven consistency rules, detailed network diagrams. |
| [ADR-006](./adr/ADR-006-organization-governance.md)      | Organization Governance            | Platform-agnostic governance variables driving GitHub rulesets and ADO branch policies.                        |
| [ADR-007](./adr/ADR-007-gitops-onboarding.md)            | GitOps-Driven Onboarding           | Issue → PR → merge → `terraform apply` pipeline via a self-contained governance repository.                    |
| [ADR-008](./adr/ADR-008-naming-collision-resistance.md)  | Naming & Collision Resistance      | Portfolio-safe naming patterns, tfstate key conventions, and UAMI naming with hash-based collision resistance. |

---

## 5. Migration Path from Current Design

### 12.1 Backward compatibility guarantees

| Feature                     | Current behavior | New behavior                                   | Breaking? |
| --------------------------- | ---------------- | ---------------------------------------------- | --------- |
| `repositories = []`         | N/A              | Falls back to single-repo using `project_name` | No        |
| `network_mode = "platform"` | Implicit         | Explicit default                               | No        |
| `byo_vnet = null`           | N/A              | Ignored when `network_mode = "platform"`       | No        |
| `shared_identities = true`  | Implicit         | Explicit default, same UAMI-per-env behavior   | No        |
| LZ governance outputs       | N/A              | New outputs; projects can ignore them          | No        |

### 12.2 Suggested migration steps

1. **Phase 1 — Non-breaking additions:**
   - Add `repositories` variable with default `[]`.
   - Add `network_mode` / `byo_vnet` variables with defaults.
   - Add governance variables and outputs to LZ (GitHub + Azure DevOps).
   - Document two-tier bootstrap model in Getting Started guide.
   - No existing tfvars files need to change.

2. **Phase 2 — Module refactoring:**
   - Refactor `modules/github` to iterate over a list of repositories.
   - Refactor `modules/github_workflows` to generate per-profile workflows.
   - Refactor `modules/azure_devops` for multi-repo support.
   - Add governance.github.tf and governance.azuredevops.tf to LZ.
   - Existing single-repo projects continue to work via the fallback in `_locals.tf`.

3. **Phase 3 — GitOps onboarding:**
   - Create the GitOps governance repository template.
   - Add issue templates for project and repository requests.
   - Add provisioning workflows (issue-to-PR, project-create).
   - Document the GitOps onboarding workflow.

4. **Phase 4 — Documentation & examples:**
   - Add multi-repo example tfvars.
   - Add BYO VNet example tfvars.
   - Add architecture diagrams for both modes.
   - Add GitHub vs Azure DevOps comparison guide.
   - Fix path references (`infra/terraform/…` → `infra/…`).

---

## 6. Decision Log (Resolved Questions)

| #   | Question                                                                                                                    | Options                                                             | Recommendation                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Should the GitOps governance repo be created as part of the Platform LZ (Tier 1), or set up independently?                  | Part of LZ / Independent / Template repo                            | **✅ Decided:** Set up independently as a **template repository**. Creating a GitHub repo via Terraform is complex and fragile. The GitOps governance organization in GitHub Enterprise hosts both the **platform LZ repo** (LZ IaC) and the **GitOps governance repo** (project IaC). The governance repo must include `project_github`/`project_azuredevops` IaC modules (via git submodule or registry reference) so it is self-contained. |
| 2   | Should BYO VNet be supported at the **LZ level** (the LZ itself uses an external VNet) or only at the **project level**?    | LZ-level BYO / Project-level BYO / Both                             | **✅ Decided:** Start with **project-level BYO VNet**. LZ-level BYO is a larger change and can be added later. Repo-level BYO VNet (different VNets per repo within a project) is **not practical** — see [ADR-005](./adr/ADR-005-vnet-architecture.md) for analysis.                                                                                                                                                                         |
| 3   | How should per-repo identities be named to stay within Azure naming limits?                                                 | `uami-<project>-<repo>-<env>-<job>-<rand>` / Hash-based short names | **✅ Decided:** Mixed approach — `uami-<project>-<repo>-<hash>`. Project and repo names remain human-readable for identification; `<hash>` is a short hash derived from env + job type + random seed. No need for env/job to appear in the name — they are encoded in the hash for collision resistance while keeping the name within Azure's 128-char limit. See [ADR-008](./adr/ADR-008-naming-collision-resistance.md) for details.        |
| 4   | Should repository profiles be extensible by users or fixed?                                                                 | Fixed set / User-defined profiles via HCL                           | **✅ Decided:** Start with a **fixed set** (`infra`, `app`, `library`, `docs`); allow user-defined extension later. The fixed set covers the vast majority of use cases. See [ADR-003](./adr/ADR-003-project-multi-repo-model.md) for profile definitions and design philosophy.                                                                                                                                                              |
| 5   | Should the org-level ruleset be enforced or advisory?                                                                       | `active` / `evaluate` (audit-only)                                  | **✅ Decided:** Default to **`active`** (enforced) with bypass for org admins. Advisory mode (`evaluate`) can be used during rollout but the default should enforce branch protection. See [ADR-006](./adr/ADR-006-organization-governance.md) (`enforcement = "active"`, bypass for `OrganizationAdmin`).                                                                                                                                    |
| 6   | Should BYO VNet projects share the platform ACA Environment or create their own?                                            | Shared / Per-project / Configurable                                 | **✅ Decided:** **Per-project ACA Environment** in the BYO VNet. Sharing the platform ACA Environment is not possible when the project uses a different VNet — ACA Environment requires subnet delegation in the project's VNet. See [ADR-005](./adr/ADR-005-vnet-architecture.md) for network resolution logic.                                                                                                                              |
| 7   | How to handle projects that need only a subset of environments (e.g., just dev + prod)?                                     | Allow `subscriptions` to be a subset / Require all 4                | **✅ Decided:** **Allow subset** — only create environments for the subscriptions provided. The module creates GitHub Actions Environments, UAMIs, and federated identity credentials only for the environments present in `subscriptions`. See [ADR-003](./adr/ADR-003-project-multi-repo-model.md) for a sample `terraform.tfvars` with dev + prod only.                                                                                    |
| 8   | For Azure DevOps, should the DevOps LZ always create a new ADO Project, or support referencing an existing one?             | Always create / Reference existing / Both                           | **✅ Decided:** **Both** — the `create_project` variable already exists in the `azure_devops` module. When `create_project = false`, the module references an existing ADO project by name. See [ADR-004](./adr/ADR-004-github-ado-abstraction.md) for the variable definition.                                                                                                                                                               |
| 9   | Should the GitOps provisioning workflow use GitHub-hosted runners or self-hosted runners?                                   | GitHub-hosted / Self-hosted / Configurable                          | **✅ Decided:** **Self-hosted runners** (required for private network access to tfstate storage and Azure resources behind private endpoints). The provisioning workflow uses `runs-on: [self-hosted, devops-lz]`. See [ADR-007](./adr/ADR-007-gitops-onboarding.md) for the workflow definition.                                                                                                                                             |
| 10  | How should Azure DevOps branch policies (project-scoped) be kept in sync with GitHub org-level rulesets when both are used? | Manual / Shared governance variables / Drift detection              | **✅ Decided:** **Shared governance variables** in the Platform LZ (`org_default_branch_rules`), applied by each project module at project creation time. GitHub uses org-level rulesets; Azure DevOps applies the same rules as project-level branch policies. See [ADR-006](./adr/ADR-006-organization-governance.md) for the governance parity matrix.                                                                                     |

---

> **Next steps:** All open questions are resolved. Proceed with Phase 1 implementation (non-breaking variable additions).
