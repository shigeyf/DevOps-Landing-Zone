[English](./ADR-005-vnet-architecture.md) | [日本語](./ADR-005-vnet-architecture.ja.md)

# ADR-005: VNet Architecture: Three-Tier Model, Platform and BYO Modes

> **Status:** Accepted
> **Context:** [Target Architecture Spec](../Target-Architecture-Spec.md)

## Summary

The VNet architecture follows a three-tier model: (1) Platform LZ VNet (org-shared), (2) Project DevOps network context (platform subnet slice or BYO spoke), (3) Application/Workload VNet (project team's own). Projects choose between `network_mode = "platform"` (low-friction default) and `network_mode = "byo"` (enterprise integration). Seven consistency rules govern BYO VNet integration.

---

> **Note:** BYO VNet support is a **proposed feature**. The current `project_github` module does not have a `network_mode` or `byo_vnet` variable. All projects currently use the platform-managed VNet created by `devops/lz`. The design below describes the target architecture.

### 8.0 VNet architecture overview (three-tier model)

Three distinct VNets participate in the end-to-end flow from code commit to deployed Azure resources. Keeping these distinct — and the connectivity between them consistent — is the foundation of the BYO VNet design.

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ 1) Platform LZ VNet  (org-scoped, managed by devops/lz)                   │
│    Purpose: shared infrastructure the DevOps platform itself needs        │
│    Contents:                                                              │
│      • Private endpoints for bootstrap Storage Account (Layer 1 tfstate)  │
│      • Private endpoints for bootstrap Key Vault (VCS PATs, etc.)         │
│      • DevBox subnet (if DevBox is platform-scoped)                       │
│      • NAT gateway for egress                                             │
│      • Private DNS zones (privatelink.*) — linked to this VNet           │
│    Tfstate: devops-lz.terraform.tfstate (Layer 1)                         │
└────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ (always present when enable_private_network = true)
                                   ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ 2) Project DevOps network context  (project-scoped choice — PLATFORM or   │
│                                   BYO)                                    │
│    Purpose: where the project's CI/CD compute runs                        │
│    Chosen by: network_mode = "platform" | "byo"                           │
│                                                                           │
│    Mode "platform": project-dedicated subnet slice inside the shared      │
│                     Platform LZ VNet (selected via LZ outputs)            │
│    Mode "byo":      user-provided VNet (pre-existing spoke)               │
│                                                                           │
│    Contents (created/placed by project module):                           │
│      • ACA Environment + runner Jobs (or ACI containers) ← Section 5.4.1  │
│      • Private endpoint to Layer 2 project tfstate Storage Account        │
│      • DevBox project pool (if per-project DevBox)                        │
│      • DNS links to platform private DNS zones                            │
│    Tfstate: projects/<project_name>.terraform.tfstate                     │
└────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ runner executes terraform apply against
                                   │ target subscription → needs network path
                                   ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ 3) Application / Workload VNet(s)  (per-environment, owned by project     │
│                                      team's own IaC — NOT this LZ)        │
│    Purpose: where the project's actual application resources are deployed │
│    Lives in: each target subscription (features / dev / staging / prod)   │
│    Contents:                                                              │
│      • App Services, AKS, Functions, SQL, Storage, Key Vault …           │
│      • Private endpoints on those services                                │
│    Tfstate: Layer 2 — per-project Storage Account (created by project    │
│             provisioning; see Section 3.2)                                │
└────────────────────────────────────────────────────────────────────────────┘
```

**Key distinction.** This Landing Zone is responsible for (1) the Platform LZ VNet and (2) the project's DevOps network context selection/binding (shared-platform subnet slice or BYO VNet). The Application / Workload VNet (3) is the project team's responsibility and is provisioned by the project team's own Terraform running inside the runner of layer (2). The BYO VNet variable at the project level (Section 8.4) configures layer (2) — **not** layer (3).

#### 8.0.1 Consistency rules between Platform LZ VNet and Project BYO VNet

When a project chooses `network_mode = "byo"`, the project module no longer deploys runner compute into the platform VNet; it deploys into the BYO VNet. However, the Platform LZ still owns several cross-cutting resources that the project must integrate with. These constraints must hold for correct operation:

| #   | Concern                                  | Rule                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Private DNS resolution**               | All private endpoints the runner contacts (ACR for the runner image, the project's Layer 2 tfstate Storage Account, the project's own Key Vault for project secrets, and target-subscription private-link services for resources the runner deploys) must resolve via private DNS. The BYO VNet **must be linked** to the Platform LZ's `privatelink.*` DNS zones for the org-shared records (notably `privatelink.azurecr.io`). The project module performs this linkage via `azurerm_private_dns_zone_virtual_network_link` (one link per zone) using the DNS zone IDs published in `devops_network.private_dns_zone_ids`. The `byo_vnet.link_to_platform_private_dns` flag toggles this. **Note:** the runner does **not** access the bootstrap Storage Account (Layer 1 tfstate is owned by the platform admin's apply path — `_bootstrap` / `devops/lz` / `project_github` provisioning — not by the project team's runner; see §3.2) nor the bootstrap Key Vault (which only stores VCS PATs used by `project_github` at provisioning time). |
| 2   | **ACR (runner images) reachability**     | The runner must pull its container image from the org-shared ACR (Tab. B in §1). The ACR must be reachable via private endpoint from the BYO VNet — its PE lives in the Platform LZ VNet, so the BYO VNet **must be peered** to the Platform LZ VNet (or otherwise reach the ACR PE through the enterprise hub-and-spoke). Peering and hub transit are the responsibility of the enterprise networking team, not this LZ. The container-run UAMI (platform-scoped) is bound as the `acr_pull` identity of the ACA Job regardless of which VNet the ACA Environment is in.                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 3   | **Layer 2 SA + project KV reachability** | The runner reads/writes the project's **Layer 2** tfstate from the per-project Storage Account (Table C in §1) and reads the project's secrets from the **project-owned** Key Vault (created by the project module — see §3.2 / §5.4 and Table C). Both are project-scoped and **deployed inside the project's runner network context** — i.e., into the project's BYO VNet in `byo` mode (or into the project-dedicated subnets of the Platform LZ VNet in `platform` mode). They must therefore be in the BYO PE subnet alongside the runner; no peering to the Platform LZ VNet is required for these. They are **not** part of the bootstrap SA/KV.                                                                                                                                                                                                                                                                                                                                                                                            |
| 4   | **Subnet delegations in BYO VNet**       | The BYO VNet's subnets must have the correct Azure delegations for the runner compute type: `Microsoft.App/environments` for ACA Environments, `Microsoft.ContainerInstance/containerGroups` for ACI, and the DevBox-compatible network configuration for DevBox. The project module enforces these via Terraform preconditions (Section 8.4) — they fail at `plan` time if misconfigured.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| 5   | **Address-space non-overlap**            | The BYO VNet's CIDR must **not overlap** with the Platform LZ VNet CIDR (otherwise peering fails) and ideally must not overlap with any Application / Workload VNet the project will later peer to. This is enforced outside Terraform by the enterprise networking team; the LZ validates peering state at apply time but cannot allocate address space.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 6   | **DNS isolation for split-horizon**      | BYO projects often operate behind an enterprise DNS forwarder (e.g., Azure Firewall DNS proxy, custom resolver). The platform private DNS zone links established in (1) must coexist with — and not conflict with — the enterprise's own DNS policies. The design mandates **private DNS zones only for Azure private-link records** (`privatelink.*`); public DNS remains under enterprise control.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| 7   | **Consistency across environments**      | For a multi-environment project, the runner VNet is the **same** regardless of which target subscription is being deployed to — the runner compute is project-scoped, not environment-scoped. Connectivity between the runner's VNet and each target subscription's Application/Workload VNet is the responsibility of that subscription's networking setup (typically hub-and-spoke peering or VPN gateway in the hub).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

#### 8.0.2 Relationship to Application / Workload VNets

The runner's deployment actions (e.g., creating an App Service with a private endpoint in the dev subscription) require network reachability from the runner's VNet (layer 2) to the target resource's VNet (layer 3). This Landing Zone **does not create** peering between the project DevOps VNet and application VNets. The enterprise networking pattern (typically hub-and-spoke with a central hub) is expected to provide this. The BYO VNet is usually an existing spoke in that topology, which naturally gives the runner the required reachability.

For `network_mode = "platform"`, the Platform LZ VNet serves as the DevOps VNet, and the same peering/hub-and-spoke requirement applies: the Platform LZ VNet must be peered (or otherwise reachable) from each target subscription's Application VNet for the runner to manage private-link resources there.

#### 8.0.3 Why `network_mode = "platform"` is a first-class design choice (not backward compatibility)

`platform` mode is not retained for backward compatibility. It is an intentional, first-class onboarding mode that exists alongside `byo` mode for the following architectural reasons. If `platform` mode were removed, every project would be required to negotiate a pre-provisioned enterprise VNet before the DevOps Landing Zone could be used at all — which is incompatible with the GitOps onboarding goal (§10) and with greenfield product teams.

| Aspect                                              | Value of `network_mode = "platform"`                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Low-friction onboarding**                         | A project team can stand up its DevOps environment without owning, requesting, or coordinating an enterprise spoke VNet. The Platform LZ already created the VNet, NAT egress, bootstrap private endpoints (SA/KV), and `privatelink.*` DNS zones at org provisioning time; the project just consumes a project-dedicated subnet slice via LZ outputs.                           |
| **Greenfield / POC / pre-enterprise projects**      | New product lines, prototypes, or early-stage projects often do not yet have an assigned enterprise spoke. `platform` mode makes the DevOps Landing Zone usable on day one for these projects, without blocking them on a central networking ticket.                                                                                                                             |
| **Automatic satisfaction of the consistency rules** | All seven §8.0.1 consistency rules (DNS zone linkage, bootstrap SA/KV reachability, ACR pull path, ACA subnet delegation, address-space non-overlap, split-horizon DNS, cross-environment VNet consistency) are satisfied by construction in `platform` mode — no peering, no DNS link resource, no firewall ticket. In `byo` mode the project must satisfy them explicitly.     |
| **Centralized cost and operational hygiene**        | One shared Platform LZ VNet (with project-dedicated subnets) is cheaper than N project-owned VNets and consolidates DNS-zone hygiene, NAT egress IP allocation, and private-endpoint inventory into a single place owned by the platform team.                                                                                                                                   |
| **Migration ramp to BYO**                           | A project can start in `platform` mode for fast bring-up and later switch to `byo` once enterprise networking provides a spoke, without changing the project module contract (`network_mode` flips from `"platform"` to `"byo"`; the `byo_vnet` block is added). The `terraform state mv` / re-bind path is straightforward because the project module owns the ACA Environment. |
| **Default safe path**                               | `platform` is the documented default of `network_mode`, so a minimal `terraform.tfvars` works out of the box. `byo` is opt-in for the explicit enterprise integration scenario.                                                                                                                                                                                                  |

When `network_mode = "byo"` is the right choice — and when not.

- Use **`byo`** when the project must land in a pre-provisioned spoke for compliance, central firewall/DNS, address-plan governance, or peering with on-prem.
- Use **`platform`** for everything else: greenfield projects, POCs, projects that have no central networking constraint, and projects that want zero VNet-related ticket dependencies during onboarding.

In short: BYO mode exists to satisfy enterprise constraints; `platform` mode exists to make those constraints **optional** instead of mandatory. Removing `platform` mode would force the LZ to assume every consumer is an enterprise with an existing spoke, which contradicts the LZ's onboarding and self-service goals.

#### 8.0.4 Why the VNet is created at the Platform LZ layer (not at the project layer) in `platform` mode

§8.0.3 explains _why `platform` mode exists at all_. This subsection answers the orthogonal question: **once we have decided to operate in `platform` mode, why is the VNet itself owned by the Platform LZ (organization) layer, and not created per-project by the project module?** The short answer: in `platform` mode, the VNet is an _organization-shared substrate_, not a project artifact, and several core platform components only function correctly when they all live in (or directly attach to) that single shared VNet. Pushing VNet creation to the project layer would either break those components or force every project to reinvent the platform team's networking work — at which point the project is effectively running BYO mode without an enterprise to back it.

The design contrast is summarized below. "Project-owned VNet" here means a VNet that the project module itself creates and owns, distinct both from the shared Platform LZ VNet and from a user-supplied enterprise spoke (which is the BYO case).

| Concern                                                     | Platform-layer VNet (current target)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Hypothetical project-owned VNet (in non-BYO mode)                                                                                                                                                                                                                                                                                                                                                          |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Bootstrap Storage Account / Key Vault Private Endpoints** | The bootstrap SA (Layer 1 tfstate) and Key Vault are **single, organization-scoped resources** (Table A in §1), used by the **platform admin's own apply path** — `_bootstrap`, `devops/lz`, and `project_github` provisioning — **not** by the project team's runner. Their Private Endpoints are deployed once into the Platform LZ VNet at LZ apply time so the platform admin (running locally, from a jumphost, or from a central pipeline that lives in the Platform LZ VNet) can reach them privately. Co-locating those PEs with the runner subnet is a side-effect of having one shared platform VNet; it is not what makes `platform` mode preferred. | A separate per-project VNet would still need to reach those PEs **from the platform admin's apply context**, which means either (a) duplicating the SA/KV PEs into every project VNet (impossible — SA/KV are org singletons) or (b) peering the platform admin's apply network to every project VNet. Either way, the project VNet design fragments organization-scoped admin networking with no benefit. |
| **Shared ACR + private DNS zones (`privatelink.*`)**        | The runner image is pulled from the org-shared ACR (Tab. B in §1) and resolved via the org-singleton `privatelink.azurecr.io` zone (plus other `privatelink.*` zones for any project-scoped Layer 2 SA / project KV records published in the same zones). The Platform LZ owns the canonical zones and links them to the LZ VNet once. Records published by the ACR PE — and by per-project SA / KV PEs that also land in `privatelink.blob.core.windows.net` / `privatelink.vaultcore.azure.net` — resolve correctly from any project subnet inside the same VNet without per-project DNS link setup.                                                          | Each project VNet would need either (a) its own copy of the same `privatelink` zones (which causes split-horizon collisions and duplicates A-records), or (b) explicit `privateDnsZoneVirtualNetworkLink` per (zone × project VNet) — i.e. exactly §8.0.1 rule #1, paid by every project for nothing in return.                                                                                            |
| **NAT egress / firewall allowlists**                        | One NAT Gateway with a **small, stable set of egress public IPs** is shared by all project subnets. SaaS providers, GitHub, registry mirrors, etc. can be allowlisted **once** at the org level.                                                                                                                                                                                                                                                                                                                                                                                                                                                                | N project NAT Gateways → N egress IP sets → O(N) allowlist entries to maintain externally. Cost and operational burden scale linearly with project count, with no functional benefit.                                                                                                                                                                                                                      |
| **Address-space governance**                                | Subnet slices are carved from a **central /16-class address plan** owned by the platform team; non-overlap (§8.0.1 rule #5) is guaranteed by construction.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Each project module would need its own (overlapping or random) address space, or a separate IPAM. This re-creates the exact problem BYO mode was designed for, but without an enterprise IPAM to solve it.                                                                                                                                                                                                 |
| **ACA subnet delegation footprint**                         | ACA Environment infrastructure subnet requires a **/23 minimum**. Allocating one /23 per project from a shared platform /16 is efficient and predictable.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Each project-owned VNet would need its own /23 plus padding for additional subnets — multiplying address-space consumption and making future peering harder.                                                                                                                                                                                                                                               |
| **Cost and lifecycle of VNet objects**                      | One VNet, one NAT, one set of NSGs/UDRs, one DNS-link fan-out (zone → VNet) — created once at LZ provisioning, amortized across all projects.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | N VNets, N NATs, N×K NSG/UDR sets, N×Z DNS zone links. Each project apply pays minutes of provisioning latency for VNet/NAT/peering it does not strategically own.                                                                                                                                                                                                                                         |
| **Operational ownership**                                   | Network is owned by the **platform team** (matches §1's "Organization" responsibility row). Project teams do not need network expertise to onboard.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Network would silently leak into the **project team's** ownership in the default mode — contradicting the org/project responsibility split that the entire spec is built around (§1, §2, §6).                                                                                                                                                                                                              |
| **Symmetry with BYO**                                       | Project module always **consumes** subnet IDs (`aca_subnet_id`, `pe_subnet_id`, etc.) regardless of mode. The only thing that differs between `platform` and `byo` is **who supplies those IDs**: the LZ outputs vs. the user input. The project-module contract is identical.                                                                                                                                                                                                                                                                                                                                                                                  | A third "project-creates-its-own-VNet" mode would introduce a third contract shape (project both creates _and_ consumes its own VNet), increasing module surface area and making the `platform`/`byo` switch in §8.2 a three-way decision instead of two.                                                                                                                                                  |
| **Already-equivalent-to-BYO if you peer**                   | n/a                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | If the project VNet still must reach the platform SA/KV PEs, the project VNet must peer to the platform VNet and link to all platform DNS zones. That is **exactly BYO mode**, just without an enterprise spoke. So this hypothetical mode is dominated by either (`platform`) or (`byo`); it is never the best choice.                                                                                    |

**Two-line summary.** Platform-layer ownership of the VNet in `platform` mode follows directly from the fact that the **Platform LZ already owns the shared ACR, the `privatelink.*` DNS zone singletons, the shared NAT, and the shared address-plan governance** (the bootstrap SA/KV PEs ride along as a side-effect of having one platform VNet, but they serve the platform admin's apply path — not the project runner — see §8.0.1 rule #1). Co-locating runner subnets in that same VNet is the cheapest, simplest, and most correct way to give projects access to those organization-shared resources without re-implementing the seven §8.0.1 consistency rules in every project. When a project _has_ a real reason to live somewhere else (enterprise spoke, central firewall, on-prem peering), it switches to `byo` mode and accepts the cost of re-establishing those rules explicitly. There is no useful third option in between.

#### 8.0.5 Detailed network diagrams (platform mode and BYO mode)

The high-level three-tier diagram in §8.0 intentionally hides per-subnet, DNS-link, peering, and identity binding details so the model stays readable. The diagrams below add those details for the two operational modes so that the runtime network path — from the runner container up to the org-shared ACR and the project's own Layer 2 tfstate Storage Account / project Key Vault, and out to the target subscription's Application VNet — is unambiguous. (The bootstrap SA / Key Vault PEs are shown for completeness but are **not** on the runner data-path: they serve the platform admin's apply context — `_bootstrap`, `devops/lz`, and `project_github` provisioning — see §8.0.1 rule #1.) The diagrams also show which arrows are created by `devops/lz`, which by the project module, and which are out of scope of this LZ (enterprise hub-and-spoke).

##### 8.0.5.1 `network_mode = "platform"` — runner co-located in the shared Platform LZ VNet

In `platform` mode the project's CI/CD compute lands in a **project-dedicated subnet slice** of the shared Platform LZ VNet. The bootstrap SA/KV/ACR Private Endpoints, the `privatelink.*` DNS zones, and the NAT egress are all in the same VNet, so the runner reaches them with **no peering and no per-project DNS link** — the seven §8.0.1 consistency rules are satisfied by construction (§8.0.4).

```text
Platform LZ subscription                                              Target subscription(s) — one per environment
┌────────────────────────────────────────────────────────────────┐    ┌───────────────────────────────────────────┐
│ Platform LZ VNet  10.10.0.0/16   (created by devops/lz)        │    │ Application / Workload VNet (project IaC) │
│                                                                │    │   10.50.0.0/16  (NOT created by this LZ)  │
│  ┌──────────────────────────┐  ┌──────────────────────────┐    │    │                                           │
│  │ pe-bootstrap   10.10.1/24│  │ devbox        10.10.4/24 │    │    │   ┌────────────────────────────────────┐  │
│  │  PE → Bootstrap SA       │  │  Dev Box NIC pool        │    │    │   │ app-tier   10.50.1.0/24            │  │
│  │  PE → Bootstrap KV       │  │  (DevBox network conn.)  │    │    │   │  App Service / AKS / Functions /…  │  │
│  │  PE → ACR (runner image) │  └──────────────────────────┘    │    │   │  + their private endpoints         │  │
│  └────────┬─────────────────┘                                  │    │   └────────────┬───────────────────────┘  │
│           │                                                    │    │                │                          │
│  ┌────────┴───────────────────────────────────────────────┐    │    │   ┌────────────┴───────────────────────┐  │
│  │ project-A runner subnet  10.10.16.0/23                 │    │    │   │ pe-app  10.50.2.0/27               │  │
│  │   delegated: Microsoft.App/environments                │    │    │   │  PE → app SQL / KV / Storage …     │  │
│  │   ┌──────────────────────────────────────────────┐     │    │    │   └────────────────────────────────────┘  │
│  │   │ ACA Environment  (created by project module) │     │    │    │                                           │
│  │   │   ACA Job: tf-runner                         │     │    │    └────────────────────┬──────────────────────┘
│  │   │     image: ACR (private pull, container-     │     │    │                         │
│  │   │            run UAMI from Platform LZ)        │     │    │                         │ peering provided by
│  │   │     env-job UAMIs (7 per project): plan/apply│     │    │                         │ enterprise hub-and-
│  │   └──────────────────────────────────────────────┘     │◄───┼─────────────────────────┘ spoke (NOT this LZ)
│  └────────────────────────────────────────────────────────┘    │                           § 8.0.2
│                                                                │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ pe-project-A-tfstate  10.10.17.0/27  (project module)  │    │
│  │   PE → Layer 2 project Storage Account (Tab. C in §1)  │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                │
│  ┌──────────┐                                                  │
│  │ NAT GW   │ ← egress (single shared public IP set,           │
│  │ + PIP    │   allowlisted once at the org level — §8.0.4)    │
│  └────┬─────┘                                                  │
│       │ egress to GitHub / Azure DevOps / public registries    │
└───────┼────────────────────────────────────────────────────────┘
        ▼
   Internet (egress only)

Private DNS zones in the Platform LZ subscription (one VNet link each, by devops/lz):
  privatelink.blob.core.windows.net           ← bootstrap SA (admin path) + project Layer 2 SA records
  privatelink.vaultcore.azure.net             ← bootstrap KV (admin path) + project KV records
  privatelink.azurecr.io                      ← ACR records (runner image pull path)
  privatelink.<region>.azurecontainerapps.io  ← ACA Environment records
                              │
                              └── linked once to Platform LZ VNet (covers ALL project subnets)
                                  → runner resolves ACR + project Layer 2 SA + project KV
                                    via private IP (bootstrap SA/KV are not on the runner path —
                                    §8.0.1 rule #1)
                                  → no per-project DNS link, no peering, no FW change
```

Key properties of `platform` mode (cross-references in parentheses):

- **Single shared VNet, project-dedicated subnets.** Platform LZ owns the address plan and carves a `/23` ACA subnet + `/27` PE subnet per project (§8.0.4 row "Address-space governance" / "ACA subnet delegation footprint"). The project module never creates the VNet; it only attaches resources to subnets exposed by `devops_network`.
- **Runner data-path PE reachability is automatic.** ACR (runner image), the project's Layer 2 tfstate Storage Account, and the project's own Key Vault PEs all live in the same VNet as the runner subnet (ACR in the org-shared PE subnet; Layer 2 SA / project KV in a project-dedicated PE subnet), so no peering is needed for the runner to reach them on private IPs (§8.0.4 row "Shared ACR + private DNS zones", §8.0.1 rules #2 and #3).
- **Bootstrap SA / KV PEs are not on the runner path.** They live in the same VNet only because the platform admin's apply path (`_bootstrap`, `devops/lz`, `project_github` provisioning) needs them. The project team's runner never reads or writes them (§8.0.1 rule #1; §3.2 two-layer state model).
- **Private DNS resolution is automatic.** Each `privatelink.*` zone is linked **once** to the Platform LZ VNet by `devops/lz`. The runner subnet inherits this link automatically (§8.0.1 rule #1; §8.0.4 row "Shared ACR + private DNS zones").
- **NAT egress is shared.** A single NAT Gateway with a small set of static PIPs serves every project subnet — SaaS allowlists (GitHub, package registries, Microsoft Entra) need to be maintained **once** at the org level (§8.0.4 row "NAT egress / firewall allowlists").
- **ACA Environment is project-scoped.** Per §5.4.1, the ACA Environment is created by the project module inside the project's runner subnet. Platform LZ provides only the shared dependencies (ACR, Log Analytics, container-run UAMI).
- **Connectivity to Application/Workload VNets (target subscription).** The runner reaches resources in the target subscription's Application VNet via the enterprise hub-and-spoke peering — **not created by this LZ** (§8.0.2). In a greenfield setup with no hub-and-spoke, the project team is expected to peer the Platform LZ VNet ↔ each Application VNet directly, or to reach those resources over service endpoints / public endpoints if private-link is not required.

##### 8.0.5.2 `network_mode = "byo"` — runner deployed into a user-supplied enterprise spoke

In `byo` mode the runner subnet lives in a **pre-provisioned enterprise spoke VNet** that the LZ neither creates nor owns. The seven §8.0.1 consistency rules now have to be made explicit: peering between the BYO VNet and the Platform LZ VNet (or transit through the enterprise hub) is required to reach the **org-shared ACR PE** so the runner can pull its container image, and the BYO VNet must be linked to the Platform LZ's `privatelink.*` DNS zones so the corresponding hostnames resolve to the platform PE IPs. The project's **Layer 2 tfstate Storage Account** and the project's **own Key Vault** for project secrets are deployed by the project module **inside the BYO VNet** (in the BYO PE subnet) — they are project-owned, not platform-owned, and therefore do not require platform-VNet peering. The bootstrap SA / Key Vault PEs in the Platform LZ VNet are **not** on the runner data-path (§8.0.1 rule #1).

```text
Platform LZ subscription (devops/lz, unchanged from platform mode)        Target subscription(s)
┌────────────────────────────────────────────────────────────────┐         ┌───────────────────────────────────┐
│ Platform LZ VNet  10.10.0.0/16                                 │         │ Application / Workload VNet       │
│                                                                │         │   10.50.0.0/16  (project IaC)     │
│  ┌──────────────────────────┐                                  │         │                                   │
│  │ pe-bootstrap   10.10.1/24│                                  │         │   App Service / AKS / SQL / …     │
│  │  PE → Bootstrap SA       │◄────────────┐                    │         │   + their private endpoints       │
│  │  PE → Bootstrap KV       │             │ private IPs        │         │                                   │
│  │  PE → ACR (runner image) │             │ resolved via       │         └────────────┬──────────────────────┘
│  └──────────────────────────┘             │ privatelink.*      │                      │
│                                           │ DNS zones          │  enterprise hub-and-spoke peering
│  pe-platform Layer-2 SA records           │                    │  (NOT this LZ — § 8.0.2)
│  exist in privatelink.blob zone, but      │                    │                      │
│  the project Layer-2 SA / PE itself is    │                    │                      ▼
│  in the BYO VNet (see below)              │                    │         (BYO spoke, see right)
│                                           │                    │
│  Private DNS zones (privatelink.*)        │                    │
│   ─ linked to Platform LZ VNet (always)   │                    │
│   ─ linked to BYO VNet (rule #1, by      ─┤                    │
│     project module via DNS zone IDs       │                    │
│     from devops_network output)           │                    │
└───────────────────────────────────────────┼────────────────────┘
                                            │
                                            │  VNet ↔ VNet peering
                                            │  (enterprise networking team —
                                            │   rule #2, NOT this LZ)
                                            │
                                            ▼
              ┌────────────────────────────────────────────────────────────────┐
              │ BYO VNet (enterprise spoke)  10.20.0.0/16                       │
              │   pre-existing — owned by enterprise networking team            │
              │   peered to: hub VNet (FW/DNS proxy), Platform LZ VNet,         │
              │              target Application VNet(s)                         │
              │                                                                 │
              │  ┌────────────────────────────────────────────────────────┐     │
              │  │ aca-runner subnet  10.20.16.0/23   (BYO, user input)   │     │
              │  │   MUST be delegated Microsoft.App/environments         │     │
              │  │   (rule #4 — checked by Terraform precondition § 8.4)  │     │
              │  │   ┌──────────────────────────────────────────────┐     │     │
              │  │   │ ACA Environment  (created by project module) │     │     │
              │  │   │   ACA Job: tf-runner                         │     │     │
              │  │   │     image: ACR pull (via peering+DNS rule #3)│     │     │
              │  │   │     env-job UAMIs (7 per project): plan/apply│     │     │
              │  │   └──────────────────────────────────────────────┘     │     │
              │  └────────────────────────────────────────────────────────┘     │
              │                                                                 │
              │  ┌────────────────────────────────────────────────────────┐     │
              │  │ pe subnet  10.20.17.0/27   (BYO, user input)           │     │
              │  │   PE → Layer 2 project Storage Account (project tfstate)│    │
              │  └────────────────────────────────────────────────────────┘     │
              │                                                                 │
              │  ┌────────────────────────────────────────────────────────┐     │
              │  │ devbox subnet  10.20.18.0/26   (optional, BYO)         │     │
              │  └────────────────────────────────────────────────────────┘     │
              │                                                                 │
              │  Egress: enterprise NAT or Azure Firewall in the hub            │
              │          (no per-project NAT GW; SaaS allowlists managed        │
              │           centrally — rules #6, also see § 8.0.2)               │
              └─────────────────────────────────────────────────────────────────┘

Address-space rules (§8.0.1 rule #5): BYO VNet CIDR must NOT overlap with
  - Platform LZ VNet (10.10.0.0/16 in this example) — required for peering
  - Application / Workload VNet(s) — required for hub-and-spoke peering
  Enforced by enterprise IPAM, not by this LZ.

Private DNS resolution path (§8.0.1 rule #1) for the runner in the BYO VNet:
  runner → DNS query for "<acr-name>.azurecr.io"   (runner image pull, rule #2)
        → resolves via privatelink.azurecr.io
        → DNS zone is linked to BYO VNet by project module
          (azurerm_private_dns_zone_virtual_network_link, one per zone,
           using devops_network.private_dns_zone_ids from the LZ output)
        → A-record points to ACR PE IP in Platform LZ VNet
        → reachable because BYO ↔ Platform LZ peering exists (rule #2)

  runner → DNS query for "<project-sa>.blob.core.windows.net"   (Layer 2 tfstate)
        → resolves via privatelink.blob.core.windows.net
        → A-record points to PE IP in the BYO PE subnet (10.20.17.x)
        → reachable directly within the BYO VNet — project SA / project KV
          are project-owned (rule #3); no platform peering needed for these.

  Note: bootstrap SA and bootstrap KV are NOT on the runner data-path
        (they are used only by the platform admin's apply context for
         _bootstrap / devops/lz / project_github provisioning — §8.0.1 rule #1).
```

What this LZ owns vs. what the enterprise owns in `byo` mode (mapping back to §8.0.1):

| Concern                                                                                                                                                                                          | Owned by `devops/lz` (Platform LZ)                                                                                                     | Owned by project module (`project_github` / `project_azuredevops`)                                                                                                    | Owned by enterprise networking team (NOT this LZ)                                                           |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Platform LZ VNet, NAT, ACR Private Endpoint, `privatelink.*` DNS zones (and the bootstrap SA/KV PEs for the platform admin path — _not_ on the runner data-path, §8.0.1 rule #1)                 | ✅ Created and owned (always — same as `platform` mode).                                                                               | —                                                                                                                                                                     | —                                                                                                           |
| BYO VNet itself (address space, NSGs, UDRs)                                                                                                                                                      | —                                                                                                                                      | —                                                                                                                                                                     | ✅ Pre-provisioned spoke; supplied via `byo_vnet.{vnet_id, aca_subnet_id, pe_subnet_id, devbox_subnet_id}`. |
| Subnet delegation `Microsoft.App/environments` on the BYO ACA subnet (rule #4)                                                                                                                   | —                                                                                                                                      | ⚠️ **Validated** by Terraform precondition; **enforced** during BYO subnet provisioning by enterprise (the project module fails fast at plan-time if missing).        | ✅ Must be set on the spoke subnet at the time it is provisioned.                                           |
| Linking BYO VNet to Platform LZ `privatelink.*` zones (rule #1)                                                                                                                                  | Exposes `devops_network.private_dns_zone_ids`.                                                                                         | ✅ Creates `azurerm_private_dns_zone_virtual_network_link` per zone × BYO VNet, using the IDs from the LZ output (when `byo_vnet.link_to_platform_private_dns`).      | —                                                                                                           |
| BYO VNet ↔ Platform LZ VNet peering (rule #2 — runner reaches the org-shared ACR PE)                                                                                                            | —                                                                                                                                      | —                                                                                                                                                                     | ✅ Done via hub-and-spoke or direct peering; the LZ only validates connectivity at apply time.              |
| ACA Environment + runner ACA Job + 7 UAMIs (env × job)                                                                                                                                           | Provides shared deps: ACR + container image build (Tab. B in §1), Log Analytics (runner logs), container-run UAMI (`acr_pull` on ACR). | ✅ Creates ACA Environment in the BYO ACA subnet, ACA Job, OIDC federated credentials, conditional subscription RBAC. See §5.4.1.                                     | —                                                                                                           |
| Layer 2 project tfstate Storage Account + project Key Vault + their PEs in the BYO PE subnet (Tab. C in §1, rule #3 — both project-owned, in the BYO VNet, no platform peering needed for these) | —                                                                                                                                      | ✅ Creates Layer 2 SA (LRS by default, selectable replication) and project KV inside a project-scoped RG in the platform subscription, with PEs in the BYO PE subnet. | —                                                                                                           |
| Connectivity from runner VNet (BYO) to target subscription Application/Workload VNets                                                                                                            | —                                                                                                                                      | —                                                                                                                                                                     | ✅ Standard hub-and-spoke peering or VPN/ER through the enterprise hub (see §8.0.2).                        |

When peering or DNS links from §8.0.1 are missing, the runner fails with deterministic, observable errors (DNS NXDOMAIN for `privatelink.azurecr.io`, TCP timeout to the ACR PE IP, ACR pull failure on the ACA Job init container, or — for the project-owned PEs — DNS NXDOMAIN / TCP timeouts within the BYO VNet itself if the project SA / KV PE subnet is not correctly configured). The project module surfaces these as Terraform preconditions where possible (rule #4 subnet delegation) and as runtime failures otherwise — there is no silent fallback to public endpoints.

---

### 8.1 Problem

Today the Landing Zone always creates a fresh VNet with all required subnets. Enterprise customers often:

- Have a **hub-and-spoke** topology managed by a central networking team.
- Need DevOps resources to land in a **pre-provisioned spoke VNet** with corporate firewall rules, DNS forwarding, and peering already configured.
- Cannot use arbitrary address spaces.

### 8.2 Design

Add a `network_mode` variable that selects between two intentional, complementary modes (rationale in §8.0.3):

| Mode       | Description                                                                                                                                          | Who creates VNet?          | Who provides subnet IDs?        |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- | ------------------------------- |
| `platform` | **Default low-friction onboarding mode.** The LZ creates and manages a shared platform VNet; each project consumes a project-dedicated subnet slice. | `devops/lz` module         | `devops/lz` outputs             |
| `byo`      | **Enterprise integration mode.** The user supplies an existing spoke VNet and subnet IDs; the project module satisfies the §8.0.1 consistency rules. | External (networking team) | User input at **project level** |

### 8.3 Landing Zone changes (`devops/lz`)

The LZ continues to create its platform VNet when `enable_private_network = true`; BYO is a **project-level** decision and does not require the LZ to delegate VNet creation. However, supporting BYO end-to-end does require the LZ output changes described in **§5.4.1** (remove `container_app_environment_id`, keep `aca_subnet_id` on `devops_network`), because the project-level ACA Environment refactor is a prerequisite for runner compute to land in the BYO VNet. In addition, the LZ already exports its private DNS zone IDs so BYO projects can link their VNet to the same DNS zones (see §8.0.1 rule #1):

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

### 8.4 Project-level changes (`devops/project_github`)

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

These checks should be implemented as **enforceable Terraform validations/preconditions** (not documentation-only rules), by reading the BYO subnet configuration and asserting required delegations:

```hcl
data "azurerm_subnet" "byo_aca" {
  count = var.network_mode == "byo" && var.use_self_hosted_runners && var.self_hosted_runners_type == "aca" ? 1 : 0
  id    = var.byo_vnet.container_app_subnet_id
}

resource "terraform_data" "validate_byo_subnets" {
  lifecycle {
    precondition {
      condition = (
        var.network_mode != "byo" ||
        !var.use_self_hosted_runners ||
        var.self_hosted_runners_type != "aca" ||
        contains(
          flatten([for d in data.azurerm_subnet.byo_aca[0].delegation : [for s in d.service_delegation : s.name]]),
          "Microsoft.App/environments"
        )
      )
      error_message = "BYO ACA subnet must include Microsoft.App/environments delegation."
    }
  }
}
```

Apply the same pattern for ACI (`Microsoft.ContainerInstance/containerGroups`) and DevBox subnet presence checks.

```hcl
# New file: network.tf (in project_github)

locals {
  # Resolve subnet IDs based on network mode
  effective_private_endpoint_subnet_id = (
    var.network_mode == "byo"
    ? var.byo_vnet.private_endpoint_subnet_id
    # Note: private_endpoint_subnet_id is a new field added to the LZ devops_network output
    : try(local._devops_outputs.devops_network.private_endpoint_subnet_id, null)
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

### 8.5 Sample `terraform.tfvars` — BYO VNet project

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

### 8.6 Architecture Diagram — BYO VNet Flow

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

### 8.7 Repo-level BYO VNet — analysis

**Question:** Could different repositories within the same project use different BYO VNets?

**Answer:** Repo-level BYO VNet is **not practical** in the current architecture. The network mode should remain a **project-level** decision.

| Concern                                     | Why repo-level BYO VNet is impractical                                                                                                                                                                    |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Runner infrastructure is project-scoped** | Self-hosted runners (ACA jobs, ACI containers) are created per project and shared across all repos in the project. A runner cannot exist in two different VNets simultaneously.                           |
| **Private endpoints are shared**            | The private endpoint to the tfstate Storage Account is project-scoped. It lives in one subnet and is used by all repos' workflows.                                                                        |
| **State management**                        | All repos in a project share the same Terraform backend (storage account + container). Splitting VNets per repo would require separate state backends, which defeats the purpose of the project grouping. |
| **Complexity vs. value**                    | Per-repo VNets would require a `for_each` over repos with different network configs, separate ACA environments per repo, and per-repo DNS zone links — significant complexity for a rare use case.        |

**If repos truly need different networks, they likely belong in different projects.** The project boundary is the right level for network isolation. A team that needs repo A in VNet X and repo B in VNet Y should define two separate projects, each with its own `network_mode` and `byo_vnet` configuration.

> **Note:** This does not limit where the _application_ deploys — application-level networking (where the app runs) is handled by the application's own Terraform/IaC, not by the DevOps Landing Zone. The BYO VNet here governs only the _CI/CD infrastructure_ (runners, private endpoints, DevBox).

---

## Related Decisions

- [ADR-001: Platform Landing Zone Resource Scoping](./ADR-001-platform-lz-resource-scoping.md)
- [ADR-002: Runner Compute Model](./ADR-002-runner-compute-model.md)
