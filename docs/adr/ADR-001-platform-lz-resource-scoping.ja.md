[English](./ADR-001-platform-lz-resource-scoping.md) | [日本語](./ADR-001-platform-lz-resource-scoping.ja.md)

# ADR-001: 組織レベルのランディングゾーン (`devops/lz`)

> **ステータス:** 承認済み
> **コンテキスト:** [ターゲットアーキテクチャ仕様](../Target-Architecture-Spec.ja.md)

## 概要

Platform LZはorganization共有インフラを管理する。主要な発見は、ACA Environmentがプロジェクトスコープであるべきという点。各プロジェクトのランナーはプロジェクト自身のネットワークコンテキストで動作する必要があるため。

---

### 5.1 役割: プラットフォーム ブートストラップ（Layer 1 内の Tier 1）

ランディングゾーンは **組織プラットフォーム ブートストラップ** として機能する。Tier 0 (`_bootstrap`) の後に適用される最初の Terraform レイヤーであり、プロジェクトが依存するすべての共有 Azure リソースと VCS リソースを作成する。

運用上:

- **Tier 0** (`_bootstrap`) は一度適用され、ほとんど更新されない。Layer 1 Storage Account を作成する。
- **Tier 1** (`devops/lz`) は、組織のプラットフォーム構成が変更された際に適用される（例: 新しいサブネット、新しい DevBox 定義、ガバナンスポリシーの変更）。
- 両ティアとも、異なる状態キーの下で同じ Layer 1 Storage Account に状態を格納する。

### 5.2 プラットフォーム LZ リソースレビュー — 組織スコープ vs. プロジェクトスコープ

プラットフォーム LZ が作成する各リソースを、組織レベル（全プロジェクトで共有）に属するべきか、プロジェクトレベル（プロジェクトごとに作成）に移すべきかの観点で評価する必要がある。以下の表はレビュー結果の要約である:

| リソース                                           | 現在のスコープ   | 正しいスコープ          | 判定と根拠                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| -------------------------------------------------- | ---------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ID リソースグループ**                            | プラットフォーム | **プラットフォーム** ✅ | ID RG は共有リソースコンテナー。ID 自体は作成しない — UAMI はプロジェクトデプロイ時（Tier 2）にこの RG 内に作成される。組織レベルの共有 RG はすべてのプロジェクト UAMI の予測可能で一元管理された配置場所を提供し、RBAC を簡素化し、プロジェクトごとの RG の乱立を防ぐ。                                                                                                                                                                    |
| **エージェント RG**                                | プラットフォーム | **分割が必要** ⚠️       | エージェント RG は現在 ACR、ACA Environment、Log Analytics、コンテナー実行 UAMI をホストしている。ACR と Log Analytics は正しく組織スコープ。しかし ACA Environment（ランナーコンピューティング）はプロジェクトスコープにすべき — 下記参照。                                                                                                                                                                                                |
| **ACR（コンテナーレジストリ）**                    | プラットフォーム | **プラットフォーム** ✅ | ランナーイメージ用の共有コンテナーイメージレジストリ。全プロジェクトが同じ ACR からイメージをプルする。組織レベルのスコープで正しい。                                                                                                                                                                                                                                                                                                       |
| **Log Analytics ワークスペース**                   | プラットフォーム | **プラットフォーム** ✅ | エージェント/ランナー運用のための一元ログ管理。組織レベルのスコープで正しい。                                                                                                                                                                                                                                                                                                                                                               |
| **コンテナー実行 UAMI**                            | プラットフォーム | **プラットフォーム** ✅ | ACR からのイメージプルと Key Vault シークレットの読み取りに使用される共有 ID。組織レベルリソース（ACR、Key Vault）にアクセスするため、組織スコープで正しい。                                                                                                                                                                                                                                                                                |
| **ACA Environment**                                | プラットフォーム | **プロジェクト** ✅     | ターゲット: ACA Environment はプロジェクトスコープのリソース。各プロジェクトが自身の有効なランナーサブネット内に ACA Environment を作成する（`platform` モード = Platform LZ VNet 内のプロジェクト専用 ACA サブネット、`byo` モード = ユーザー提供の BYO サブネット）。Platform LZ は ACR、Log Analytics、コンテナー実行 UAMI、プライベート DNS ゾーンなど、プロジェクトレベルの ACA Environment が共有利用するインフラを引き続き提供する。 |
| **ネットワーク RG + プラットフォーム VNet**        | プラットフォーム | **プラットフォーム** ✅ | 組織スコープで正しい。`network_mode = "platform"` のプロジェクトに共有ネットワークインフラを提供。                                                                                                                                                                                                                                                                                                                                          |
| **プライベート DNS ゾーン**                        | プラットフォーム | **プラットフォーム** ✅ | プライベートエンドポイント解決用の共有 DNS ゾーン。組織スコープで正しい。                                                                                                                                                                                                                                                                                                                                                                   |
| **プライベートエンドポイント（ブートストラップ）** | プラットフォーム | **プラットフォーム** ✅ | ブートストラップ Storage Account と Key Vault へのプライベートエンドポイント。組織スコープで正しい。                                                                                                                                                                                                                                                                                                                                        |
| **Dev Center**                                     | プラットフォーム | **プラットフォーム** ✅ | 組織レベルのシングルトンリソース。DevBox 定義は全プロジェクトで共有。DevBox プロジェクトプールはプロジェクトレベルで作成。組織スコープで正しい。                                                                                                                                                                                                                                                                                            |
| **コンテナーイメージ ビルドタスク**                | プラットフォーム | **プラットフォーム** ✅ | ランナーコンテナーイメージの ACR タスク。全プロジェクトで共有。組織スコープで正しい。                                                                                                                                                                                                                                                                                                                                                       |
| **VCS ガバナンスリソース**                         | プラットフォーム | **プラットフォーム** ⚠️ | 組織レベルのルールセット（GitHub）とエージェントプール（Azure DevOps）はプラットフォームレベルに属する。ターゲットアーキテクチャではセクション 9 のとおり `devops/lz` でガバナンスリソースを管理する。                                                                                                                                                                                                                                      |

