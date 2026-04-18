[English](./ADR-008-naming-collision-resistance.md) | [日本語](./ADR-008-naming-collision-resistance.ja.md)

# ADR-008: Naming, State Key, and Collision Resistance Conventions

> **Status:** Accepted
> **Context:** [Target Architecture Spec](../Target-Architecture-Spec.md)

## Summary

Resource naming uses a portfolio-safe pattern (`<type>-<org_prefix>-<project>-<region>-<rand>`), tfstate keys follow `projects/<project_name>.terraform.tfstate`, and UAMI names use a mixed human-readable + hash approach (`uami-<project>-<repo>-<hash>`) to stay within Azure's 128-character limit.

---

### 11.1 Current naming

Resources use a random 4-character suffix (`rand_id`) to avoid collisions. The naming pattern is:

```
<resource_type>-<project_name>-devops-<region_short>-<rand_id>
```

### 11.2 Improvements

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

4. **State key stability guardrail**: Use an immutable `project_id` (slug/UUID-like token) for backend keys, and keep `project_name` human-readable/display-only:

   ```text
   projects/<project_id>.terraform.tfstate
   ```

   - `project_id` is set once at project creation and must not change.
   - If display name changes, no backend key change is required.
   - If a legacy project must change backend key format, perform explicit `terraform init -migrate-state` as a controlled operation.

### 11.3 UAMI naming convention

Per-repo UAMI names use a **mixed** approach that balances readability and Azure naming limits (128 chars max):

```
uami-<project>-<repo>-<hash>
```

| Segment     | Source                                               | Purpose                                                                    |
| ----------- | ---------------------------------------------------- | -------------------------------------------------------------------------- |
| `uami-`     | Fixed prefix                                         | Resource type identifier                                                   |
| `<project>` | `var.project_name`                                   | Human-readable project identification                                      |
| `<repo>`    | Repository name from `repositories` list             | Human-readable repo identification                                         |
| `<hash>`    | `substr(sha256("<env>-<job_type>-<rand_id>"), 0, 8)` | Collision-resistant suffix encoding environment, job type, and random seed |

**Key design decisions:**

- **Project and repo are human-readable**: When browsing UAMIs in the Azure portal or CLI, operators can immediately identify which project and repository a UAMI belongs to.
- **Env and job type are hashed**: The environment (dev/staging/prod) and job type (plan/apply) don't need to be visible in the name — they are encoded in the hash. Operators can look up the mapping via Terraform state or resource tags.
- **Hash provides collision resistance**: The 8-character hex hash (from SHA-256) gives ~4 billion combinations per project-repo pair, which is more than sufficient.
- **Tags carry full metadata**: Each UAMI should be tagged with `environment`, `job_type`, `project`, and `repo` for full traceability independent of the name.

**Example names:**

```
uami-contoso-ecom-infra-a3f7b2c1        # project=contoso-ecom, repo=infra, env=prod/apply
uami-contoso-ecom-infra-e9d4c8f0        # project=contoso-ecom, repo=infra, env=dev/plan
uami-contoso-ecom-api-7b2e1a9d          # project=contoso-ecom, repo=api, env=prod/apply
```

**When `shared_identities = true`** (backward-compatible mode), the `<repo>` segment is omitted:

```
uami-<project>-<hash>
```

**Terraform implementation sketch:**

```hcl
locals {
  uami_names = {
    for key in local.identity_keys : key => (
      var.shared_identities
      ? "uami-${var.project_name}-${substr(sha256("${key}-${local.rand_id}"), 0, 8)}"
      : "uami-${var.project_name}-${local.repo_name_by_key[key]}-${substr(sha256("${key}-${local.rand_id}"), 0, 8)}"
    )
  }
}
```

---

## Related Decisions

- [ADR-003: Project Definition and Multi-Repository Model](./ADR-003-project-multi-repo-model.md)
