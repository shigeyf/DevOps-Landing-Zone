[English](./ADR-003-project-multi-repo-model.md) | [日本語](./ADR-003-project-multi-repo-model.ja.md)

# ADR-003: プロジェクト定義とマルチリポジトリモデル

> **ステータス:** 承認済み
> **コンテキスト:** [ターゲットアーキテクチャ仕様](../Target-Architecture-Spec.ja.md)

## 概要

DevOps LZ「プロジェクト」はリポジトリ、ID、ランナー、ネットワークコンテキストの論理的なグルーピング。複数リポジトリをCI/CDプロファイル別にサポート。

---

> **注記:** セクション 6.3〜6.7 はマルチリポジトリサポート、リポジトリプロファイル、リポジトリごとの ID、サブセット環境の**ターゲット設計**を記述する。**現在**、`project_github` モジュールは単一のメインリポジトリ + オプションのテンプレートリポジトリ（セクション 6.2）のみをサポートし、ハードコードされた単一の `infra` スタイルのワークフロープロファイルと、リポジトリ間で共有される環境 × ジョブタイプ（plan/apply）ごとの UAMI を持つ。

### 6.1 設計思想: 分離は推奨であり、必須ではない

リポジトリプロファイル（`infra`、`app`、`library`、`docs`）は、異なる CI/CD ワークフロー形状にマッピングされる **推奨パターン** である。すべてのプロジェクトを複数のリポジトリに分割することを義務付けるものではない。

**infra コードと app コードの両方を含む単一リポジトリは完全にサポートされている。** その場合、ユーザーは `infra` プロファイル（最も包括的なブランチ/環境戦略を含む）を割り当て、単一リポジトリが完全な `validate → plan → apply` パイプラインを取得する。マルチリポジトリパターンは、関心の分離、独立したリリースケイデンス、またはきめ細かい RBAC を好むチーム向けに提供される。

| シナリオ                         | 設定                                                          | 結果                                                                 |
| -------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------- |
| 単一リポジトリ（現在の動作）     | `repositories = []` または `infra` プロファイルの単一エントリ | 今日と同一                                                           |
| infra + app を分離               | 2 つのエントリ: `profile = "infra"` + `profile = "app"`       | 別々のワークフロー形状、オプションで別々の UAMI                      |
| 複数の関心事を持つモノリポジトリ | `infra` プロファイルの単一エントリ                            | 1 つのリポジトリが完全なパイプラインを取得; 内部構造はユーザーの選択 |

### 6.2 現在の設計（単一リポジトリ）

```hcl
# 現在
project_name = "my-project"
# → 1 つのリポジトリを作成: "my-project"
# → 1 つのテンプレートリポジトリを作成: "my-project-templates" (オプション)
```

### 6.3 ターゲット設計（マルチリポジトリ）

```hcl
# 新規変数: _variables.repositories.tf

variable "repositories" {
  description = "このプロジェクトのリポジトリリスト"
  type = list(object({
    name        = string
    profile     = string          # "infra" | "app" | "library" | "docs"
    description = optional(string, "")
    visibility  = optional(string) # null → 組織デフォルトを継承
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
    environments = optional(list(string))  # プロジェクト環境のサブセット; null → すべて
  }))

  # 後方互換のデフォルト: 空の場合、単一リポジトリの動作にフォールバック
  default = []

  validation {
    condition = length(var.repositories) == 0 || length(var.repositories) == length(distinct([for r in var.repositories : r.name]))
    error_message = "プロジェクト内のリポジトリ名は一意でなければなりません。"
  }
}
```

#### 後方互換性

`repositories = []`（デフォルト）の場合、モジュールはリポジトリ名として `project_name` を使用する現在の単一リポジトリ動作にフォールバックする。これにより、既存ユーザーに対して破壊的変更がゼロになる。