#### 主要な発見: ACA Environment はプロジェクトスコープにすべき

最も重要な発見は、**ACA Environment**（セルフホステッドランナー用の Azure Container Apps Environment）を**プラットフォーム LZ からプロジェクトモジュールに移動**すべきという点である:

1. **ネットワーク分離の要件:** セルフホステッドランナーはプロジェクトのネットワークコンテキストで動作する必要がある。BYO VNet プロジェクトの場合、ランナーの ACA Environment はプロジェクトの VNet 内（`Microsoft.App/environments` サブネット委任付き）に配置する必要がある。プラットフォーム VNet の ACA Environment は共有できない — ACA Environment は単一の VNet にバインドされるため。

2. **現在の矛盾:** セクション 8（BYO VNet）では BYO VNet プロジェクトが独自の ACA Environment を作成すると記載（決定事項 #6）しているが、セクション 5.2 では ACA Environment を共有プラットフォームリソースとして列挙している。これは矛盾している。

3. **推奨される設計:**
   - **プラットフォーム LZ** が提供: ACR、Log Analytics、コンテナー実行 UAMI、コンテナーイメージ ビルドタスク — すべてのランナー環境が利用する*共有インフラ*。
   - **プロジェクトモジュール** が作成: ACA Environment（プロジェクトの VNet またはプラットフォーム VNet サブネット内）、ACA ランナージョブ — _プロジェクトごとのランナーコンピューティング_。

