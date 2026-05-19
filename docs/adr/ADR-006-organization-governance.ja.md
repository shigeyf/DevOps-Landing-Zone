[English](./ADR-006-organization-governance.md) | [日本語](./ADR-006-organization-governance.ja.md)

# ADR-006: 組織レベルのガバナンス（GitHub & Azure DevOps）

> **ステータス:** 承認済み
> **コンテキスト:** [ターゲットアーキテクチャ仕様](../Target-Architecture-Spec.ja.md)

## 概要

プラットフォーム非依存のガバナンス変数がGitHub組織レベルルールセットとAzure DevOpsプロジェクトレベルブランチポリシーの両方を駆動し、単一の宣言的ソースからガバナンスパリティを実現。

---

> **注記:** このセクション全体は**提案されたガバナンス機能**を記述する。ガバナンスリソース（ルールセット、ランナーグループ、エージェントプール、リポジトリデフォルト）は `devops/lz` では現在作成されていない。現在の LZ は GitHub PAT と Azure DevOps PAT をブートストラップ Key Vault にシークレットとして格納するのみである。ブランチ保護ルールは `github_workflows` モジュールによりプロジェクトレベルで作成される。

### 9.1 現在のギャップ

- ブランチ保護ルールは `github_workflows` 内でプロジェクトレベルでのみ定義されている。
- ランナーグループは `use_runner_group = true` の場合にプロジェクトごとにのみ作成される。
- 組織レベルのリポジトリ設定ベースラインがない。
- **Azure DevOps のガバナンスは一切管理されていない** — ADO のポリシーやプールは手動で設定される。

### 9.2 ターゲット: プラットフォーム非依存のガバナンス変数

LZ は **プラットフォームに依存しない** ガバナンス設定を定義し、GitHub と Azure DevOps の両方にマッピングする:

```hcl
# devops/lz/_variables.governance.tf

variable "org_default_branch_rules" {
  description = "すべてのプロジェクトリポジトリに適用されるデフォルトのブランチ保護ルール (GitHub + Azure DevOps)"
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
  description = "組織内のすべてのリポジトリのデフォルト設定"
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

### 9.3 GitHub ガバナンスの実装

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
    actor_id    = 0   # 組織管理者
    actor_type  = "OrganizationAdmin"
    bypass_mode = "pull_request"  # 管理者は PR を使用する必要があるが、緊急時にはバイパスできる
  }
}

variable "org_runner_groups" {
  description = "GitHub 組織レベルで作成するランナーグループ"
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

### 9.4 Azure DevOps ガバナンスの実装

Azure DevOps のガバナンスは異なるリソースタイプにマッピングされるが、同じポリシーの意図に対応する:

```hcl
# devops/lz/governance.azuredevops.tf

# 組織レベルのエージェントプール（GitHub ランナーグループに相当）
variable "org_agent_pools" {
  description = "Azure DevOps 組織レベルで作成するエージェントプール"
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

# 注: Azure DevOps のブランチポリシーは組織スコープではなく、プロジェクトスコープ。
# org_default_branch_rules は project_azuredevops モジュールの実行時に
# プロジェクトレベルで適用され、以下にマッピングされる:
#   - azuredevops_branch_policy_min_reviewers
#   - azuredevops_branch_policy_build_validation
#   - azuredevops_branch_policy_auto_reviewers (CODEOWNERS 相当)
```

### 9.5 ガバナンスの対応表

| ガバナンスの意図                 | GitHub（組織レベル）                            | Azure DevOps（組織レベル）      | Azure DevOps（プロジェクトレベル）           |
| -------------------------------- | ----------------------------------------------- | ------------------------------- | -------------------------------------------- |
| **デフォルトブランチの PR 必須** | `github_organization_ruleset`                   | N/A                             | `azuredevops_branch_policy_min_reviewers`    |
| **最小レビュー数**               | ルールセット: `required_approving_review_count` | N/A                             | ブランチポリシー: `minimum_reviewer_count`   |
| **古いレビューの却下**           | ルールセット: `dismiss_stale_reviews_on_push`   | N/A                             | （直接サポートなし）                         |
| **ステータスチェック必須**       | ルールセット: `required_status_checks`          | N/A                             | `azuredevops_branch_policy_build_validation` |
| **エージェント/ランナープール**  | `github_actions_runner_group`（org）            | `azuredevops_agent_pool`（org） | `azuredevops_agent_queue`（プロジェクト）    |
| **リポジトリデフォルト**         | API 経由の組織レベル設定                        | N/A                             | プロジェクトレベルの設定                     |

> **主要なアーキテクチャの違い:** GitHub は組織レベルのルールセットをすべてのリポジトリにカスケードできる。Azure DevOps には組織レベルのブランチポリシーがなく、プロジェクトごとに適用する必要がある。DevOps LZ はこれを、`project_azuredevops` モジュール内のプロジェクト作成時に `org_default_branch_rules` を適用することで処理する。

---

## 関連する決定

- [ADR-004](./ADR-004-github-ado-abstraction.ja.md)