```hcl
# _locals.tf 内

locals {
  # repositories リストが提供された場合はそれを使用; それ以外は現在の動作にフォールバック
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

### 6.4 リポジトリプロファイル

プロファイルはリポジトリの **ワークフロー形状** を定義する。`github_workflows` モジュール内で定義され、どの CI/CD ワークフローとブランチ戦略が生成されるかを制御する。

| プロファイル | ブランチ                               | CI ワークフロー             | CD ワークフロー                 | 環境                                               |
| ------------ | -------------------------------------- | --------------------------- | ------------------------------- | -------------------------------------------------- |
| `infra`      | `features/*`, `dev`, `staging`, `main` | PR 時の `validate` + `plan` | プッシュ時の `plan` + `apply`   | `features`, `development`, `staging`, `production` |
| `app`        | `features/*`, `dev`, `staging`, `main` | PR 時の `build` + `test`    | プッシュ時の `build` + `deploy` | `development`, `staging`, `production`             |
| `library`    | `features/*`, `main`                   | PR 時の `build` + `test`    | タグ時の `publish`              | —                                                  |
| `docs`       | `main`                                 | —                           | —                               | —                                                  |

> **注記:** `docs` プロファイルは **CI/CD ワークフローを生成しない**。デフォルトのブランチ保護のみでリポジトリを作成する。このプロファイルは、ビルドやデプロイのパイプラインを必要としないドキュメント専用リポジトリ（wiki、ADR、ランブック）を対象としている。

### 6.5 ID (UAMI) 割り当て戦略

#### ID の作成場所

UAMI は **プロジェクトデプロイ時**（Tier 2）に作成され、プラットフォーム LZ レベルで事前登録されるわけではない。プラットフォーム LZ（Tier 1）は、UAMI が配置される **ID リソースグループ** のみを提供する。

サブスクリプションと環境のマッピングは、各プロジェクトの `terraform.tfvars` 内の `subscriptions` 変数で定義される。プラットフォーム LZ はグローバルなサブスクリプションレジストリを **維持しない**。各プロジェクトが環境に必要な Azure サブスクリプションを宣言し、プロジェクトモジュールがそれに応じて UAMI とフェデレーション ID 資格情報を作成する。

**ID モデル:** `github_workflows` モジュールは `{branch_key}-{job_type}` をキーとする `github_environments` マップを生成する（例: `feat-plan`、`dev-apply`、`stg-plan`、`prod-apply`）。プロジェクトモジュールはエントリごとに 1 つの UAMI を作成する — 現在はプロジェクトごとに 7 つの UAMI（4 環境 × plan + 3 環境 × apply。`features` には `apply` ジョブがないため）。各 UAMI は GitHub OIDC 用の単一のフェデレーション ID 資格情報を受け取る。

```text
プラットフォーム LZ (Tier 1)             プロジェクト (Tier 2)
┌─────────────────────┐             ┌──────────────────────────────┐
│ 提供するもの:        │             │ 作成（プロジェクト RG 内）:   │
│ • 共有インフラ       │────────────►│ • 7 UAMI (環境 × ジョブタイプ)│
│   (ACR, Log, UAMI)  │             │   feat-plan, dev-plan,       │
│                     │             │   stg-plan, prod-plan,       │
│                     │             │   dev-apply, stg-apply,      │
│                     │             │   prod-apply                 │
│                     │             │ • 7 フェデレーション ID 資格情報 │
│                     │             │ • サブスクリプションのロール割り当て │
│                     │             │   (subscriptions マップに存在する │
│                     │             │    環境のみ)                  │
│                     │             │                              │
│                     │             │ サブスクリプションマップの出典: │
│                     │             │ • プロジェクトの terraform.tfvars │
└─────────────────────┘             └──────────────────────────────┘
```

#### 共有 vs リポジトリごとの ID

現在: プロジェクトごとに環境 × ジョブタイプ（plan/apply）ごとに 1 つの UAMI。

ターゲット: **リポジトリごとに** 環境 × ジョブタイプ（plan/apply）ごとに 1 つの UAMI（またはユーザーがオプトインした場合はプロジェクトで共有）。

```hcl
variable "shared_identities" {
  description = "プロジェクト内のすべてのリポジトリで UAMI を共有するか（true）、リポジトリごとの ID を作成するか（false）"
  type        = bool
  default     = true   # 後方互換
}
```

`shared_identities = true` の場合: 動作は現在と同一 — 1 セットの UAMI がプロジェクト内のすべてのリポジトリをカバーする。

`shared_identities = false` の場合: 各リポジトリが独自の UAMI セットを取得し、きめ細かい RBAC が可能になる（例: `infra` リポジトリは `Contributor`、`app` リポジトリは `AcrPush` + `Web Apps Contributor` のみ）。

#### UAMI 命名

UAMI は、プロジェクトとリポジトリを人間が読める形式に保ちつつ、環境/ジョブの詳細をハッシュ化する混合命名パターンを使用する:

```
uami-<project>-<repo>-<hash>          # リポジトリごとの ID (shared_identities = false)
uami-<project>-<hash>                 # 共有 ID (shared_identities = true)
```

完全な命名規則、ハッシュの導出方法、および例については、[セクション 11.3](#113-uami-命名規則) を参照。

### 6.6 サンプル `terraform.tfvars` — マルチリポジトリプロジェクト

```hcl
# terraform.tfvars — プロジェクト "contoso-ecommerce"

target_subscription_id = "00000000-0000-0000-0000-000000000000"
project_name           = "contoso-ecommerce"
location               = "japaneast"

tags = {
  appTag     = "contoso-ecommerce"
  envTag     = "prod"
  projectTag = "devops"
  purposeTag = "alz"
}

# このプロジェクトの複数リポジトリ
repositories = [
  {
    name    = "contoso-ecommerce-infra"
    profile = "infra"
    description = "Contoso e-commerce プラットフォームの Azure インフラストラクチャ"
  },
  {
    name    = "contoso-ecommerce-api"
    profile = "app"
    description = "バックエンド API サービス"
  },
  {
    name    = "contoso-ecommerce-web"
    profile = "app"
    description = "フロントエンド Web アプリケーション"
    environments = ["development", "staging", "production"]  # features 環境なし
  },
  {
    name    = "contoso-ecommerce-shared"
    profile = "library"
    description = "共有ライブラリとユーティリティ"
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

# ネットワークモード
network_mode = "platform"  # LZ 管理の VNet を使用

# ランナーオプション
use_templates_repository = true
use_self_hosted_runners  = true
self_hosted_runners_type = "aca"
```

### 6.7 サンプル `terraform.tfvars` — 環境のサブセット（dev + prod のみ）

```hcl
# terraform.tfvars — development と production 環境のみのプロジェクト

target_subscription_id = "00000000-0000-0000-0000-000000000000"
project_name           = "contoso-internal-tool"
location               = "japaneast"

tags = {
  appTag     = "contoso-internal-tool"
  envTag     = "prod"
  projectTag = "devops"
}

# 単一リポジトリ（後方互換; repositories = [] はリポジトリ名として project_name を使用）

# 2 つの環境のみ — features と staging なし
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

> **注記（ターゲット動作）:** このサンプルはサブセット環境サポートの意図を示す。ターゲット: `subscriptions` マップに存在する環境のみに対して GitHub Actions Environments、UAMI、ブランチ、フェデレーション資格情報を作成する。対応するサブスクリプションエントリがない環境はリソースを生成しない。

---

## 関連する決定

- [ADR-004](./ADR-004-github-ado-abstraction.ja.md)
- [ADR-008](./ADR-008-naming-collision-resistance.ja.md)