```text
プラットフォーム LZ (Tier 1)              プロジェクト (Tier 2)
┌───────────────────────────┐           ┌──────────────────────────────────┐
│ 提供するもの（共有）:      │           │ 作成するもの（プロジェクトごと）: │
│ • ACR（ランナーイメージ）  │──────────►│ • ACA Environment               │
│ • Log Analytics            │           │   (プラットフォーム VNet or BYO) │
│ • コンテナー実行 UAMI      │           │ • ACA ランナージョブ             │
│ • コンテナーイメージタスク  │           │ • ACI ランナーインスタンス (ACI時)│
│ • プラットフォーム VNet     │           │                                  │
│                            │           │ LZ から利用するもの:              │
│ 作成しなくなるもの:         │           │ • ACR ログインサーバー            │
│ • ACA Environment ← 移動  │           │ • Log Analytics ワークスペース ID │
│                            │           │ • コンテナー実行 UAMI ID         │
│                            │           │ • サブネット ID (platform or BYO) │
└───────────────────────────┘           └──────────────────────────────────┘
```

#### ID リソースグループの根拠

ID RG のパターン（空の組織レベル RG をプロジェクト時に UAMI で充填）は以下の理由で有効かつ有用:

- **一元化された RBAC:** 単一の ID RG により、プラットフォーム管理者がすべての UAMI に一貫したアクセスポリシーを一箇所で設定可能。
- **発見容易性:** すべてのプロジェクト UAMI が同一場所に配置され、監査とライフサイクル管理が容易。
- **プロジェクトごとの RG オーバーヘッドなし:** プロジェクトごとに個別の ID RG を作成する必要がなく、管理対象が増えない。
- **実行時には RG は空ではない** — プロジェクトがプロビジョニングされた後、すべてのプロジェクト UAMI が格納される。

### 5.3 変わらない点（改訂版）

- ブートストラップリソース（Storage Account、Key Vault）
- ID リソースグループ（プロジェクト UAMI の共有コンテナー）
- 組織スコープリソース用のエージェント リソースグループ（ACR、Log Analytics、コンテナー実行 UAMI） — セクション 5.4.1 により ACA Environment はこの RG からプロジェクトレベルへ移動する
- ネットワーク リソースグループとプラットフォーム管理 VNet の作成
- Dev Center と DevBox の定義
- コンテナーイメージのビルドタスク

> **注記:** 「変わらない点」は組織レベルに留まるリソースを指す。VCS ガバナンスリソース（組織レベルのルールセット、ランナーグループ、エージェントプール）は組織レベルに属する（セクション 9 参照）。

### 5.4 変更点（ターゲットアーキテクチャ）

> **注記:** 以下のサブセクションは**ターゲットアーキテクチャ**を記述する。§5.4.1 は ACA Environment のプロジェクトレベル移動、§5.4.2 および §5.4.3 はガバナンス出力とプロジェクトスコープのネットワークバインドを記述する。

#### 5.4.1 ACA Environment のプロジェクトレベルへの移動（ターゲットアーキテクチャ）

**ターゲット設計。** ACA Environment（ランナーのコンピュート プレーン）は**プロジェクトレベル**のリソースとする。プロジェクトモジュール（`project_github` / `project_azuredevops`）が、**プロジェクトの DevOps VNet** 内に ACA Environment を作成する（`network_mode = "platform"` ではプラットフォーム VNet、`network_mode = "byo"` では BYO VNet）。Platform LZ は ACA Environment を作成しない。

**このアーキテクチャが正しい理由:**

1. Azure Container Apps Environment は作成時に**ただ 1 つの VNet** にバインドされる。組織レベルの単一 ACA Environment では、プラットフォーム VNet と接続しない BYO VNet を持つプロジェクトを扱えない。ACA Environment をプロジェクトスコープにすることで、この構造的な衝突が解消される。
2. プロジェクトのターゲットサブスクリプションに対して Terraform を実行するセルフホステッドランナーは、デプロイ対象の Azure リソース（Storage / Key Vault / SQL / プライベートリンク PaaS のプライベートエンドポイント、ピアリングされたアプリケーション VNet）にネットワーク疎通を持つ必要がある。この経路は**プロジェクトの DevOps VNet** で定義されるため、ランナーコンピュートは同じ VNet に配置しなければならない。
3. プロジェクト間のコンピュート分離: あるプロジェクトの ACA Environment で発生した障害・スケール上限・設定ミスは、他のプロジェクトに波及しない。

**責務分担（ターゲット）:**

