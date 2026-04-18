[English](./ADR-002-runner-compute-model.md) | [日本語](./ADR-002-runner-compute-model.ja.md)

# ADR-002: Runner Compute Model: Self-hosted (ACA) vs. GitHub-hosted with Azure Private Networking

> **Status:** Accepted
> **Context:** [Target Architecture Spec](../Target-Architecture-Spec.md)

## Summary

Self-hosted runners on Azure Container Apps (ACA) are chosen over GitHub-hosted runners with Azure private networking (APES) for five architectural reasons: dual VCS platform support, no plan lock-in, full image control, static egress IPs, and region flexibility.

---

> **Context.** Two architecturally distinct approaches exist for running CI/CD jobs that need private-network access to Azure resources deployed in a closed VNet. This section compares them and explains why this Landing Zone uses self-hosted runners on Azure Container Apps (ACA).

#### 5.5.1 Option A — Self-hosted runner on a container platform (ACA / ACI)

The project module creates an **ACA Environment** in the project's DevOps VNet (§5.4.1) and registers ephemeral **ACA Jobs** as self-hosted runners. The Platform LZ provides the shared runner container image (built and stored in the org-level ACR), the Log Analytics sink, and the container-run UAMI.

| Property                           | Detail                                                                                                                                                                  |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **VCS platform support**           | GitHub Actions **and** Azure DevOps Pipelines (via the same ACA compute, different agent/runner registration)                                                           |
| **GitHub plan requirement**        | Any plan (Free, Team, Enterprise) — self-hosted runners are available on all plans                                                                                      |
| **Azure region availability**      | Any Azure region where ACA is available                                                                                                                                 |
| **Runner image control**           | Full — custom Dockerfile, pre-installed tools, caching layers, pinned OS versions; images are built by org-level ACR tasks                                              |
| **Network integration**            | ACA Environment is bound to the project's VNet at creation time (subnet delegation: `Microsoft.App/environments`); runner gets a private IP inside the project's subnet |
| **Static / predictable egress IP** | Yes — the Platform LZ NAT Gateway (platform mode) or the enterprise spoke's NAT/firewall (BYO mode) provides stable egress IPs for SaaS allowlists                      |
| **Compute cost model**             | Azure consumption-based (ACA vCPU-seconds + memory-seconds); no per-minute GitHub runner charges                                                                        |
| **Management overhead**            | Platform team maintains runner images (Dockerfile, OS patches, tool updates), ACA Environment scaling, and runner registration tokens                                   |

#### 5.5.2 Option B — GitHub-hosted runner with Azure private networking (APES / VNet injection)

GitHub's **Azure Private Networking** feature (sometimes called APES — Actions Private Endpoint Service) lets you use GitHub-managed runner VMs whose Network Interface Card (NIC) is injected into a customer-owned Azure subnet at job start time. The runner gets a private IP in the customer VNet and is destroyed after the job completes.

| Property                           | Detail                                                                                                                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **VCS platform support**           | **GitHub Actions only** — Azure DevOps has no equivalent VNet-injection feature for Microsoft-hosted agents                                                               |
| **GitHub plan requirement**        | **Team or Enterprise Cloud** — Free plan is not supported                                                                                                                 |
| **Azure region availability**      | Limited — only specific Azure regions are enabled; not all regions are supported                                                                                          |
| **Runner image control**           | Limited — GitHub-managed standard images (Ubuntu, Windows); no custom Dockerfile or pre-installed tool control                                                            |
| **Network integration**            | Subnet delegation: `GitHub.Network/networkSettings`; GitHub injects a runner NIC at job start; NIC is removed after the job                                               |
| **Static / predictable egress IP** | **No** — runners receive dynamic IPs from the subnet; no NAT Gateway binding (static IP is not supported by APES)                                                         |
| **Compute cost model**             | GitHub-hosted runner minutes pricing (per-minute charges on top of the Enterprise/Team license) + standard Azure networking costs                                         |
| **Management overhead**            | Near-zero for the runner itself (GitHub manages the VM, OS, patches); customer manages only the Azure VNet/subnet and the `GitHub.Network` resource provider registration |

