# モジュール設計仕様書

[English](./Module-Design.md) | [日本語](./Module-Design.ja.md)

> **ステータス:** ドラフト — 計画フェーズ。
>
> **目的:** 4 層 DevOps Landing Zone デプロイメントモデル用の再利用可能なサブモジュール（ビルディングブロック）設計を定義する。各デプロイメントレイヤー（`bootstrap`、`devops-org-lz`、`devops-project-lz`、`devops-repo-lz`）は、統一インターフェースの背後にリソースと VCS 固有の実装をカプセル化する抽象的なドメインレベルのサブモジュールで構成される。

---

## 目次

1. [4 層デプロイメントモデル](#1-4-層デプロイメントモデル)
2. [モジュール設計原則](#2-モジュール設計原則)
3. [レイヤー 0: ブートストラップサブモジュール (bootstrap)](#3-レイヤー-0-ブートストラップサブモジュール-bootstrap)
4. [レイヤー 1: 組織 LZ サブモジュール (devops-org-lz)](#4-レイヤー-1-組織-lz-サブモジュール-devops-org-lz)
5. [レイヤー 2: プロジェクト LZ サブモジュール (devops-project-lz)](#5-レイヤー-2-プロジェクト-lz-サブモジュール-devops-project-lz)
6. [レイヤー 3: リポジトリ LZ サブモジュール (devops-repo-lz)](#6-レイヤー-3-リポジトリ-lz-サブモジュール-devops-repo-lz)
7. [抽象モジュールパターン](#7-抽象モジュールパターン)
8. [モジュール構成図](#8-モジュール構成図)
9. [実装計画](#9-実装計画)

---

## 1. 4 層デプロイメントモデル

DevOps Landing Zone は **4 つ** の個別の Terraform デプロイメント（それぞれ独自の状態を持つ）を使用する。Layer 0（ブートストラップ）は状態バックエンドを作成する基盤であり、Layer 1〜3 がその上に構築される:

| Layer | デプロイメント        | ディレクトリ               | スコープ                                                       | 状態キー                                   |
| ----- | --------------------- | -------------------------- | -------------------------------------------------------------- | ------------------------------------------ |
| 0     | **ブートストラップ**  | `infra/bootstrap/`         | Layer 1 Storage Account + Key Vault + CMK + UAMI               | `bootstrap.terraform.tfstate`              |
| 1     | **devops-org-lz**     | `infra/devops-org-lz/`     | 組織全体の共有インフラ                                         | `devops-lz.terraform.tfstate`              |
| 2     | **devops-project-lz** | `infra/devops-project-lz/` | プロジェクトごとのインフラ（ID、ランナー、状態、ネットワーク） | `projects/<name>.terraform.tfstate`        |
| 3     | **devops-repo-lz**    | `infra/devops-repo-lz/`    | リポジトリごとのリソース + 環境                                | `repos/<project>/<repo>.terraform.tfstate` |

各レイヤーは `terraform_remote_state` を通じて前のレイヤーの出力を読み取る。Layer 0 は一度だけ適用される（再適用はまれ）。Layer 1〜3 は通常の運用サイクルに従う。

---

## 2. モジュール設計原則

1. **VCS プラットフォームの抽象化** — `project_repo`、`environment`、`runner` などのサブモジュールは `vcs_provider` 入力（`"github"` または `"azuredevops"`）を受け取り、内部で正しい実装にディスパッチする。呼び出し側は統一された入出力契約を得る。

2. **単一責務** — 各サブモジュールは正確に 1 つのドメイン概念を所有する（例: プロジェクト状態ストレージ、プロジェクト ID、リポジトリプロビジョニング、環境バインディング）。

3. **可能な限りプラットフォーム非依存** — 純粋な Azure リソースを扱うモジュール（`project_state`、`project_identity`、`project_network`、`aca_env`）は GitHub と Azure DevOps の両プロジェクトで同一に動作する。

4. **必要な場合のみ VCS 固有** — VCS API と対話するモジュール（`project_repo`、`environment`、`runner`）は抽象ディスパッチパターンを使用する。

5. **合成可能、ネストしない** — サブモジュールは互いに呼び出さない。ルートモジュール（`project_github`、`repo_github` 等）がサブモジュールを合成し、出力を渡す。

6. **一貫したインターフェース** — すべての抽象モジュールは共通の変数パターンを共有する: `vcs_provider`、`project_name`、およびドメイン固有の入力。

---

## 3. レイヤー 0: ブートストラップサブモジュール (bootstrap)

ブートストラップレイヤーは DevOps Landing Zone 全体の基盤となる状態バックエンドとシークレットストアを作成する。組織ごとに **1 回** だけ適用される（再適用はまれ）。ローカル状態ファイルを使用し、作成した Storage Account に移行する。

### Layer 0 — 統合リソース一覧

| #   | リソース                          | Azure タイプ / Terraform タイプ  | リソースグループ     | サブモジュール |
| --- | --------------------------------- | -------------------------------- | -------------------- | -------------- |
| 1   | ブートストラップ リソースグループ | `azurerm_resource_group`         | _(自身)_             | `bootstrap`    |
| 2   | Layer 1 Storage Account           | `azurerm_storage_account`        | Bootstrap RG         | `bootstrap`    |
| 3   | `tfstate` blob コンテナ           | `azurerm_storage_container`      | Bootstrap RG (SA)    | `bootstrap`    |
| 4   | ブートストラップ Key Vault        | `azurerm_key_vault`              | Bootstrap RG         | `bootstrap`    |
| 5   | `tfbackend_cmk` キー              | `azurerm_key_vault_key`          | Bootstrap RG (KV)    | `bootstrap`    |
| 6   | ブートストラップ UAMI             | `azurerm_user_assigned_identity` | Bootstrap RG         | `bootstrap`    |
| 7   | `azurerm.tfbackend` 設定ファイル  | `local_file`                     | _(ローカルディスク)_ | `bootstrap`    |

**合計: 1 リソースグループ、7 リソース。**

### サブモジュール

| サブモジュール | 責務                                          | プラットフォーム非依存? | ステータス |
| -------------- | --------------------------------------------- | ----------------------- | ---------- |
| `bootstrap`    | RG + Storage Account + Key Vault + CMK + UAMI | はい                    | 既存       |

### `bootstrap`

Layer 1 状態バックエンドとその保護チェーンを作成する。

**デプロイされるリソース:**

| リソース                          | Terraform タイプ                 | 目的                                                                                     |
| --------------------------------- | -------------------------------- | ---------------------------------------------------------------------------------------- |
| ブートストラップ リソースグループ | `azurerm_resource_group`         | 全ブートストラップリソースのコンテナ。Layer 1 状態バックエンドのライフサイクルアンカー   |
| Layer 1 Storage Account           | `azurerm_storage_account`        | bootstrap、Org LZ、Project LZ、Repo LZ の tfstate を格納（blob バージョニング + 不変性） |
| `tfstate` blob コンテナ           | `azurerm_storage_container`      | モジュールごとの tfstate コンテナ（bootstrap、lz、project\_\*、repos/\*）                |
| ブートストラップ Key Vault        | `azurerm_key_vault`              | Layer 1 SA を暗号化する CMK を保持。パージ保護、RBAC 認可                                |
| `tfbackend_cmk` キー              | `azurerm_key_vault_key`          | Layer 1 Storage Account を暗号化する RSA キー（tfstate の多層防御）                      |
| ブートストラップ UAMI             | `azurerm_user_assigned_identity` | CMK アクセス権を付与された ID（`Storage Account → Key Vault` 暗号化チェーン）            |
| `azurerm.tfbackend` 設定ファイル  | `local_file`                     | すべての下流レイヤー用に生成された Terraform バックエンド設定テンプレート                |

**出力:** `storage_account_name`、`storage_account_id`、`key_vault_id`、`key_vault_uri`、`resource_group_name`、`bootstrap_config_json`（すべての下流レイヤーで消費される）。

---

## 4. レイヤー 1: 組織 LZ サブモジュール (devops-org-lz)

Org LZ は、既存および新規のサブモジュールを使用して組織全体の共有インフラをプロビジョニングする単一のルートモジュールである。

### Layer 1 — 統合リソース一覧

| #   | リソース                              | Azure タイプ / Terraform タイプ         | リソースグループ | サブモジュール   |
| --- | ------------------------------------- | --------------------------------------- | ---------------- | ---------------- |
| 1   | ネットワーク RG                       | `azurerm_resource_group`                | _(自身)_         | `vnet`           |
| 2   | プラットフォーム LZ VNet              | `azurerm_virtual_network`               | Network RG       | `vnet`           |
| 3   | サブネット（ランナー、DevBox、PE 等） | `azurerm_subnet`                        | Network RG       | `vnet`           |
| 4   | NAT Gateway（設定時）                 | `azurerm_nat_gateway`                   | Network RG       | `vnet`           |
| 5   | NAT Gateway パブリック IP             | `azurerm_public_ip`                     | Network RG       | `vnet`           |
| 6   | プライベート DNS ゾーン               | `azurerm_private_dns_zone`              | Network RG       | `vnet`           |
| 7   | プライベートエンドポイント（SA、KV）  | `azurerm_private_endpoint`              | Network RG       | `vnet`           |
| 8   | Agents RG                             | `azurerm_resource_group`                | _(自身)_         | `acr`            |
| 9   | Azure Container Registry              | `azurerm_container_registry`            | Agents RG        | `acr`            |
| 10  | ACR ビルドタスク                      | `azurerm_container_registry_task`       | Agents RG        | `acr`            |
| 11  | ACR プライベートエンドポイント        | `azurerm_private_endpoint`              | Agents RG        | `acr`            |
| 12  | Log Analytics ワークスペース          | `azurerm_log_analytics_workspace`       | Agents RG        | `acr`            |
| 13  | Container-Run UAMI                    | `azurerm_user_assigned_identity`        | Agents RG        | `acr`            |
| 14  | DevBox RG                             | `azurerm_resource_group`                | _(自身)_         | `devcenter`      |
| 15  | Dev Center                            | `azurerm_dev_center`                    | DevBox RG        | `devcenter`      |
| 16  | Dev Box Definitions                   | `azurerm_dev_center_dev_box_definition` | DevBox RG        | `devcenter`      |
| 17  | KV シークレット（VCS PAT）            | `azurerm_key_vault_secret`              | Bootstrap KV     | `devcenter`      |
| 18  | 組織レベルルールセット（GitHub）      | `github_organization_ruleset`           | —                | `org_governance` |
| 19  | ランナーグループ（GitHub）            | `github_actions_runner_group`           | —                | `org_governance` |
| 20  | エージェントプール（ADO）             | `azuredevops_agent_pool`                | —                | `org_governance` |

**合計: 3 リソースグループ（Network RG、Agents RG、DevBox RG）、約 20 リソース。**

### サブモジュール

| サブモジュール   | 責務                                                                       | プラットフォーム非依存? | ステータス |
| ---------------- | -------------------------------------------------------------------------- | ----------------------- | ---------- |
| `vnet`           | プラットフォーム VNet + サブネット + NAT Gateway + プライベート DNS ゾーン | はい                    | 既存       |
| `acr`            | Azure Container Registry + イメージビルドタスク                            | はい                    | 既存       |
| `org_governance` | 組織レベルのルールセット、ランナーグループ、エージェントプール             | いいえ（ディスパッチ）  | 新規       |
| `devcenter`      | Dev Center + Dev Box Definitions（組織カタログ）                           | はい                    | 新規       |

> [!NOTE]
> `resource_providers` はターゲット設計では意図的に**モジュール化しない**。
> リソースプロバイダー登録は、複数プロジェクト間での state 所有権競合を避けるため、再利用サブモジュール外で別管理とする。

### `vnet`

プラットフォーム管理 VNet と関連ネットワークインフラを作成。

**デプロイされるリソース:**

| リソース                                     | Terraform タイプ           | 目的                                                                         |
| -------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------- |
| プラットフォーム LZ VNet                     | `azurerm_virtual_network`  | プラットフォームのハブ VNet。PE、ランナーサブネット、DevBox サブネットを格納 |
| サブネット（ランナー、DevBox、PE 等）        | `azurerm_subnet`           | プロジェクト専用アドレススライスとプラットフォーム共有サービススライス       |
| NAT Gateway（設定時）                        | `azurerm_nat_gateway`      | ランナージョブの決定論的エグレス（IP 許可リスト登録可）                      |
| NAT Gateway パブリック IP                    | `azurerm_public_ip`        | NAT Gateway に割り当てられた静的パブリック IP                                |
| プライベート DNS ゾーン（blob、vault 等）    | `azurerm_private_dns_zone` | プラットフォームおよび BYO プロジェクト VNet からの PE 名前解決              |
| プライベートエンドポイント（Layer 1 SA、KV） | `azurerm_private_endpoint` | ブートストラップ SA と KV へのプライベート接続                               |
| ネットワーク RG                              | `azurerm_resource_group`   | VNet、サブネット、NAT、DNS ゾーン、PE を格納                                 |

### `acr`

共有コンテナレジストリを作成。

**デプロイされるリソース:**

| リソース                       | Terraform タイプ                  | 目的                                                             |
| ------------------------------ | --------------------------------- | ---------------------------------------------------------------- |
| Azure Container Registry       | `azurerm_container_registry`      | Premium ACR + PE。セルフホステッドランナーコンテナイメージを格納 |
| ACR ビルドタスク               | `azurerm_container_registry_task` | プラットフォーム内でランナーコンテナイメージをビルド・更新       |
| ACR プライベートエンドポイント | `azurerm_private_endpoint`        | プラットフォーム VNet からの ACR へのプライベートアクセス        |
| Agents RG                      | `azurerm_resource_group`          | ACR、Log Analytics、container-run UAMI を格納                    |
| Log Analytics ワークスペース   | `azurerm_log_analytics_workspace` | 全プロジェクトのランナー ACA Environment のログ/メトリクス集約   |
| Container-Run UAMI             | `azurerm_user_assigned_identity`  | ランナーコンテナが ACR プルとログ書き込みに使用する ID           |

### `org_governance` — 抽象モジュール

```hcl
module "org_governance" {
  source       = "./modules/org_governance"
  vcs_provider = var.vcs_provider   # "github" | "azuredevops"

  # 統一入力
  default_branch_rules = var.org_default_branch_rules
  runner_group_name    = var.runner_group_name
  # ...
}
```

内部でディスパッチ:

- `modules/org_governance/github.tf` — GitHub 組織ルールセット + ランナーグループ
- `modules/org_governance/azuredevops.tf` — ADO ブランチポリシー + エージェントプール

**デプロイされるリソース（GitHub）:**

| リソース                 | Terraform タイプ                          | 目的                                             |
| ------------------------ | ----------------------------------------- | ------------------------------------------------ |
| 組織レベルルールセット   | `github_organization_ruleset`             | ブランチ保護と必須ワークフローを組織全体で適用   |
| ランナーグループ         | `github_actions_runner_group`             | プロジェクトごとのランナー分離を組織レベルで実施 |
| リポジトリデフォルト設定 | `github_actions_organization_permissions` | 新規リポジトリのデフォルト Actions 権限          |

**デプロイされるリソース（Azure DevOps）:**

| リソース           | Terraform タイプ               | 目的                                     |
| ------------------ | ------------------------------ | ---------------------------------------- |
| エージェントプール | `azuredevops_agent_pool`       | プロジェクトごとのエージェントプール分離 |
| ブランチポリシー   | `azuredevops_branch_policy_*`  | ブランチ保護を組織全体で適用             |
| プロジェクト設定   | `azuredevops_project_features` | プロジェクトのデフォルト機能設定         |

### `devcenter`

組織全体の Dev Center と Dev Box カタログを作成。

**デプロイされるリソース:**

| リソース                   | Terraform タイプ                        | 目的                                                                     |
| -------------------------- | --------------------------------------- | ------------------------------------------------------------------------ |
| Dev Center                 | `azurerm_dev_center`                    | 組織全体の開発者 Dev Box 制御プレーン                                    |
| Dev Box Definitions        | `azurerm_dev_center_dev_box_definition` | イメージ/SKU ごとの Dev Box 定義（カタログ）                             |
| DevBox RG                  | `azurerm_resource_group`                | Dev Center と定義を格納                                                  |
| KV シークレット（VCS PAT） | `azurerm_key_vault_secret`              | プロジェクトプロビジョニング用にブートストラップ KV に格納される VCS PAT |

---

## 5. レイヤー 2: プロジェクト LZ サブモジュール (devops-project-lz)

プロジェクト LZ はプロジェクトごとのインフラをプロビジョニングする。リポジトリや環境は作成 **しない** — それらは Layer 3 に属する。

### Layer 2 — 統合リソース一覧（プロジェクトごと）

| #   | リソース                                             | Azure タイプ / Terraform タイプ                          | リソースグループ | サブモジュール     |
| --- | ---------------------------------------------------- | -------------------------------------------------------- | ---------------- | ------------------ |
| 1   | プロジェクト リソースグループ                        | `azurerm_resource_group`                                 | _(自身)_         | `project_state`    |
| 2   | Layer 2 Storage Account                              | `azurerm_storage_account`                                | Project RG       | `project_state`    |
| 3   | Layer 2 blob コンテナ                                | `azurerm_storage_container`                              | Project RG       | `project_state`    |
| 4   | プロジェクト Key Vault                               | `azurerm_key_vault`                                      | Project RG       | `project_state`    |
| 5   | Layer 2 プライベートエンドポイント                   | `azurerm_private_endpoint`                               | Project RG       | `project_state`    |
| 6   | Layer 2 PE DNS ゾーンリンク                          | `azurerm_private_dns_zone_virtual_network_link`          | Project RG       | `project_state`    |
| 7   | 7 プロジェクト UAMI                                  | `azurerm_user_assigned_identity` (×7)                    | Project RG       | `project_identity` |
| 8   | OIDC フェデレーション資格情報 (×7)                   | `azurerm_federated_identity_credential`                  | Project RG       | `project_identity` |
| 9   | サブスクリプションロール割り当て                     | `azurerm_role_assignment`（条件付き）                    | _(sub スコープ)_ | `project_identity` |
| 10  | プロジェクト ACA サブネット _(platform モード)_      | `azurerm_subnet`                                         | Network RG       | `project_network`  |
| 11  | ACA Environment                                      | `azurerm_container_app_environment`                      | Project RG       | `aca_env`          |
| 12  | ACA Environment DNS ゾーンリンク                     | `azurerm_private_dns_zone_virtual_network_link`          | Project RG       | `aca_env`          |
| 13  | DevCenter Project                                    | `azurerm_dev_center_project`                             | Project RG       | `devbox_project`   |
| 14  | Dev Box Pool                                         | `azurerm_dev_center_project_pool`                        | Project RG       | `devbox_project`   |
| 15  | Network Connection                                   | `azurerm_dev_center_network_connection`                  | Project RG       | `devbox_project`   |
| 16  | Dev Box ロール割り当て                               | `azurerm_role_assignment`                                | Project RG       | `devbox_project`   |
| 17  | ACA ジョブ（GitHub ランナーまたは ADO エージェント） | `azurerm_container_app_job`                              | Project RG       | `runner`           |
| 18  | ランナーグループ/エージェントプール登録              | `github_actions_runner_group` / `azuredevops_agent_pool` | —                | `runner`           |

**合計: 1 リソースグループ（Project RG）、プロジェクトあたり約 18 リソース。**

### サブモジュール

| サブモジュール     | 責務                                                                          | プラットフォーム非依存? | ステータス |
| ------------------ | ----------------------------------------------------------------------------- | ----------------------- | ---------- |
| `project_state`    | Layer 2 Storage Account + プロジェクト Key Vault + プロジェクト RG            | はい                    | 新規       |
| `project_identity` | 7 UAMI + OIDC フェデレーション資格情報 + サブスクリプション RBAC              | はい                    | 新規       |
| `project_network`  | サブネットスライス（platform モード）または BYO VNet 検証                     | はい                    | 新規       |
| `aca_env`          | プロジェクトのネットワークコンテキストにバインドされた ACA Environment        | はい                    | 既存       |
| `devbox_project`   | DevCenter Project + Dev Box Pool + Network Connection                         | はい                    | 新規       |
| `runner`           | GitHub ランナーグループまたは ADO エージェントプールに登録する ACA ジョブ定義 | いいえ（ディスパッチ）  | 新規       |

### `project_state`

プロジェクトごとの状態インフラを作成。

**デプロイされるリソース:**

| リソース                           | Terraform タイプ                                | 目的                                                                                               |
| ---------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| プロジェクト リソースグループ      | `azurerm_resource_group`                        | 全プロジェクト所有リソース（state、ID、シークレット）をプラットフォームサブスクリプション内に格納  |
| Layer 2 Storage Account            | `azurerm_storage_account`                       | プロジェクトチームのアプリ IaC 用 Layer 2 tfstate を格納（LRS デフォルト、レプリケーション選択可） |
| Layer 2 blob コンテナ              | `azurerm_storage_container`                     | プロジェクトチーム用のワークスペースごとの tfstate コンテナ                                        |
| プロジェクト Key Vault             | `azurerm_key_vault`                             | プロジェクト所有のシークレットとキー（ブートストラップ KV とは別）                                 |
| Layer 2 プライベートエンドポイント | `azurerm_private_endpoint`                      | プロジェクトのランナーネットワークから Layer 2 SA へのプライベート接続                             |
| Layer 2 PE DNS ゾーンリンク        | `azurerm_private_dns_zone_virtual_network_link` | PE 解決のためにプロジェクトの VNet をプラットフォーム DNS ゾーンにリンク                           |

### `project_identity`

**プロジェクト RG 内** に 7 つのプロジェクトスコープ UAMI を作成。

**デプロイされるリソース:**

| リソース                           | Terraform タイプ                        | 目的                                                                                                                      |
| ---------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| 7 プロジェクト UAMI                | `azurerm_user_assigned_identity`        | 環境ごと・ジョブタイプごとの ID: `feat-plan`、`dev-plan`、`stg-plan`、`prod-plan`、`dev-apply`、`stg-apply`、`prod-apply` |
| OIDC フェデレーション資格情報 (×7) | `azurerm_federated_identity_credential` | VCS 環境が (env × job) ごとに Azure トークンを発行できるよう信頼                                                          |
| サブスクリプションロール割り当て   | `azurerm_role_assignment`               | 環境サブスクリプションへの条件付き RBAC（サブスクリプションが宣言されている場合のみ）                                     |

> [!NOTE]
> すべての UAMI はプロジェクト RG（Layer 2）に作成される。組織レベルの Identity RG は使用しない。
> これによりプロジェクトが自己完結的になり、Layer 2 が Layer 1 のリソースグループへの書き込みアクセスを必要としない。
> プロジェクト RG を削除するとすべてのプロジェクト所有 ID もクリーンに削除される。

各 UAMI には以下が付与される:

- OIDC フェデレーション資格情報（VCS 環境にバインド）
- 条件付きサブスクリプション RBAC（サブスクリプションが宣言されている場合のみ）

### `project_network`

プロジェクトの DevOps ネットワークコンテキストを処理。

**デプロイされるリソース（platform モード）:**

| リソース                    | Terraform タイプ       | 目的                                                        |
| --------------------------- | ---------------------- | ----------------------------------------------------------- |
| プロジェクト ACA サブネット | `azurerm_subnet`       | 共有プラットフォーム LZ VNet 内のプロジェクト専用サブネット |
| サブネット委任（ACA）       | サブネット委任ブロック | サブネットを `Microsoft.App/environments` に委任            |

**デプロイされるリソース（BYO モード）:**

| リソース                | Terraform タイプ | 目的                                                  |
| ----------------------- | ---------------- | ----------------------------------------------------- |
| _(作成なし — 検証のみ)_ | data ソース      | 外部提供の VNet/サブネットを 7 つの一貫性ルールで検証 |

### `aca_env`

プロジェクトスコープの ACA Environment を作成。

**デプロイされるリソース:**

| リソース                         | Terraform タイプ                                | 目的                                                         |
| -------------------------------- | ----------------------------------------------- | ------------------------------------------------------------ |
| ACA Environment                  | `azurerm_container_app_environment`             | プロジェクトのネットワークコンテキストでランナージョブを実行 |
| ACA Environment DNS ゾーンリンク | `azurerm_private_dns_zone_virtual_network_link` | ACA 内部 DNS をプロジェクトの VNet にリンク                  |

### `devbox_project`

DevCenter プロジェクトリソースを作成。

**デプロイされるリソース:**

| リソース               | Terraform タイプ                        | 目的                                                                          |
| ---------------------- | --------------------------------------- | ----------------------------------------------------------------------------- |
| DevCenter Project      | `azurerm_dev_center_project`            | プロジェクトスコープの Dev Box カタログ参照（組織レベル Dev Center にリンク） |
| Dev Box Pool           | `azurerm_dev_center_project_pool`       | プロジェクト開発者の Dev Box 用プール                                         |
| Network Connection     | `azurerm_dev_center_network_connection` | プールをプロジェクトのランナーネットワークコンテキストにバインド              |
| Dev Box ロール割り当て | `azurerm_role_assignment`               | プロジェクトチームに Dev Box のプロビジョニング・管理権限を付与               |

### `runner` — 抽象モジュール

CI/CD ランナー登録用の抽象モジュール。

**デプロイされるリソース（GitHub）:**

| リソース                       | Terraform タイプ              | 目的                                                          |
| ------------------------------ | ----------------------------- | ------------------------------------------------------------- |
| ACA ジョブ（GitHub ランナー）  | `azurerm_container_app_job`   | 共有 ACR からイメージを取得するセルフホステッドランナージョブ |
| ランナーグループメンバーシップ | `github_actions_runner_group` | プロジェクトの CI ジョブを専用ランナーグループにルーティング  |

**デプロイされるリソース（Azure DevOps）:**

| リソース                       | Terraform タイプ                 | 目的                                                              |
| ------------------------------ | -------------------------------- | ----------------------------------------------------------------- |
| ACA ジョブ（ADO エージェント） | `azurerm_container_app_job`      | 共有 ACR からイメージを取得するセルフホステッドエージェントジョブ |
| エージェントプール登録         | `azuredevops_agent_pool`（参照） | プロジェクトのパイプラインを専用エージェントプールにルーティング  |

---

## 6. レイヤー 3: リポジトリ LZ サブモジュール (devops-repo-lz)

Repo LZ は個別のリポジトリとその環境をプロビジョニングする。各リポジトリが独自の Terraform 状態を持ち、独立したライフサイクル管理を可能にする。

### Layer 3 — 統合リソース一覧（リポジトリごと）

| #   | リソース                               | Terraform タイプ / プラットフォーム                                              | サブモジュール |
| --- | -------------------------------------- | -------------------------------------------------------------------------------- | -------------- |
| 1   | GitHub リポジトリ / ADO Git リポジトリ | `github_repository` / `azuredevops_git_repository`                               | `project_repo` |
| 2   | ブランチ保護 / ポリシー                | `github_branch_protection_v3` / `azuredevops_branch_policy_*`                    | `project_repo` |
| 3   | GitHub 環境 / ADO 環境 (×N)            | `github_repository_environment` / `azuredevops_environment`                      | `environment`  |
| 4   | デプロイメント保護ルール / 承認 (×N)   | `github_repository_environment_deployment_policy` / `azuredevops_check_approval` | `environment`  |
| 5   | 環境シークレット / サービス接続        | `github_actions_environment_secret` / `azuredevops_serviceendpoint_azurerm`      | `environment`  |
| 6   | ワークフロー YAML / パイプライン定義   | `github_repository_file` / `azuredevops_build_definition`                        | `workflow_gen` |
| 7   | ACA ジョブ（専用ランナー、オプション） | `azurerm_container_app_job`                                                      | `runner`       |

**合計: 0 リソースグループ（VCS API + オプションで Layer 2 の Project RG を使用）、リポジトリあたり約 7+ リソース（N = 環境数）。**

### サブモジュール

| サブモジュール | 責務                                                           | プラットフォーム非依存? | ステータス |
| -------------- | -------------------------------------------------------------- | ----------------------- | ---------- |
| `project_repo` | 抽象: リポジトリ作成 + ブランチ保護                            | いいえ（ディスパッチ）  | 新規       |
| `environment`  | 抽象: 環境作成 + 保護ルール + UAMI バインディング              | いいえ（ディスパッチ）  | 新規       |
| `runner`       | 抽象: リポジトリごとのランナー登録（オプション、専用プール用） | いいえ（ディスパッチ）  | 新規       |
| `workflow_gen` | CI/CD ワークフロー/パイプライン生成（プロファイル駆動）        | いいえ（ディスパッチ）  | 新規       |

### `project_repo` — 抽象モジュール

VCS プラットフォームに関係なく統一インターフェースでリポジトリを作成:

```hcl
module "repo" {
  source       = "./modules/project_repo"
  vcs_provider = var.vcs_provider   # "github" | "azuredevops"

  # 統一入力
  project_name       = var.project_name
  repo_name          = var.repo_name
  visibility         = var.visibility           # "private" | "internal" | "public"
  profile            = var.profile              # "infra" | "app" | "library" | "docs"
  default_branch     = var.default_branch       # "main"
  branch_protection  = var.branch_protection    # ルールオブジェクト
}
```

内部でディスパッチ:

- `modules/project_repo/github.tf` — `github_repository` + `github_branch_protection_v3`
- `modules/project_repo/azuredevops.tf` — `azuredevops_git_repository` + ブランチポリシー

**デプロイされるリソース（GitHub）:**

| リソース          | Terraform タイプ              | 目的                                                     |
| ----------------- | ----------------------------- | -------------------------------------------------------- |
| GitHub リポジトリ | `github_repository`           | 標準ファイルレイアウトのプロジェクトソースリポジトリ     |
| ブランチ保護      | `github_branch_protection_v3` | ブランチ保護ルール（レビュー、ステータスチェック）の適用 |
| リポジトリ設定    | `github_repository` 属性      | 可視性、マージ設定、機能、テンプレート設定               |

**デプロイされるリソース（Azure DevOps）:**

| リソース           | Terraform タイプ              | 目的                                         |
| ------------------ | ----------------------------- | -------------------------------------------- |
| ADO Git リポジトリ | `azuredevops_git_repository`  | プロジェクトのソースリポジトリ               |
| ブランチポリシー   | `azuredevops_branch_policy_*` | ブランチ保護（レビュアー、ビルド検証）の適用 |

**出力:** `repo_id`、`repo_url`、`repo_full_name`

### `environment` — 抽象モジュール

保護ルール付きのデプロイメント環境を作成:

```hcl
module "env" {
  source       = "./modules/environment"
  vcs_provider = var.vcs_provider

  # 統一入力
  project_name     = var.project_name
  repo_name        = var.repo_name
  environment_name = each.key           # "dev", "staging", "prod"
  subscription_id  = each.value.subscription_id
  uami_plan_id     = each.value.uami_plan_id
  uami_apply_id    = each.value.uami_apply_id
  reviewers        = each.value.reviewers       # レビュアーチーム/ユーザー ID リスト
  wait_timer       = each.value.wait_timer      # 分（0 = 待機なし）
}
```

内部でディスパッチ:

- `modules/environment/github.tf` — `github_repository_environment` + デプロイメント保護ルール
- `modules/environment/azuredevops.tf` — `azuredevops_environment` + 承認 + チェック

**デプロイされるリソース（GitHub）:**

| リソース                 | Terraform タイプ                                  | 目的                                                      |
| ------------------------ | ------------------------------------------------- | --------------------------------------------------------- |
| GitHub 環境              | `github_repository_environment`                   | リポジトリにバインドされたデプロイメントターゲット        |
| デプロイメント保護ルール | `github_repository_environment_deployment_policy` | レビュアー要件、待機タイマー、ブランチ制約                |
| 環境シークレット         | `github_actions_environment_secret`               | 環境 UAMI の OIDC クライアント ID とサブスクリプション ID |

**デプロイされるリソース（Azure DevOps）:**

| リソース     | Terraform タイプ                      | 目的                                         |
| ------------ | ------------------------------------- | -------------------------------------------- |
| ADO 環境     | `azuredevops_environment`             | ADO パイプラインのデプロイメントターゲット   |
| 承認チェック | `azuredevops_check_approval`          | デプロイメント前のレビュアー要件             |
| サービス接続 | `azuredevops_serviceendpoint_azurerm` | 環境 UAMI にバインドされた OIDC サービス接続 |

**出力:** `environment_id`、`environment_name`

### `workflow_gen`

プロファイル駆動の CI/CD ワークフローまたはパイプラインファイルを生成。

**デプロイされるリソース（GitHub）:**

| リソース                   | Terraform タイプ         | 目的                                                                   |
| -------------------------- | ------------------------ | ---------------------------------------------------------------------- |
| ワークフロー YAML ファイル | `github_repository_file` | (env × job) マトリクスをターゲットとする標準化 plan/apply ワークフロー |

**デプロイされるリソース（Azure DevOps）:**

| リソース         | Terraform タイプ               | 目的                                                           |
| ---------------- | ------------------------------ | -------------------------------------------------------------- |
| パイプライン定義 | `azuredevops_build_definition` | (env × job) マトリクスをターゲットとする YAML パイプライン定義 |

### `runner`（リポジトリレベル、オプション）

プロジェクトレベルのランナーグループを共有する代わりに専用ランナーが必要なリポジトリ用:

```hcl
module "runner" {
  source       = "./modules/runner"
  vcs_provider = var.vcs_provider

  project_name  = var.project_name
  repo_name     = var.repo_name
  aca_env_id    = var.aca_environment_id
  runner_labels = ["self-hosted", var.project_name, var.repo_name]
}
```

**デプロイされるリソース:** Layer 2 の `runner` モジュールと同一（ACA ジョブ + ランナーグループ/エージェントプール登録）だが、単一リポジトリにスコープ。

---

## 7. 抽象モジュールパターン

すべての抽象（VCS ディスパッチ）モジュールは以下のパターンに従う:

```text
modules/<module_name>/
├── _variables.tf         # 統一入力契約（vcs_provider を含む）
├── _outputs.tf           # 統一出力契約
├── main.tf               # ディスパッチロジック（vcs_provider での count/for_each）
├── github.tf             # GitHub 実装（count = vcs_provider == "github" ? 1 : 0）
└── azuredevops.tf        # ADO 実装（count = vcs_provider == "azuredevops" ? 1 : 0）
```

**主要ルール:**

- 呼び出し側は `_variables.tf` の入力と `_outputs.tf` の出力 **のみ** を見る。
- GitHub 固有および ADO 固有のリソースは `vcs_provider` でゲートされた `count` を使用する。
- サブモジュール内にプロバイダーブロックなし — プロバイダーはルートモジュールから渡される。
- 出力値は統一: 例えば `repo_id` は作成されたものに応じて GitHub リポジトリ ID または ADO リポジトリ ID を返す。

---

## 8. モジュール構成図

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ bootstrap (Layer 0 ルートモジュール — 組織ごとに 1 つ)                    │
│                                                                         │
│  ┌──────────┐                                                           │
│  │bootstrap │                                                           │
│  └──────────┘                                                           │
└─────────────────────────────────────────────────────────────────────────┘
                              │ bootstrap.config.json
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-org-lz (Layer 1 ルートモジュール)                                  │
│                                                                         │
│  ┌──────┐ ┌─────┐ ┌───────────────┐ ┌──────────┐                      │
│  │ vnet │ │ acr │ │org_governance │ │devcenter │                      │
│  └──────┘ └─────┘ └───────────────┘ └──────────┘                      │
└─────────────────────────────────────────────────────────────────────────┘
                              │ remote_state
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-project-lz (Layer 2 ルートモジュール — プロジェクトごとに 1 つ)    │
│                                                                         │
│  ┌─────────────┐ ┌────────────────┐ ┌───────────────┐ ┌─────────────┐ │
│  │project_state│ │project_identity│ │project_network│ │   aca_env   │ │
│  └─────────────┘ └────────────────┘ └───────────────┘ └─────────────┘ │
│  ┌──────────────┐ ┌────────────────┐                                   │
│  │devbox_project│ │    runner      │                                    │
│  └──────────────┘ └────────────────┘                                   │
└─────────────────────────────────────────────────────────────────────────┘
                              │ remote_state
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ devops-repo-lz (Layer 3 ルートモジュール — リポジトリごとに 1 つ)         │
│                                                                         │
│  ┌────────────┐ ┌─────────────┐ ┌────────────┐ ┌────────────────────┐ │
│  │project_repo│ │ environment │ │workflow_gen│ │ runner (オプション) │ │
│  └────────────┘ └─────────────┘ └────────────┘ └────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 実装計画

### フェーズ 1 — プラットフォーム非依存のプロジェクトサブモジュール

| 優先度 | モジュール         | 依存関係                    |
| ------ | ------------------ | --------------------------- |
| 1      | `project_state`    | なし（純粋な Azure）        |
| 2      | `project_identity` | なし（純粋な Azure）        |
| 3      | `project_network`  | Org LZ VNet 出力            |
| 4      | `aca_env`          | `project_network`           |
| 5      | `devbox_project`   | `project_network`           |
| 6      | `runner`           | `aca_env`、VCS コンテキスト |

### フェーズ 2 — 抽象リポジトリ/環境サブモジュール

| 優先度 | モジュール     | 依存関係                                  |
| ------ | -------------- | ----------------------------------------- |
| 1      | `project_repo` | VCS プロバイダー設定                      |
| 2      | `environment`  | `project_identity`（UAMI）                |
| 3      | `runner`       | `aca_env`（リポジトリレベル、オプション） |

### フェーズ 3 — 組織レベルガバナンス

| 優先度 | モジュール       | 依存関係             |
| ------ | ---------------- | -------------------- |
| 1      | `org_governance` | VCS プロバイダー設定 |

### 順序

1. まず `project_state` + `project_identity` + `project_network` を実装（純粋な Azure、VCS 依存なし）。
2. `aca_env` + `devbox_project` + `runner` を実装（プロジェクトレベルのコンピュート）。
3. `project_repo` + `environment` を実装（Layer 3 用の抽象 VCS モジュール）。
4. `org_governance` を実装（Layer 1 用の抽象ガバナンス）。
5. ルートモジュール（`project_github`、`project_azuredevops`、`repo_github`、`repo_azuredevops`）に合成。

---

> **関連ドキュメント:**
>
> - [ターゲットアーキテクチャ仕様書](./Target-Architecture-Spec.ja.md) — アーキテクチャ全体の概要
> - [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md) — リソーススコーピングの決定
> - [ADR-003](./adr/ADR-003-project-multi-repo-model.ja.md) — プロジェクトモデルと ID
> - [ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md) — GitHub/ADO 抽象化