| レイヤー             | 提供するリソース                                                                                                                                                                                                              |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Platform LZ          | ACR（ランナーイメージ）、Log Analytics Workspace（ログシンク）、コンテナー実行 UAMI（イメージ Pull + KV シークレットアクセス）、コンテナーイメージビルドタスク、プラットフォーム VNet + サブネット、プライベート DNS ゾーン   |
| Project（LZ 消費側） | ACA Environment（プロジェクト DevOps VNet 内）、ACA Job / ACI ランナーリソース、ランナーグループ / エージェントプール登録、プロジェクトレベルのプライベートエンドポイント、プロジェクト IaC 用の Layer 2 ストレージアカウント |

**サブネット解決（ターゲット）:**

```text
network_mode = "platform"                network_mode = "byo"
─────────────────────────                ────────────────────
ACA Environment サブネット:              ACA Environment サブネット:
  devops_network.aca_subnet_id             byo_vnet.container_app_subnet_id
  （LZ remote state から取得）              （ユーザー入力。必ず
                                            Microsoft.App/environments の
                                            委任が必要）
```

**必要となる LZ 出力の変更:**

- **削除:** `devops_agents` 出力から `container_app_environment_id`（および関連 ACA Environment フィールド）を削除する。
- **追加（または維持）:** `devops_network` 出力に `aca_subnet_id` を含め、`platform` モードのプロジェクトが自身の ACA Environment を正しいサブネットに配置できるようにする。
- **維持:** `acr_login_server`、Log Analytics Workspace ID、コンテナー実行 UAMI のプリンシパル ID / クライアント ID。これらはプロジェクトレベルの ACA Environment がバインドする共有依存である。

**移行上の注意:** 既存デプロイに対しては**破壊的な変更**である。ACA Environment のリソース ID は LZ の state ファイルから各プロジェクトの state ファイルへ移動する。移行ステップ:

1. LZ の state から `terraform state rm` で ACA Environment リソースを削除する。
2. Azure 側の組織レベル ACA Environment を削除する（またはすべてのプロジェクト移行完了後に廃棄する）。
3. プロジェクトモジュールを apply し、プロジェクトの DevOps VNet 内に新しい ACA Environment を作成、ランナーを再登録する。
4. ランナー登録トークン（PAT / OIDC）を再発行する。ランナー ID は新しい Environment に再バインドされるため。

現在の状態: ACA Environment は LZ レベルに存在する。ターゲット: プロジェクトモジュールが ACA Environment を作成し、`network_mode = "byo"` プロジェクトのサポートを有効にする。

#### 5.4.2 ガバナンス出力（提案）

LZ は、プロジェクトが継承する組織ガバナンス設定を公開する:

```hcl
# 新規ファイル: devops/lz/_variables.governance.tf

variable "org_default_branch_rules" {
  description = "すべてのプロジェクトリポジトリに適用されるデフォルトのブランチ保護ルール"
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
  description = "組織のデフォルトランナーグループ設定"
  type = object({
    visibility             = optional(string, "selected")
    allows_public_repos    = optional(bool, false)
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

#### 5.4.3 提案：プロジェクト利用のための新しい出力

> **注記:** 以下の出力は**提案された追加**である。現在の `devops/lz/_outputs.tf` は `devops_agents`、`devops_identity`、`devops_network`、`devops_devbox`、`container_specs`、`options` をエクスポートしている。以下に示す `org_governance` および `network_mode_info` 出力はまだ存在しない。

```hcl
# devops/lz/_outputs.tf への提案追加

output "org_governance" {
  value = {
    default_branch_rules    = var.org_default_branch_rules
    runner_group_defaults   = var.org_runner_group_defaults
    repository_defaults     = var.org_repository_defaults
  }
  description = "プロジェクトが継承する組織レベルのガバナンスデフォルト"
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
  description = "platform または BYO ネットワークを使用するプロジェクト向けのネットワーク情報"
}
```

---

## 関連する決定

- [ADR-002](./ADR-002-runner-compute-model.ja.md)
- [ADR-005](./ADR-005-vnet-architecture.ja.md)
