[English](./ADR-004-github-ado-abstraction.md) | [日本語](./ADR-004-github-ado-abstraction.ja.md)

# ADR-004: GitHub と Azure DevOps — 構造的差異と抽象化

> **ステータス:** 承認済み
> **コンテキスト:** [ターゲットアーキテクチャ仕様](../Target-Architecture-Spec.ja.md)

## 概要

GitHubとAzure DevOpsは根本的に異なる組織階層を持つ。DevOps LZはプラットフォームに依存しない「プロジェクト」概念と統一インターフェースを導入。

---

> **注記:** セクション 7.2〜7.4 で記述される統一インターフェースは**ターゲット設計**である。`project_azuredevops` モジュールは `project_github` と同じインターフェースを提供する（§7）。

### 7.1 構造的な不一致

GitHub と Azure DevOps は、根本的に異なる組織階層を持つ:

```text
GitHub                              Azure DevOps
──────                              ──────────────
Organization                        Organization
├── Repository A                    ├── Project X
├── Repository B                    │   ├── Repository A
├── Repository C                    │   ├── Repository B
├── Teams (組織全体)                 │   ├── Pipelines
├── Runner Groups (組織全体)         │   ├── Environments
├── Org Rulesets (組織全体)          │   ├── Service Connections
└── Environments (リポジトリごと)    │   ├── Agent Pools (プロジェクトスコープ)
                                    │   └── Teams/Groups (プロジェクトスコープ)
                                    ├── Project Y
                                    │   └── ...
                                    └── 組織レベルの Agent Pools
```

主な違い:

| 観点                            | GitHub                                                       | Azure DevOps                                                           |
| ------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------- |
| **「プロジェクト」概念**        | ネイティブなプロジェクトなし; org 配下のフラットなリポジトリ | 独自のセキュリティ境界を持つファーストクラスの `Project` コンテナー    |
| **環境**                        | リポジトリごとに定義                                         | プロジェクトごとに定義                                                 |
| **パイプライン**                | リポジトリ内で定義（GitHub Actions ワークフロー）            | プロジェクト内で定義し、リポジトリファイルを参照                       |
| **チーム/権限**                 | 組織全体のチームとリポジトリごとのアクセス                   | プロジェクトスコープのチーム + 組織レベルのグループ                    |
| **エージェント/ランナープール** | 組織レベルのランナーグループ                                 | 組織レベルとプロジェクトスコープの両方のプール                         |
| **ブランチ保護**                | リポジトリごとのルールセットまたは組織レベルのルールセット   | プロジェクト内のリポジトリごとのブランチポリシー                       |
| **サービス接続**                | N/A（環境ごとの OIDC フェデレーション）                      | プロジェクトスコープのサービス接続（ワークロード ID フェデレーション） |

### 7.2 抽象化: DevOps LZ「プロジェクト」

DevOps Landing Zone は、各 VCS プラットフォームに異なるマッピングを行う論理的な **「プロジェクト」** 概念を導入する:

```text
DevOps LZ プロジェクト                GitHub マッピング              Azure DevOps マッピング
──────────────────                    ──────────────                ────────────────────
project_name = "contoso-ecommerce"    命名規則:                     ADO プロジェクト:
                                      リポジトリに                   "contoso-ecommerce"
                                      "contoso-ecommerce-*" のプレフィックス

repositories = [                      GitHub リポジトリ:             ADO プロジェクト内のリポジトリ:
  { name="...-infra", ... },          contoso-ecommerce-infra       contoso-ecommerce-infra
  { name="...-app",   ... },          contoso-ecommerce-app         contoso-ecommerce-app
]

environments = {                      GitHub Environments            ADO Environments:
  development, staging, production    (リポジトリごと、環境プレフィックス付き) (プロジェクトごと)
}

identities = {                        OIDC フェデレーション           ワークロード ID フェデレーション
  環境 × ジョブごとの UAMI            (環境ごと)                     (サービス接続経由)
}
```

### 7.3 統一インターフェース設計

`project_github` と `project_azuredevops` の両モジュールは、プロジェクトレベルの設定に対して同じ **入力インターフェース** を共有する:

```hcl
# 共有入力インターフェース (project_github と project_azuredevops の両方)

variable "project_name"    { ... }   # → GitHub: 命名プレフィックス │ ADO: プロジェクト名
variable "repositories"    { ... }   # → GitHub: org レベルのリポジトリ │ ADO: プロジェクトスコープのリポジトリ
variable "subscriptions"   { ... }   # → 両方: 環境ごとの Azure サブスクリプション
variable "network_mode"    { ... }   # → 両方: platform または byo
variable "byo_vnet"        { ... }   # → 両方: BYO VNet 設定
variable "shared_identities" { ... } # → 両方: 共有 vs リポジトリごとの UAMI
```

プラットフォーム固有の変数は追加的:

```hcl
# GitHub 固有
variable "use_runner_group"          { ... }
variable "use_templates_repository"  { ... }

# Azure DevOps 固有
variable "create_project"            { ... }   # ADO プロジェクトの作成または既存の参照
variable "use_separate_repo_for_pipeline_templates" { ... }
```

### 7.4 ガバナンスの一貫性

両プラットフォームでガバナンスを一貫させるため、プラットフォーム LZ は **プラットフォームに依存しないガバナンスデフォルト** を定義し、それをプラットフォーム固有のリソースにマッピングする:

| DevOps LZ ガバナンス設定       | GitHub 実装                                         | Azure DevOps 実装                                              |
| ------------------------------ | --------------------------------------------------- | -------------------------------------------------------------- |
| `require_pull_request = true`  | Org ルールセット: `pull_request` ブロック           | ブランチポリシー: `azuredevops_branch_policy_min_reviewers`    |
| `required_review_count = 1`    | Org ルールセット: `required_approving_review_count` | ブランチポリシー: `minimum_reviewer_count`                     |
| `dismiss_stale_reviews = true` | Org ルールセット: `dismiss_stale_reviews_on_push`   | （直接利用不可; ポリシー設定で近似）                           |
| `require_status_checks = true` | Org ルールセット: `required_status_checks`          | ブランチポリシー: `azuredevops_branch_policy_build_validation` |
| `runner_group / agent_pool`    | `github_actions_runner_group`                       | `azuredevops_agent_pool`（組織レベル）                         |

このマッピングは、LZ モジュール内の個別のファイル（`governance.github.tf` と `governance.azuredevops.tf`）で実装され、同じガバナンス変数によって駆動される。

---

## 関連する決定

- [ADR-003](./ADR-003-project-multi-repo-model.ja.md)
- [ADR-006](./ADR-006-organization-governance.ja.md)