#### 5.5.3 Comparison and architectural decision

```text
┌──────────────────────────────┬─────────────────────────────────┬──────────────────────────────────────────┐
│ Criterion                    │ Self-hosted (ACA)               │ GitHub-hosted + Azure private networking │
├──────────────────────────────┼─────────────────────────────────┼──────────────────────────────────────────┤
│ GitHub + ADO parity          │ ✅ Both (same ACA compute)      │ ❌ GitHub only — no ADO equivalent       │
│ GitHub plan flexibility      │ ✅ Any plan                     │ ⚠️ Team or Enterprise Cloud only         │
│ Azure region availability    │ ✅ Any ACA-supported region     │ ⚠️ Limited regions                       │
│ Runner image customization   │ ✅ Full (custom Dockerfile)     │ ❌ GitHub-standard images only            │
│ Static egress IP             │ ✅ NAT Gateway                  │ ❌ Dynamic IPs only                       │
│ Operational overhead         │ ⚠️ Image builds, patching,     │ ✅ Near-zero (GitHub-managed)             │
│                              │    scaling, token rotation      │                                          │
│ Cost model                   │ Azure consumption (ACA)         │ GitHub minutes + Azure networking        │
│ Subnet delegation            │ Microsoft.App/environments      │ GitHub.Network/networkSettings           │
│ Runner lifecycle              │ Ephemeral ACA Job per run      │ Ephemeral VM + NIC per job               │
└──────────────────────────────┴─────────────────────────────────┴──────────────────────────────────────────┘
```

**Why this LZ uses self-hosted runners on ACA (Option A):**

1. **Dual VCS platform support (Goal 6 — GitHub / Azure DevOps parity).** This LZ's core design goal is to provide a unified abstraction over GitHub and Azure DevOps (§7). Azure DevOps has no VNet-injection feature for Microsoft-hosted agents — self-hosted agents are the **only** option for private-network deployments in ADO Pipelines. Choosing Option B for GitHub would force a fundamentally different runner architecture for ADO projects, breaking the unified project module contract.

2. **No GitHub plan lock-in.** Self-hosted runners work with _any_ GitHub plan, including Free. APES requires Team or Enterprise Cloud. The Landing Zone should not impose a GitHub licensing constraint on every consumer.

3. **Full runner image control.** Self-hosted runners use a custom Dockerfile maintained by the platform team (built and stored in the org-level ACR). This enables pre-installed Terraform versions, Azure CLI, custom tools, security hardening, and deterministic caching — critical for enterprise IaC workflows. GitHub-hosted images are managed by GitHub and cannot be customized.

4. **Static egress IPs.** The Platform LZ NAT Gateway provides predictable egress IPs that can be allowlisted by SaaS providers (GitHub API, Terraform Registry, package registries, Microsoft Entra). APES runners receive dynamic IPs and do not support NAT Gateway binding.

5. **Azure region flexibility.** ACA is available in all major Azure regions. APES VNet injection is limited to specific regions, which may not match the customer's Azure footprint.

**When Option B (GitHub-hosted + APES) may be appropriate:**

- The organization uses **only GitHub** (no Azure DevOps), is on **Team or Enterprise Cloud**, operates in a **supported Azure region**, does not need custom runner images or static egress IPs, and values **near-zero runner management overhead** over customization flexibility. In this scenario, the operational simplicity of GitHub-managed runners may outweigh the customization benefits of self-hosted ACA.

> **Note for Azure DevOps.** Microsoft-hosted agents do not support VNet injection as of 2025. For Azure DevOps Pipelines with private-network requirements, **self-hosted agents** (on VMs, container instances, or ACA) are the only option. This LZ's ACA-based runner model works identically for ADO self-hosted agents, which is the primary reason for the architectural choice.

---

## Related Decisions

- [ADR-001: Platform Landing Zone Resource Scoping](./ADR-001-platform-lz-resource-scoping.md)
- [ADR-005: VNet Architecture](./ADR-005-vnet-architecture.md)
