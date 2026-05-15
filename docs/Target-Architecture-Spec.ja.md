# ターゲットアーキテクチャ仕様書 (DRAFT)

[English](./Target-Architecture-Spec.md) | [日本語](./Target-Architecture-Spec.ja.md)

> **ステータス:** ドラフト — 計画フェーズ（ターゲットアーキテクチャ定義）。
>
> **主目的:** DevOps Landing Zone の正しい **Organization → Project → Repository → Environment（Org-Project-Repo-Env）** リソース階層を定義し精緻化する。本ドキュメントのすべてのギャップ、目標、設計決定は、この階層を Azure リソース、VCS プラットフォーム（GitHub / Azure DevOps）、および Terraform 状態管理に正しくマッピングするために存在する。
>
> **スコープ:** Org-Project-Repo-Env 階層に基づき、DevOps Landing Zone を再設計する。各レイヤーでリソースを正しくスコープする — 組織レベルの共有インフラ、プロジェクトレベルの分離、リポジトリレベルの CI/CD ワークフロー、環境レベルの ID とデプロイターゲット。
>
> **読み方ガイド:** 本ドキュメントはアーキテクチャの概要（現状、ギャップ、ターゲットゴール、リソーステーブル、モジュール構造、移行パス）をカバーします。詳細な設計決定は個別の [アーキテクチャ決定記録 (ADR)](#アーキテクチャ決定記録-adr) に記載されています — トピック領域ごとに 1 つの ADR があります。

---

## 目次

1. [動機と課題の概要](#1-動機と課題の概要)
2. [ターゲット階層と用語](#2-ターゲット階層と用語)
3. [ブートストラップと状態管理（4 層デプロイメント）](#3-ブートストラップと状態管理4-層デプロイメント)
4. [モジュールとディレクトリ構造（ターゲット）](#4-モジュールとディレクトリ構造ターゲット)
5. [アーキテクチャ決定記録 (ADR)](#アーキテクチャ決定記録-adr)
6. [現行設計からの移行パス](#6-現行設計からの移行パス)
7. [決定ログ（解決済みの質問）](#7-決定ログ解決済みの質問)

---

## 1. 動機と課題の概要

### 主目的: Org-Project-Repo-Env 階層の定義

本ドキュメントの主目的は、DevOps Landing Zone の正しい **Organization → Project → Repository → Environment（Org-Project-Repo-Env）リソース階層を定義し精緻化する** ことである。この階層の各レイヤーには明確な責務がある:

| レイヤー             | 責務                                                                                               | Terraform スコープ                                   |
| -------------------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| **ブートストラップ** | 基盤となる状態バックエンド（Layer 1 SA + KV + CMK + UAMI）— 一度適用、ほとんど変更なし             | `bootstrap` (Layer 0)                                |
| **組織**             | すべてのプロジェクトで使用する共有インフラとガバナンス（ACR、Dev Center、VNet、DNS、ルールセット） | `devops-org-lz` (Layer 1)                            |
| **プロジェクト**     | リポジトリ、ID、ランナー、ネットワークコンテキストの論理グループ化（1 つの製品/ワークロード向け）  | `devops-project-lz` (Layer 2)                        |
| **リポジトリ**       | プロファイル駆動の CI/CD ワークフローとオプションのリポジトリ別 ID を持つ個別の Git リポジトリ     | `devops-repo-lz` (Layer 3)                           |
| **環境**             | Azure サブスクリプション、UAMI、GitHub/ADO 環境と 1:1 でマッピングされるデプロイターゲット         | `devops-repo-lz` (Layer 3、リポジトリコンテキスト内) |

以降で特定されるすべてのギャップ、すべてのゴール、すべての設計決定は、リソースがこの階層の **正しいレイヤーにスコープされる** ことを確実にするために存在する。

### 現状とギャップ（階層レイヤー別分析）

| 階層レイヤー     | 領域                            | 現在の状態                                                                                                           | ギャップ（階層違反または不足する機能）                                                                                                                                                                                                                                                                       |
| ---------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **組織**         | 組織ガバナンス                  | GitHub 組織名が文字列として渡されるのみで、ガバナンス境界がない                                                      | 組織レベルのルールセット、ランナーグループ、リポジトリデフォルトが未定義。ガバナンスはプロジェクトレベルで個別管理されている。                                                                                                                                                                               |
| **組織**         | ACA Environment スコープ        | ACA Environment はプラットフォーム LZ レベルで作成                                                                   | ACA Environment はプロジェクトスコープであるべき。[ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md) 参照。                                                                                                                                                                                         |
| **組織**         | ID リソースグループ             | プラットフォーム LZ で空の RG が作成される                                                                           | RG のみのデプロイは妥当 — プロジェクト UAMI の共有コンテナーとして機能する。正しいことを確認済み。[ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md) 参照。                                                                                                                                         |
| **組織**         | 共有エージェントリソース        | ACR、Log Analytics、コンテナー実行 UAMI がプラットフォームレベルに配置                                               | 正しくスコープされている。すべてのプロジェクトで利用される。                                                                                                                                                                                                                                                 |
| **組織**         | Dev Center                      | Dev Center と定義がプラットフォームレベルに配置                                                                      | 正しくスコープされている。DevBox プロジェクトプールは組織レベルの Dev Center を参照してプロジェクトごとに作成される。                                                                                                                                                                                        |
| **プロジェクト** | プロジェクトモデル              | 1 プロジェクト = 1 メインリポ + オプションのテンプレートリポ                                                         | 実際のプロジェクトでは複数のリポジトリ（infra、app、data、ops、共有ライブラリ）が必要。マルチリポジトリ未サポート。                                                                                                                                                                                          |
| **プロジェクト** | ネットワーク / VNet             | プラットフォームが常にアドレスプレフィックスから新しい VNet を作成                                                   | プロジェクトレベルで既存の（企業提供の）VNet に接続するオプションがない。セルフホステッドランナーはプロジェクトの VNet に配置する必要がある。                                                                                                                                                                |
| **プロジェクト** | Layer 2 状態ストレージ          | プロジェクトが Layer 1 Storage Account 内に Blob コンテナーを作成                                                    | プロジェクト別の Storage Account（LRS デフォルト、レプリケーション選択可）をプラットフォームサブスクリプション内のプロジェクトスコープ RG に配置。プロジェクト所有の Key Vault も同 RG に含む。§3.2 参照。                                                                                                   |
| **プロジェクト** | Azure DevOps モジュール         | コードベースに `project_azuredevops` ルートモジュールが存在しない                                                    | `project_github` のみ存在。`project_azuredevops` は同じインターフェースを実装する（[ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md)）。                                                                                                                                                                 |
| **リポジトリ**   | リポ → ワークフロー対応         | 単一リポジトリが固定のワークフローセットを取得                                                                       | リポジトリプロファイルの概念がない。目的（infra vs app vs library）に関係なくすべてのリポに同じ CI/CD 形状が適用される。                                                                                                                                                                                     |
| **リポジトリ**   | リポジトリ別 ID                 | 1 セットの UAMI がプロジェクト単位（リポ間で共有）                                                                   | リポジトリ別の UAMI による細粒度 RBAC のオプションがない（例: infra リポは Contributor、app リポは AcrPush のみ）。                                                                                                                                                                                          |
| **環境**         | 環境 → サブスクリプション対応   | サブスクリプション変数は柔軟（`default = {}`）; サブスクリプションレベルのロール割り当ては `lookup()` による条件付き | ターゲット: `subscriptions` マップに存在する環境のみに対して GitHub 環境、UAMI、フェデレーション資格情報を作成する。サブスクリプションレベルのロール割り当ては欠落エントリに対してスキップされる。                                                                                                           |
| **環境**         | ID 戦略                         | UAMI が環境 × ジョブタイプごとに作成される                                                                           | 戦略は [ADR-003](./adr/ADR-003-project-multi-repo-model.ja.md) で明確にドキュメント化された（UAMI はプロジェクトスコープで、組織レベルの Identity RG 内に Tier 2 で作成される。LZ にはグローバルなサブスクリプションレジストリは存在しない）。リポジトリ別 UAMI 分離はターゲット（上記リポジトリ行を参照）。 |
| **横断**         | ブートストラップ状態            | 単一のブートストラップが tfstate 用の Storage Account と Key Vault を作成                                            | 2 層モデル: Layer 1 はプラットフォーム状態、Layer 2 はプロジェクト別 SA（LRS デフォルト、レプリケーション選択可）をプラットフォームサブスクリプション内のプロジェクトスコープ RG に配置。                                                                                                                    |
| **横断**         | GitHub vs Azure DevOps          | 個別のコードパスで統一的な抽象化がない                                                                               | GitHub には Azure DevOps のような「プロジェクト」概念がなく、両者で一貫したガバナンスモデルがない。                                                                                                                                                                                                          |
| **横断**         | ポートフォリオ オンボーディング | 各プロジェクトが個別の `terraform apply` でプロビジョニング                                                          | セルフサービスや GitOps 駆動のオンボーディングパターンがない。                                                                                                                                                                                                                                               |
| **横断**         | ドキュメント                    | パスが `infra/terraform/…` を参照しているが、コードは `infra/…` 配下にある                                           | 導入者にとって混乱を招く。                                                                                                                                                                                                                                                                                   |

### ゴール（正しい Org-Project-Repo-Env 階層を達成するために）

1. **組織 → プラットフォーム LZ → プロジェクト → リポジトリセット → 環境** の明確な階層を定義し、各リソースをその階層の正しいレイヤーにスコープする。
2. **2 層状態管理** モデルを導入する: Layer 1 はプラットフォーム/DevOps LZ 状態用、Layer 2 はプロジェクトごとのアプリケーション IaC 状態用（プロジェクトプロビジョニング時に独立した Storage Account として作成）。
3. プロジェクトが異なるプロファイルを持つ **複数のリポジトリ** を所有できるようにし、単一リポジトリも有効なオプションとして維持する。
4. GitHub（プロジェクト概念なし）と Azure DevOps（Org → Project → Repos）の両方に対応する **統一抽象化レイヤー** を設計する。
5. プロジェクトレベルで **「Bring Your Own VNet」** をサポートし、セルフホステッドランナーをプロジェクトの VNet に配置する。
6. **ACA Environment** を組織レベルからプロジェクトレベルに移動し、ランナーコンピュートが正しいネットワークコンテキストで動作するようにする。
7. プラットフォーム非依存のガバナンス変数で GitHub と Azure DevOps の両方の **組織レベルガバナンス** を強化する。
8. **GitOps 駆動のプロジェクト/リポジトリ オンボーディング** パターン（Issue → PR → プロビジョニング）を提供する。
9. **ID とサブスクリプションマッピング** 戦略を明確にする — UAMI はプロジェクトスコープ、サブスクリプションはプロジェクトごとに宣言、オプションでリポジトリ別 ID 分離。
10. `project_github` とのパリティを達成する `project_azuredevops` ルートモジュールを提供する。
11. V1 ユーザーが再設計された V2 アーキテクチャを採用するための簡単な移行ガイドを提供する。

### アーキテクチャゴール（ターゲット全体像）

> **このサブセクションの目的。** ドキュメントの残りが現状（as-is）、ギャップ、目指す姿（to-be）、各ギャップの解消方法を詳述する前に、本サブセクションでは**到達点**を要約し、ターゲットアーキテクチャを念頭に置いて読み進められるようにします。各項目は括弧内で参照するセクションで実現されます。ここで新しい設計判断を導入するものではありません。

**1. 4 層のリソース階層 — Organization → Project → Repository → Environment**（§2）

- **Organization（Platform LZ, `devops-org-lz`）** — 組織全体で共有されるインフラ: ブートストラップ Storage Account（Layer 1 状態）、ACR、Log Analytics、container-run UAMI、Platform VNet、Private DNS ゾーン、Dev Center、コンテナイメージビルドタスク。
- **Project（`devops-project-lz`）** — チーム所有と課金分離の単位。プロジェクト固有の UAMI、OIDC 認証情報、Layer 2 状態 Storage Account、ACA Environment、Project DevOps ネットワークコンテキスト（`platform` モードでは共有 Platform LZ VNet 内のプロジェクト専用サブネット、`byo` モードでは BYO VNet）、DevBox プールを所有。
- **Repository（`devops-repo-lz`）** — プロジェクトごとに 1 つ以上のリポジトリ。各リポジトリは CI/CD プロファイル（例: `terraform-env`、`container-image`）に従う。独自の Terraform 状態を持つ個別の apply としてプロビジョニングされる。
- **Environment** — GitHub/ADO 環境と Azure サブスクリプション + plan/apply UAMI ペアとの 1:1 対応。環境は宣言的で、{features, development, staging, production} のサブセットを許可。`devops-repo-lz` レイヤーの一部としてプロビジョニングされる。

**2. 2 層状態管理**（§3.2）

- **Layer 1 — プラットフォーム状態**（bootstrap で作成される単一 Storage Account）: bootstrap、Platform LZ、プロジェクトプロビジョニング（`project_github` / `project_azuredevops`）の tfstate を保存。
- **Layer 2 — プロジェクトごとのアプリケーション状態**（プロジェクトプロビジョニング時に作成されるプロジェクトごとの Storage Account）: プロジェクトチーム自身のアプリ IaC（ワークロード VNet、AKS、アプリリソース等）の tfstate を保存。Layer 2 はプロジェクトが完全所有し、Project DevOps ネットワークコンテキストからプライベートエンドポイント経由で到達。

**3. 3 層 VNet モデル**（[ADR-005](./adr/ADR-005-vnet-architecture.ja.md)）

- **Platform LZ VNet**（組織スコープ、`devops-org-lz`）— ブートストラップ SA/KV のプライベートエンドポイント、NAT エグレス、共有 DNS ゾーン。
- **Project DevOps ネットワークコンテキスト**（プロジェクトスコープ: `platform` モードでは共有 Platform LZ VNet 内のプロジェクト専用サブネット、`byo` モードでは BYO VNet）— ランナー ACA Environment、Layer 2 tfstate プライベートエンドポイント、DevBox プールをホスト。
- **Application / Workload VNet**（環境ごと、プロジェクトチーム自身の IaC が所有）— 実際のアプリワークロードのデプロイ先。プロジェクトの DevOps ネットワークコンテキストと Application VNet 間のピアリングはエンタープライズ hub-and-spoke の関心事であり、**LZ では作成しない**。

**4. セルフホステッドランナー向けのプロジェクトスコープ ACA Environment**（[ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md)）

- ACA Environment は**プロジェクトモジュール**により作成され、プロジェクトの DevOps ネットワークコンテキストのサブネットにバインドされる。ACA Environment は厳密に 1 つの VNet にバインドされるため、BYO VNet プロジェクトを共有プラットフォーム側から提供することは構造上不可能。
- Platform LZ は引き続き共有前提リソース（ACR、Log Analytics、container-run UAMI、コンテナイメージビルドタスク、Private DNS ゾーン）を提供。

**5. ID とサブスクリプションマッピング**（[ADR-003](./adr/ADR-003-project-multi-repo-model.ja.md)、[ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md)）

- 各プロジェクトはプロジェクト作成時に **7 つの UAMI** を取得: `feat-plan`、`dev-plan`、`stg-plan`、`prod-plan`、`dev-apply`、`stg-apply`、`prod-apply`。全 UAMI は組織レベルの Identity RG（中央集約された RBAC と発見性）に置かれるが、命名とライフサイクルはプロジェクトスコープ。
- サブスクリプションはプロジェクトごとに宣言。サブスクリプションに対するロール割当はサブスクリプション存在時の条件付きのため、プロジェクトは環境のサブセットを選択可能。
- OIDC フェデレーション認証情報が各 UAMI を対応する GitHub 環境 / ADO サービス接続に紐付ける。

**6. GitHub / Azure DevOps の統一抽象化**（[ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md)）

- DevOps LZ "Project" はプラットフォーム非依存の概念。GitHub では Project は命名プレフィックス + リポジトリセット + 7 UAMI。Azure DevOps では Project は `azuredevops_project` に 1:1 対応。ガバナンス変数（ルールセット、ランナーグループ、リポジトリデフォルト）は一度定義し、各プラットフォームで正しいプリミティブに適用。

**7. 組織レベルのガバナンス**（[ADR-006](./adr/ADR-006-organization-governance.ja.md)）

- プラットフォーム非依存のガバナンス入力が GitHub ルールセット + ランナーグループ + リポジトリデフォルト、および Azure DevOps ブランチポリシー + エージェントプール + プロジェクト設定を駆動し、両プラットフォームが同一の宣言的ソースからガバナンスパリティに到達。

**8. GitOps 駆動のプロジェクト / リポジトリ オンボーディング**（[ADR-007](./adr/ADR-007-gitops-onboarding.ja.md)）

- 新規プロジェクトおよびリポジトリはガバナンスリポジトリ経由で要求される（Issue → YAML PR → 自動 `project_*` apply）。これにより Platform LZ とプロジェクトチームの相互作用は監査可能かつレビュー可能になる。

**9. 意図的な 2 つのネットワークモード — `platform` と `byo` — および整合性ルール**（[ADR-005](./adr/ADR-005-vnet-architecture.ja.md)）

- `network_mode = "platform"` は、まだエンタープライズスポーク VNet を所有していないプロジェクト向けの**低摩擦のデフォルト**である。Platform LZ が組織プロビジョニング時に VNet、NAT 送信、Private DNS ゾーン、ブートストラップ Private Endpoint を一度だけ事前配置し、プロジェクトは LZ 出力を介してプロジェクト専用のサブネットスライスを消費する。7 つの BYO 整合性ルールはすべて構造上自動的に満たされ、プロジェクトチームのピアリング作業や DNS リンク作業は不要である。
- `network_mode = "byo"` は、事前にプロビジョニングされたハブ＆スポークのスポーク（企業ファイアウォール、DNS 転送、アドレス計画ガバナンス）に配置する必要があるプロジェクト向けの**エンタープライズ統合モード**である。プロジェクトは既存の VNet/サブネット ID を提供し、Platform LZ VNet との 7 つの整合性ルール（Private DNS ゾーンリンク、ピアリング経由でのブートストラップ SA/KV 到達性、ACR pull 経路、ACA サブネット委任、アドレス空間非重複、split-horizon DNS 分離、環境間 VNet 一貫性）を満たす必要がある。
- 両モードは第一級かつ補完的である — `platform` モードは**バックワード互換のために残されているのではない**（理由は [ADR-005](./adr/ADR-005-vnet-architecture.ja.md) を参照）。プロジェクトは `platform` モードで開始し、後にプロジェクトモジュール契約を変更せずに `byo` へ移行することもできる。

**10. `project_github` とパリティの `project_azuredevops`**（[ADR-003](./adr/ADR-003-project-multi-repo-model.ja.md)、[ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md)）

- Azure DevOps ルートモジュールは、`project_github` と同じ Project → Repo → Environment 契約、同じ 7-UAMI ID モデル、同じ Layer 2 状態ストレージ、同じ ACA Environment バインドを提供する。

> **ドキュメントの残りの読み方。** §2–§3 で階層と状態レイヤーを定義; §4 でターゲットのモジュール構成を示します。詳細な設計決定は個別の ADR ドキュメントに記載されています（以下の [ADR インデックス](#アーキテクチャ決定記録-adr) を参照）。§6 で移行パス、§7 で決定ログを示します。

### アーキテクチャ図（ターゲット全体像）

> **このサブセクションの目的。** 以下の 3 つの図は、上記のアーキテクチャゴールを可視化し、as-is / ギャップ / to-be の議論に入る前に行き先を一目で示すためのものである。これらは**ターゲット**状態を示しており、現在のコードではない — 各トピックの詳細な設計は ADR ドキュメントに記載されています。

#### 図 1 — Org-Project-Repo-Env 階層 + 2 層状態管理（ゴール 1, 2, 5, 6, 7）

4 層リソース階層と、どのレイヤがどの tfstate を所有するか（Layer 1 プラットフォーム vs. Layer 2 プロジェクト別）、および GitHub と Azure DevOps を横断するプラットフォーム非依存の Project 抽象を示す。

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ ORGANIZATION  (GitHub Org │ Azure DevOps Org)                              │
│                                                                             │
│  ┌─ Bootstrap (infra/bootstrap) ─────────────────────────────────────────┐ │
│  │  Layer 1 Storage Account  ◄── tfstate: bootstrap, LZ, project, repo   │ │
│  │  Bootstrap Key Vault       (VCS PATs)                                 │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                  │                                          │
│  ┌─ Platform LZ (devops-org-lz) ──────▼──── Tier 1 ──────────────────────┐ │
│  │  ACR  •  Log Analytics  •  container-run UAMI                         │ │
│  │  Identity RG (org container for project UAMIs)                        │ │
│  │  Platform VNet  •  Private DNS zones  •  NAT  •  Dev Center           │ │
│  │  Org-level governance (rulesets / runner groups / agent pools)         │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                  │ remote_state outputs                     │
│        ┌─────────────────────────┴────────────────────────┐                 │
│        ▼                                                  ▼                 │
│  ┌─ PROJECT A (devops-project-lz) ── Tier 2 ─┐   ┌─ PROJECT B ────────────┐│
│  │  7 UAMIs  (feat-plan, dev/stg/prod        │   │  7 UAMIs (same shape)  ││
│  │           plan+apply)                      │   │  Layer 2 SA            ││
│  │  Layer 2 Storage Account ◄── app tfstate   │   │  ACA Environment       ││
│  │  ACA Environment (project runner context)  │   │  DevBox project pool   ││
│  │  Project network (platform or BYO)         │   │                        ││
│  │  DevBox project pool + Network Connection  │   │                        ││
│  └───────────────────┬────────────────────────┘   └────────────┬───────────┘│
│                      │ remote_state outputs                     │            │
│        ┌─────────────┴──────────────────┐          ┌───────────┴──────┐     │
│        ▼                                ▼          ▼                  ▼     │
│  ┌─ REPO: repo-infra ── Tier 3 ─┐ ┌─ REPO: repo-app ─┐  ┌─ REPO ────────┐│
│  │  GitHub/ADO repo              │ │  GitHub/ADO repo  │  │  ADO repo     ││
│  │  profile = infra              │ │  profile = app    │  │  profile=infra││
│  │  CI/CD workflows              │ │  CI/CD workflows  │  │               ││
│  │  ┌─ ENVIRONMENTS ──────────┐ │ │  ┌─ ENVS ──────┐ │  │  ┌─ ENVS ───┐ ││
│  │  │  dev → sub-dev (UAMIs)  │ │ │  │  dev → ...  │ │  │  │  dev     │ ││
│  │  │  stg → sub-stg (UAMIs)  │ │ │  │  prod → ... │ │  │  │  prod    │ ││
│  │  │  prod → sub-prod (UAMIs)│ │ │  └─────────────┘ │  │  └──────────┘ ││
│  │  └─────────────────────────┘ │ └──────────────────┘  └────────────────┘│
│  └───────────────────────────────┘                                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 図 2 — 3 層 VNet モデル + BYO 整合性ルール（ゴール 3, 9）

3 つの VNet 層、それぞれの所有者、および BYO プロジェクト VNet が Platform LZ VNet に対して満たすべき整合性契約を示す。

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ TIER 1 — Platform LZ VNet  (組織スコープ, devops/lz)                        │
│  • Private endpoints: bootstrap SA, bootstrap KV                           │
│  • Private DNS zones (linked to project VNets)                             │
│  • NAT egress                                                              │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ peering + DNS-zone link
                                   │ (7 つの整合性ルール — §8.0.1)
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
                     │ hub-and-spoke ピアリング (LZ では作成しない — §8.0.2)
                     ▼                                      ▼
┌─ TIER 3 — Application / Workload VNet (環境ごと、プロジェクトの IaC が所有)─┐
│  • プロジェクト独自の Layer 2 Terraform で所有・デプロイされる              │
│  • AKS / App Service / VM / DB / アプリの private endpoint をホスト         │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 図 3 — プロジェクトモジュール構成（ゴール 4, 5, 8, 10）

単一のプロジェクトモジュールが apply 時にデプロイするリソース、Platform LZ 出力の消費方法、および GitOps オンボーディングリポジトリがプロビジョニングを駆動する流れを示す。これは、プロジェクトスコープ ACA Environment ゴール（[ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md)）のプロジェクト視点である。

```text
                ┌──────────────────────────────────┐
                │ GitOps オンボーディングリポ (§10) │
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
│  プロジェクトスコープの Azure リソース ─────────────────────────────────┐   │
│  ┌─────────────────────────┐  ┌──────────────────────────────────────┐ │   │
│  │ Identity (org RG 内)    │  │ Layer 2 Storage Account              │ │   │
│  │  7 UAMIs:               │  │  • app-tfstate container             │ │   │
│  │   feat-plan             │  │  • ランナーネットワークコンテキスト内 │ │   │
│  │   dev/stg/prod plan     │  │    の private endpoint               │ │   │
│  │   dev/stg/prod apply    │  │  • platform DNS zone へのリンク      │ │   │
│  └─────────────────────────┘  └──────────────────────────────────────┘ │   │
│  ┌─────────────────────────┐  ┌──────────────────────────────────────┐ │   │
│  │  + OIDC fed creds       │  │ ACA Environment (プロジェクトスコープ)│ │   │
│  └─────────────────────────┘  │  • プロジェクトのランナーネットワーク │ │   │
│  ┌─────────────────────────┐  │    コンテキストにバインド            │ │   │
│  │ サブスクリプション RBAC │  │  • 共有 ACR イメージから Jobs を実行 │ │   │
│  │  env 別（条件付き）     │  │  • ログ → 共有 Log Analytics         │ │   │
│  └─────────────────────────┘  └──────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  VCS スコープのリソース（プラットフォーム別）──────────────────────────┐   │
│  • Repositories（profile 駆動のワークフローファイル付き）               │   │
│  • Environments × {features, dev, staging, prod} ↔ サブスクリプション   │   │
│  • UAMI への OIDC 信頼  • プロジェクト別 runner / agent group 参照      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### レイヤー別リソース一覧（ターゲットアーキテクチャ）

以下のテーブルは、DevOps Landing Zone がプロビジョニングする Azure / VCS リソースを、所有するレイヤーごとに列挙したものです。各テーブルは「**そのリソースは何で、何のためか**」を明示します。これはセクション 1 のアーキテクチャゴールが参照し、セクション 3〜10 で詳細化される、リソース単位の確定的な定義です。

#### テーブル A — ルートブートストラップ層 (`infra/bootstrap/`、現在 `infra/_bootstrap/`)

DevOps プラットフォーム自体の管理に必要なリソース（Layer 1 tfstate バックエンドとその保護）のみをプロビジョニングします。組織ごとに 1 回、Platform LZ の前に実行します。状態は最初オペレーターのワークステーションに保存され、その後生成された Platform Storage Account に移行されます。

| リソース                                             | 何か                                                            | 何のため                                                                                                               |
| ---------------------------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Bootstrap Resource Group                             | すべての bootstrap リソースを格納する Azure リソースグループ    | Layer 1 backend Storage Account、Key Vault、CMK identity の格納先。tfstate バックエンドのライフサイクルアンカー        |
| Layer 1 Storage Account (tfbackend)                  | Blob バージョニング + 不変性付き Azure Storage Account          | `bootstrap`, `devops-org-lz`, `devops-project-lz/project_github` / `project_azuredevops` の **Layer 1** tfstate を保存 |
| `tfstate` Blob コンテナ（消費者ごとに 1 つ）         | Layer 1 SA 内の Blob コンテナ                                   | モジュール別 tfstate コンテナ (bootstrap, lz, project\_\*)                                                             |
| Bootstrap Key Vault                                  | Azure Key Vault（パージ保護、RBAC）                             | Layer 1 Storage Account の保存時暗号化に用いる Customer-Managed Key (CMK) を保持                                       |
| `tfbackend_cmk` キー                                 | Bootstrap Key Vault 内の RSA キー                               | Layer 1 Storage Account を暗号化する CMK（tfstate の多層防御）                                                         |
| Bootstrap UAMI                                       | User-Assigned Managed Identity                                  | Storage Account に対し CMK アクセスを付与する ID（`Storage Account → Key Vault` 暗号化チェーン）                       |
| `azurerm.tfbackend` 設定ファイル (`local_file` 出力) | オペレーターのディスク上に生成される Terraform バックエンド設定 | `bootstrap`, `devops-org-lz`, プロジェクトモジュールを Layer 1 SA / コンテナへ手動編集なしで接続                       |

#### テーブル B — 組織全体の Platform Landing Zone (`infra/devops-org-lz/`、現在 `infra/devops/lz/`)

組織内の **すべての** プロジェクトが消費する共有インフラをプロビジョニングします。組織ごとに 1 回デプロイ。出力はすべてのプロジェクトモジュールから `terraform_remote_state` 経由で参照されます。

| カテゴリ        | リソース                                                                                                                           | 何か                                                                       | 何のため                                                                                                                                                                                                                                                     |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| RG              | Agents RG                                                                                                                          | リソースグループ                                                           | 共有エージェント / runner インフラ（ACR、Log Analytics、container-run UAMI、現状コードでは ACA Environment、[ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md) 参照）の格納先                                                                       |
| RG              | Identity RG                                                                                                                        | リソースグループ（LZ 時点では空）                                          | プロジェクトモジュールが Tier 2 で 7 個のプロジェクト UAMI を投入する組織レベルコンテナ（中央集約 RBAC と発見性 — [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md) 参照）                                                                         |
| RG              | Network RG                                                                                                                         | リソースグループ                                                           | Platform LZ VNet、サブネット、NAT、Private DNS Zone、Private Endpoint の格納先                                                                                                                                                                               |
| RG              | DevBox RG                                                                                                                          | リソースグループ                                                           | 組織レベルの Dev Center と Dev Box 定義の格納先                                                                                                                                                                                                              |
| Agents          | Azure Container Registry (ACR)                                                                                                     | Premium ACR + Private Endpoint                                             | すべてのプロジェクトの ACA Job が使用する self-hosted runner コンテナイメージを格納（共有イメージ × プロジェクト別ランナー）                                                                                                                                 |
| Agents          | ACR ビルドタスク                                                                                                                   | `azurerm_container_registry_task`                                          | プラットフォーム内で runner コンテナイメージをビルド・更新（外部 CI 不要）                                                                                                                                                                                   |
| Agents          | Log Analytics ワークスペース                                                                                                       | 共有 LA ワークスペース                                                     | すべてのプロジェクトの runner ACA Environment / Job に対する集中ログ・メトリクス                                                                                                                                                                             |
| Agents          | Container-Run UAMI                                                                                                                 | ACA Job に割り当てる UAMI                                                  | runner コンテナが ACR からプル / Log Analytics へログ書き込みするための ID（プロジェクト横断で共有）                                                                                                                                                         |
| Agents          | ~~ACA Environment~~ _(ターゲット: プロジェクトレベルに移動 — [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md))_         | _(LZ レベルでは作成しない)_                                                | ACA Environment はプロジェクトスコープのリソース。LZ はプロジェクトレベルの ACA Environment が利用する共有インフラ（ACR、Log Analytics、container-run UAMI）を引き続き提供。Table C のプロジェクトスコープ ACA Environment 行を参照。                        |
| Network         | Platform LZ VNet                                                                                                                   | Azure Virtual Network                                                      | プラットフォームのハブ VNet。Bootstrap SA / KV の Private Endpoint、runner サブネット（`platform` モードでプロジェクトスコープ ACA が使用）、DevBox サブネット、Private DNS Zone リンクをホスト                                                              |
| Network         | サブネット（runner / devbox / private-endpoint 等）                                                                                | 必要な delegation 付きの VNet サブネット                                   | プロジェクト専用アドレス スライス（`platform` モード）およびプラットフォーム共有サービス スライスを提供                                                                                                                                                      |
| Network         | NAT Gateway _(構成時)_                                                                                                             | Azure NAT Gateway                                                          | runner Job に決定論的なエグレスを提供（顧客側ファイアウォール / Private Endpoint で IP 許可リスト化可能）                                                                                                                                                    |
| Network         | Private DNS Zone                                                                                                                   | `blob`, `vault`, `azurecr.io`, `containerapps` 等の Azure Private DNS Zone | プラットフォームの Private Endpoint を Platform VNet および BYO プロジェクト VNet（このゾーンにリンクしたもの、[ADR-005](./adr/ADR-005-vnet-architecture.ja.md)）から名前解決                                                                                |
| Network         | Private Endpoint（Layer 1 SA、KV）                                                                                                 | Platform VNet 内の Private Endpoint                                        | Bootstrap Storage Account / Key Vault をプライベート接続経由のみで到達可能にする                                                                                                                                                                             |
| KV シークレット | VCS PAT シークレット（GitHub / Azure DevOps）                                                                                      | Bootstrap Key Vault 内のシークレット                                       | プロジェクトモジュール（`project_github` / `project_azuredevops`）に Key Vault データソース経由で VCS PAT を安全に提供（tfvars に保存しない）                                                                                                                |
| Dev Center      | Azure Dev Center                                                                                                                   | Microsoft Dev Box サービスのルート                                         | プロジェクト横断で利用される開発者 Dev Box の組織全体コントロールプレーン                                                                                                                                                                                    |
| Dev Center      | Dev Box 定義                                                                                                                       | イメージ / SKU 別の Dev Box 定義                                           | プロジェクトチームが自プロジェクトに関連付け可能な Dev Box イメージのカタログ                                                                                                                                                                                |
| Dev Center      | ~~Dev Center ネットワーク接続~~ _(target: プロジェクトレベルに移動 — [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md))_ | _(target: LZ レベルでは作成しない)_                                        | ネットワーク接続はプロジェクトの runner ネットワークコンテキスト（`platform` モードではプロジェクト専用サブネット、`byo` モードでは BYO VNet）にバインドする必要がある — ACA Environment リファクタと同じ理由。プロジェクトスコープの行はテーブル C を参照。 |
| ガバナンス      | 組織レベルの ruleset / runner group _(target — [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md))_                       | GitHub 組織 ruleset、Azure DevOps エージェントプール / グループ（計画中）  | ブランチ保護、必須ワークフロー、プロジェクト別 runner 隔離を組織レベルで強制（両 VCS プラットフォーム間でパリティ）                                                                                                                                          |

#### テーブル C — プロジェクト別 (`infra/devops-project-lz/` サブモジュール、現在 `infra/devops/project_github/`)

1 プロジェクト分の Azure リソース、ID、VCS 側構成をプロビジョニングします。プロジェクトごとに 1 回実行。`terraform_remote_state` 経由で Platform LZ 出力（テーブル B）を消費します。`project_azuredevops`（[ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md)）も同等のリソースセットを生成し、GitHub と Azure DevOps プロジェクトを機能的に等価にします。

| カテゴリ      | リソース                                                                                           | 何か                                                                                                                               | 何のため                                                                                                                                                                                                                         |
| ------------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ID            | 7 個のプロジェクト UAMI                                                                            | 組織レベル Identity RG（テーブル B）に作成される UAMI                                                                              | 環境別 × ジョブ種別の ID: `feat-plan`, `dev-plan`, `stg-plan`, `prod-plan`, `dev-apply`, `stg-apply`, `prod-apply` — 最小権限ワークフロー用に (env × job) ごとに 1 ID（[ADR-003](./adr/ADR-003-project-multi-repo-model.ja.md)） |
| ID            | OIDC フェデレーテッドクレデンシャル                                                                | UAMI ごとの `azurerm_federated_identity_credential`                                                                                | プロジェクトの GitHub リポ / Azure DevOps サービス接続を信頼し、(env × job) ごとに client secret なしで Azure トークンを発行                                                                                                     |
| ID            | サブスクリプション ロール割当 _(条件付き、env 別)_                                                 | env サブスクリプション上の組み込み / カスタム RBAC ロール割当                                                                      | env にマップされたサブスクリプションに対し、`*-plan` UAMI に読み取り専用、`*-apply` UAMI にデプロイ時スコープを付与（env にサブスクリプションが指定された場合のみ）                                                              |
| State         | Layer 2 Storage Account                                                                            | プラットフォームサブスクリプション内のプロジェクトスコープ RG に配置する Storage Account（LRS デフォルト、レプリケーション選択可） | プロジェクトチーム自身のアプリ IaC の **Layer 2** tfstate を保存                                                                                                                                                                 |
| RG            | Layer 2 プロジェクトリソースグループ                                                               | プラットフォームサブスクリプション内のプロジェクトスコープ RG                                                                      | Layer 2 Storage Account とプロジェクト Key Vault を格納するリソースグループ                                                                                                                                                      |
| Secrets       | プロジェクト Key Vault                                                                             | プロジェクトスコープ RG 内の Key Vault（プロジェクトのランナー VNet 内にデプロイ）                                                 | プロジェクトチーム自身のシークレットとキー（アプリ設定、DB パスワード、署名キー等）を保存。組織レベルのブートストラップ Key Vault（プロビジョニング時の VCS PAT のみ保持）とは別物。                                             |
| State         | Layer 2 Private Endpoint + DNS リンク                                                              | プロジェクトのランナーネットワークコンテキスト内の Layer 2 SA 用 Private Endpoint                                                  | アプリ tfstate アクセスをプロジェクト runner と同じプライベートネットワーク上に保つ                                                                                                                                              |
| Compute       | ACA Environment _([ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md))_                    | プロジェクトスコープの Azure Container Apps Environment                                                                            | プロジェクトの self-hosted runner Job を実行。プロジェクトのランナーネットワークコンテキスト（`platform` モードでは Platform LZ VNet 内のプロジェクト専用サブネット、`byo` モードでは BYO VNet）にバインド                       |
| Compute       | ACA Job / ACI Job                                                                                  | self-hosted runner ジョブ定義                                                                                                      | 共有 ACR から runner イメージをプルし、プロジェクトのリポジトリの CI ワークフローを実行                                                                                                                                          |
| Dev Box       | Dev Center Project + Pool                                                                          | 組織 Dev Center にバインドされた Dev Center Project とプール                                                                       | 組織カタログ（テーブル B）からプロジェクト開発者が Dev Box をプロビジョン（このプロジェクトにスコープ）                                                                                                                          |
| Dev Box       | Dev Center ネットワーク接続 ([ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md))          | プロジェクトの runner ネットワークコンテキストにバインドされたネットワーク接続                                                     | プロジェクトの Dev Box プールをプロジェクトの VNet（`platform` モードではプロジェクト専用サブネット、`byo` モードでは BYO VNet）にバインドし、Dev Box が runner と同じプライベート DNS / エグレス姿勢を共有                      |
| Dev Box       | Dev Box ロール割当                                                                                 | Dev Center Project 上の Dev Box admin / user RBAC                                                                                  | プロジェクトチームに Dev Box プロビジョン / 管理に適切なアクセスを付与                                                                                                                                                           |
| カスタム RBAC | カスタムロール（例: blob container reader）                                                        | プロジェクトスコープのカスタム RBAC ロール定義 / 割当                                                                              | runner UAMI からプロジェクト tfstate コンテナ等への細粒度アクセス                                                                                                                                                                |
| VCS — GitHub  | リポジトリ（プロファイル別 1 個）                                                                  | モジュールがプロビジョニングする GitHub リポジトリ                                                                                 | ワークフローテンプレートが想定する標準ブランチ / ファイル レイアウトを持つプロジェクトのソースリポジトリ                                                                                                                         |
| VCS — GitHub  | GitHub Environments × {features, dev, staging, prod}                                               | リポジトリ別の GitHub デプロイメント環境                                                                                           | 各 (env × job) を OIDC + 保護ルール（レビュアー、ブランチポリシー）で対応する UAMI にバインド                                                                                                                                    |
| VCS — GitHub  | ワークフローファイル（プロファイル駆動）                                                           | `github_workflows` モジュールから生成される YAML ワークフロー                                                                      | 7 個の (env × job) 組み合わせとプロジェクトの runner ACA Environment を対象とする標準化された plan/apply パイプライン                                                                                                            |
| VCS — GitHub  | プロジェクト別 runner 参照                                                                         | プロジェクト ACA runner を参照する GitHub runner group / labels                                                                    | プロジェクトの CI ジョブを自プロジェクトの runner にルーティング（プロジェクト横断の runner 共有なし）                                                                                                                           |
| VCS — ADO     | Azure DevOps Project + repos + pipelines _([ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md))_ | Azure DevOps Project + Git リポジトリ + YAML パイプライン                                                                          | 上記 GitHub スタックの機能的等価物。[ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md) の抽象化をエンドツーエンドで成立させる                                                                                                 |

---

## 2. ターゲット階層と用語

```text
┌────────────────────────────────────────────────────────────────────┐
│  Organization (GitHub Org / Azure DevOps Org)                     │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Bootstrap  (infra/bootstrap)                               │  │
│  │  • Storage Account (Layer 1: プラットフォーム tfstate コンテナー) │  │
│  │  • Key Vault (VCS PAT などのシークレット)                   │  │
│  │  • Terraform state: ローカルファイル → azurerm に移行        │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                        ▼ (tfstate → azurerm)       │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Platform Landing Zone  (devops-org-lz)                      │  │
│  │  • プラットフォームブートストラップ: 組織用 Azure リソースの作成 │  │
│  │    – 共有 ID RG (UAMI)                                      │  │
│  │    – 共有エージェント RG (ACR, Log Analytics, コンテナー実行 UAMI) │  │
│  │    – ネットワーク RG (プラットフォーム管理 VNet またはハブ)   │  │
│  │    – DevBox Dev Center                                      │  │
│  │    – Bootstrap KV シークレット (VCS PAT)                     │  │
│  │  • VCS ガバナンス:                                            │  │
│  │    – GitHub: 組織レベルのルールセット、ランナーグループ       │  │
│  │    – Azure DevOps: 組織レベルのエージェントプール             │  │
│  │  * ACA Environment はプロジェクトレベルのリソース — §5.4.1   │  │
│  │  • Tfstate キー: "devops-lz.terraform.tfstate"               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                        ▼ (remote_state)            │
│  ┌── Project A (GitHub) ─────────────────────────────────────────┐ │
│  │  DevOps LZ "プロジェクト" = 論理的なグルーピング               │ │
│  │  (GitHub: フラットな org 内のリポジトリ │ ADO: ADO Project 内) │ │
│  │  repositories = [                                             │ │
│  │    { name="project-a-infra",  profile="infra"  },             │ │
│  │    { name="project-a-app",    profile="app"    },             │ │
│  │  ]                                                            │ │
│  │  network_mode = "platform"                                    │ │
│  │  subscriptions = { features, dev, staging, prod }             │ │
│  │  identities (環境 × ジョブごとの UAMI — プロジェクト時に作成) │ │
│  │  runners (ACA ジョブまたは ACI)                               │ │
│  │  DevBox プロジェクトプール                                     │ │
│  │  Tfstate キー: "projects/project-a.terraform.tfstate"          │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  ┌── Project B (Azure DevOps) ───────────────────────────────────┐ │
│  │  DevOps LZ "プロジェクト" = Azure DevOps Project の境界       │ │
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

### 主要用語

| 用語                                    | 定義                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **組織 (Organization)**                 | 最上位のガバナンス境界 — GitHub Organization または Azure DevOps Organization にマッピングされる。共有インフラストラクチャとポリシーを所有する。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **ブートストラップ**                    | Storage Account（tfstate 用）と Key Vault（シークレット用）を作成する基盤レイヤー（ターゲット: `infra/bootstrap/`、現在 `infra/_bootstrap/`）。一度実行され、後続のすべてのレイヤーが使用する `bootstrap.config.json` を出力する。                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **プラットフォーム ランディングゾーン** | 組織ごとに一度プロビジョニングされる共有インフラストラクチャレイヤー（ターゲット: `infra/devops-org-lz/`、現在 `infra/devops/lz/`）。Azure リソースグループ（ID、エージェント、ネットワーク、DevBox）と共有コンピューティング/レジストリリソースを作成する。組織スコープリソース: ACR、Log Analytics、コンテナー実行 UAMI、Dev Center、プラットフォーム VNet、プライベート DNS ゾーン。VCS ガバナンスリソース（組織レベルのルールセット、ランナーグループ）は[ADR-006](./adr/ADR-006-organization-governance.ja.md) を参照。ACA Environment はプロジェクトスコープのリソース（[ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md)）。自身の tfstate はブートストラップの Storage Account に格納される。 |
| **プロジェクト**                        | リポジトリ、環境、ID、ランナージョブを論理的にグループ化したもので、1 つの製品やワークロードを提供する。GitHub ではフラットな org 内で命名規則ベースのリポジトリグルーピングとなる。Azure DevOps では実際の Azure DevOps Project コンテナーにマッピングされる。                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| **リポジトリセット**                    | プロジェクトに属する Git リポジトリの順序付きリスト。各リポジトリは CI/CD ワークフローの形状を決定する **プロファイル** を持つ。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **リポジトリプロファイル**              | ブランチ戦略、ワークフローファイル、環境、ID 要件をリポジトリのクラス（例: `infra`、`app`、`library`）ごとに定義するテンプレート。プロファイルは **推奨事項** であり、ユーザーは好みに応じて infra と app のコードを単一リポジトリに配置できる。                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| **環境 (Environment)**                  | デプロイターゲット — Azure サブスクリプションおよび OIDC フェデレーション UAMI を持つ GitHub Actions Environment（または Azure DevOps Environment）と 1:1 でマッピングされる。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **ネットワークモード**                  | プロジェクトが Azure ネットワークにどのように接続するかを決定する: `platform`（LZ 管理の VNet を使用）または `byo`（Bring Your Own VNet）。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |

---

## 3. ブートストラップと状態管理（4 層デプロイメント）

### 3.1 課題

現在の bootstrap レイヤーは、Terraform 状態ファイルを管理するための Storage Account と Key Vault を作成する。このストレージ（Layer 1）は、ブートストラップ自体、プラットフォーム ランディングゾーン、およびプロジェクトプロビジョニングモジュール（`project_github`、`project_azuredevops`）の状態を保持する。

しかし、DevOps Landing Zone を通じてプロビジョニングされたプロジェクトは、独自のアプリケーションインフラストラクチャにも Terraform を使用する場合がある（例: アプリ用の Azure リソースのデプロイ）。これらのプロジェクトレベルの IaC 状態は、プラットフォームの Layer 1 ストレージに格納すべき **ではなく** — プロジェクトごとの独自の状態ストレージ（Layer 2）が必要であり、これはプロジェクトプロビジョニング時に作成される。

現在、この 2 層の関係は明示的にされていない。

### 3.2 2 層状態管理モデル

```text
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: プラットフォーム状態ストレージ                           │
│ (bootstrap が作成 — 組織用の単一 Storage Account)                  │
│                                                                 │
│  以下の tfstate を格納:                                          │
│    • ブートストラップ自体    ("bootstrap.terraform.tfstate")      │
│    • プラットフォーム LZ     ("devops-lz.terraform.tfstate")      │
│    • プロジェクトプロビジョニング ("projects/<name>.terraform.tfstate") │
│                                                                 │
│  その他の内容:                                                   │
│    • Key Vault (LZ とプロジェクトプロビジョニング用の PAT とシークレット) │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2: プロジェクトごとの状態ストレージ（プロジェクトごとに 1 つ）│
│ (プロジェクトプロビジョニング時に作成 — project_github /           │
│  project_azuredevops モジュール)                                  │
│                                                                 │
│  以下の tfstate を格納:                                          │
│    • プロジェクト独自のアプリケーション IaC（例: プロジェクト       │
│      チームが Terraform でデプロイする Azure リソース）             │
│                                                                 │
│  各プロジェクトが Layer 2 用の独自の Storage Account を取得:       │
│    • プラットフォームサブスクリプション内のプロジェクトスコープ RG  │
│    • LRS デフォルト、レプリケーション選択可                        │
│    • プロジェクト Key Vault も同じ RG に配置                       ││
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 Layer 1 内の運用ティア

Layer 1 内には、Terraform 操作の順序と状態の依存関係を決定する 4 つの運用ティアがある:

```text
┌─────────────────────────────────────────────────────────────────┐
│ Layer 0: Tfstate ブートストラップ  (infra/bootstrap)              │
│                                                                 │
│  terraform apply (ローカル状態 → azurerm に移行)                 │
│  作成するもの:                                                   │
│    • ブートストラップ用リソースグループ                           │
│    • Storage Account + "tfstate" コンテナー (= Layer 1 ストレージ) │
│    • Key Vault (PAT とシークレット用)                            │
│  出力:                                                           │
│    • bootstrap.config.json (storage_account_name 等)             │
│    • devops.azurerm.tfbackend (バックエンド設定テンプレート)      │
│                                                                 │
│  状態キー: "bootstrap.terraform.tfstate" (Layer 1 内)            │
├─────────────────────────────────────────────────────────────────┤
│ Layer 1: プラットフォーム ランディングゾーン  (devops-org-lz)       │
│                                                                 │
│  terraform init -backend-config=devops.azurerm.tfbackend        │
│  terraform apply                                                │
│  作成するもの:                                                   │
│    • ID RG + コンテナー実行用 UAMI                               │
│    • エージェント RG + ACR + Log Analytics                        │
│    • ネットワーク RG + VNet + サブネット + DNS ゾーン + NAT GW    │
│    • DevBox Dev Center + 定義                                    │
│    • Bootstrap KV シークレット (VCS PAT)                         │
│    • VCS ガバナンス                                                │
│  出力:                                                           │
│    • devops_agents, devops_identity, devops_network,            │
│      devops_devbox, container_specs, options                    │
│                                                                 │
│  状態キー: "devops-lz.terraform.tfstate" (Layer 1 内)            │
│  読み取り: Layer 0 の bootstrap.config.json                       │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2: プロジェクト (devops-project-lz)                          │
│                                                                 │
│  terraform init -backend-config=...                             │
│  terraform apply                                                │
│  読み取り: Layer 1 (devops-org-lz) の remote_state                 │
│  作成:                                                           │
│    • プロジェクト RG + Layer 2 Storage Account + プロジェクト KV  │
│    • プロジェクトスコープ UAMI + フェデレーション ID 資格情報     │
│    • ACA Environment（プロジェクトごと、ADR-001）                 │
│    • ランナー（プロジェクト ACA Env を使用した ACA ジョブ）       │
│    • プロジェクトネットワークコンテキスト（サブネットまたは BYO）  │
│    • DevBox プロジェクトプール + Network Connection               │
│                                                                 │
│  状態キー: "projects/<project_name>.terraform.tfstate" (Layer 1) │
│  読み取り: Layer 1 (devops-org-lz) の remote_state                 │
├─────────────────────────────────────────────────────────────────┤
│ Layer 3: リポジトリ + 環境 (devops-repo-lz)                        │
│                                                                 │
│  terraform init -backend-config=...                             │
│  terraform apply                                                │
│  読み取り: Layer 2 (devops-project-lz) の remote_state             │
│  作成:                                                           │
│    • VCS リポジトリ（GitHub リポジトリまたは ADO リポジトリ）      │
│    • CI/CD ワークフロー / パイプライン（リポジトリプロファイル別）│
│    • GitHub/ADO 環境（保護ルール付き）                            │
│    • 環境 ↔ サブスクリプションバインディング（UAMI フェデレーション）│
│    • リポジトリ別 ID（オプション、きめ細かい RBAC 用）           │
│                                                                 │
│  状態キー: "repos/<project>/<repo_name>.terraform.tfstate"       │
│            (Layer 1 内)                                          │
└─────────────────────────────────────────────────────────────────┘
```

### 3.4 変わらない点

- bootstrap モジュール（ターゲット: `infra/bootstrap/`、現在 `infra/_bootstrap/`）は機能的に変更なし。既に Layer 1 に必要なリソースを正確に作成している。
- Org LZ（ターゲット: `infra/devops-org-lz/`、現在 `infra/devops/lz/`）は既に `bootstrap.config.json` を読み取り、Layer 1 の Storage Account に状態を格納している。
- プロジェクトは既に `terraform_remote_state` を通じて LZ の出力を読み取っている。

### 3.5 変更点

**概念的なドキュメント** で 2 層ストレージモデルを明示的にする:

1. **Layer 1** = プラットフォーム状態ストレージ — bootstrap が作成する単一の Storage Account で、以下の tfstate を保持する:
   - ブートストラップ自体 (`bootstrap.terraform.tfstate`)
   - プラットフォーム LZ (`devops-lz.terraform.tfstate`)
   - プロジェクトプロビジョニング (`projects/<project_name>.terraform.tfstate`)
   - リポジトリプロビジョニング (`repos/<project>/<repo_name>.terraform.tfstate`)

2. **Layer 2** = プロジェクトごとの状態ストレージ — プロジェクトごとに個別の Storage Account（`devops-project-lz` によるプロジェクトプロビジョニング時に作成）で、以下を保持する:
   - プロジェクトチーム独自のアプリケーション IaC 状態（例: プロジェクトがデプロイする Azure リソースの Terraform 状態）

Layer 1 は DevOps LZ プラットフォームチームが管理する。Layer 2 はプロジェクトチームが独自のインフラストラクチャ・アズ・コード ワークフローで使用する。

> **注記:** Layer 1（プラットフォーム Storage Account）内の 4 つのデプロイメントレイヤー（Layer 0 → Layer 1 → Layer 2 → Layer 3）は `terraform apply` 操作の順序と状態の依存関係を決定する。Layer 0 は非常にまれにしか適用されない（基本的に 1 回）、Layer 1 は組織のプラットフォーム構成が変更された際に適用される、Layer 2 は新しいプロジェクトがオンボーディングまたは変更された際に適用される、Layer 3 はプロジェクト内のリポジトリや環境が追加/変更された際に適用される。4 つのレイヤーすべてが **同じ** Layer 1 Storage Account に状態を格納する。プロジェクトごとの Layer 2 Storage Account は Layer 2 プロビジョニング中にプロジェクトごとに作成される別の SA であり、プロジェクトチーム独自の利用を目的としている。

---

## 4. モジュールとディレクトリ構造（ターゲット）

### 4.1 新ディレクトリレイアウト

ターゲットアーキテクチャでは、既存のディレクトリと並行して **新しいディレクトリレイアウト** を導入する。移行期間中は両方のレイアウトが共存する。新設計の実装が完了したら、旧ディレクトリは削除できる。

| レイヤー                   | 現在のディレクトリ                                                  | ターゲットディレクトリ     | 備考                                                       |
| -------------------------- | ------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------- |
| Layer 0 — ブートストラップ | `infra/_bootstrap/`                                                 | `infra/bootstrap/`         | リネーム（アンダースコアプレフィックス削除）               |
| Layer 1 — Org LZ           | `infra/devops/lz/`                                                  | `infra/devops-org-lz/`     | フラットディレクトリ（`devops/` 配下のネスト廃止）         |
| Layer 2 — Project LZ       | `infra/devops/project_github/`, `infra/devops/project_azuredevops/` | `infra/devops-project-lz/` | 別リポジトリからの **Git サブモジュール**                  |
| Layer 3 — Repo LZ          | _(プロジェクトモジュール内)_                                        | `infra/devops-repo-lz/`    | **Git サブモジュール** — リポジトリ + 環境プロビジョニング |
| セットアップ               | `infra/_setup_subscriptions/`                                       | _(変更なし)_               |                                                            |
| 共有モジュール             | `infra/modules/`                                                    | _(変更なし)_               | Org LZ、Project LZ、Repo LZ で使用                         |

**重要な設計決定:**

- `infra/devops-project-lz/` は別リポジトリを参照する **Git サブモジュール** である。独立バージョニングとマルチリポジトリ利用を可能にする。
- `infra/devops-repo-lz/` は **Git サブモジュール**（同一または別リポジトリ）であり、リポジトリと環境のプロビジョニングを独自の Terraform 状態を持つ別の apply として処理する。

```text
infra/
├── bootstrap/                          # Layer 0: Layer 1 状態ストレージ + Key Vault  [新規]
├── _bootstrap/                         # (旧レイアウト — 移行中は保持)
├── _setup_subscriptions/               # (変更なし) リソースプロバイダーの登録
├── devops-org-lz/                      # Layer 1: 組織レベルのプラットフォーム LZ    [新規]
│   ├── _variables.tf
│   ├── _variables.network.tf
│   ├── _variables.vcs.github.tf
│   ├── _variables.vcs.azuredevops.tf
│   ├── _variables.governance.tf        # 組織レベルのポリシーとルールセット (GitHub + ADO)
│   ├── _outputs.tf
│   ├── network.vnet.tf                 # プラットフォーム管理の VNet
│   ├── governance.github.tf            # GitHub 組織レベルのルールセット、ランナーグループ
│   ├── governance.azuredevops.tf       # Azure DevOps 組織レベルのポリシー
│   └── ...
│
├── devops-project-lz/                  # Layer 2: プロジェクトごとのリソース          [新規 — git サブモジュール]
│   ├── project_github/                 # GitHub プロジェクト用ルートモジュール
│   │   ├── _variables.tf               # プロジェクト ID、network_mode
│   │   ├── _variables.network.tf       # BYO VNet 入力
│   │   ├── uami.tf                     # プロジェクトスコープ UAMI
│   │   ├── uami.federation.tf          # OIDC フェデレーション
│   │   ├── state.tf                    # Layer 2 SA + プロジェクト KV + プロジェクト RG
│   │   ├── aca_env.tf                  # ACA Environment（プロジェクトランナー）
│   │   ├── network.tf                  # BYO VNet データ参照と検証
│   │   └── ...
│   │
│   ├── project_azuredevops/            # Azure DevOps プロジェクト用ルートモジュール
│   │   ├── _variables.tf               # プロジェクト ID、network_mode
│   │   └── ...                         # (該当部分は project_github と同様)
│   │
│   └── modules/                        # プロジェクトプロビジョニング用共有サブモジュール
│       ├── project_state/              # Layer 2 SA + プロジェクト KV + プロジェクト RG
│       ├── project_identity/           # 7 UAMI + フェデレーション資格情報 + RBAC
│       ├── project_network/            # サブネットスライス (platform) または BYO 検証
│       ├── aca_env/                    # ACA Environment
│       ├── devbox_project/             # DevCenter Project + Pool + Network Connection
│       └── runner/                     # ACA ジョブ定義 (GitHub または ADO)
│
├── devops-repo-lz/                     # Layer 3: リポジトリ + 環境プロビジョニング  [新規 — git サブモジュール]
│   ├── repo_github/                    # GitHub リポジトリ + 環境用ルートモジュール
│   │   ├── _variables.tf               # リポジトリ名、プロファイル、環境
│   │   ├── _variables.environments.tf  # 環境 → サブスクリプションマッピング
│   │   ├── repo.tf                     # GitHub リポジトリ作成
│   │   ├── workflows.tf                # CI/CD ワークフロー生成（プロファイル駆動）
│   │   ├── environments.tf             # GitHub 環境 + 保護ルール
│   │   ├── identity.tf                 # オプションのリポジトリ別 UAMI
│   │   └── ...
│   │
│   ├── repo_azuredevops/               # ADO リポジトリ + 環境用ルートモジュール
│   │   ├── _variables.tf               # リポジトリ名、プロファイル、環境
│   │   ├── _variables.environments.tf  # 環境 → サブスクリプションマッピング
│   │   ├── repo.tf                     # ADO リポジトリ作成
│   │   ├── pipelines.tf                # CI/CD パイプライン生成
│   │   ├── environments.tf             # ADO 環境 + 承認
│   │   └── ...
│   │
│   └── modules/                        # リポジトリプロビジョニング用共有サブモジュール
│       ├── project_repo/               # 抽象: リポジトリ作成 (GH/ADO ディスパッチ)
│       ├── environment/                # 抽象: 環境作成 (GH/ADO ディスパッチ)
│       └── runner/                     # 抽象: ランナー登録 (GH/ADO)
│
├── devops/                             # (旧レイアウト — 移行中は保持)
│   ├── lz/
│   └── project_github/
│
└── modules/                            # 共有 Terraform モジュール (組織レベル)
    ├── bootstrap/                      # ブートストラップモジュール
    ├── vnet/                           # VNet モジュール
    └── ...
```

### 4.2 Project LZ リポジトリ（サブモジュール参照元）

`infra/devops-project-lz/` ディレクトリは、プロジェクトのインフラ（ID、ネットワーク、ランナー、状態ストレージ）のプロビジョニングに必要なすべてを含む **別リポジトリ** を参照する Git サブモジュールである。このリポジトリがプロジェクトレベル IaC の唯一の信頼できるソースとなる:

```text
<org>/<devops-project-lz-repo>/         # プロジェクトプロビジョニング用の別リポジトリ
├── project_github/                     # GitHub プロジェクト用 Terraform ルートモジュール
│   ├── _variables.tf
│   ├── _variables.network.tf
│   ├── uami.tf                         # プロジェクトスコープ UAMI
│   ├── state.tf                        # Layer 2 SA + プロジェクト KV + プロジェクト RG
│   ├── aca_env.tf                      # ACA Environment
│   ├── network.tf
│   └── ...
├── project_azuredevops/                # Azure DevOps プロジェクト用 Terraform ルートモジュール
│   ├── _variables.tf
│   └── ...
├── modules/                            # プロジェクトプロビジョニング用共有サブモジュール
│   ├── project_state/                  # Layer 2 SA + プロジェクト KV + プロジェクト RG
│   ├── project_identity/               # 7 UAMI + フェデレーション資格情報 + RBAC
│   ├── project_network/                # サブネットスライス (platform) または BYO 検証
│   ├── aca_env/                        # ACA Environment
│   ├── devbox_project/                 # DevCenter Project + Pool + Network Connection
│   └── runner/                         # ACA ジョブ定義 (GitHub または ADO)
└── README.md
```

### 4.3 Repo LZ リポジトリ（サブモジュール参照元）

`infra/devops-repo-lz/` ディレクトリは、プロジェクト内のリポジトリと環境のプロビジョニングに必要なすべてを含むリポジトリを参照する Git サブモジュールである。この分離により:

- **独立したライフサイクル** — プロジェクトレベルの Terraform を再適用せずにリポジトリ/環境を追加できる。
- **きめ細かい状態** — 各リポジトリが独自の tfstate を持ち、変更の影響範囲を縮小。
- **チーム委任** — プロジェクトチームがより狭い権限でリポジトリ/環境を管理できる。

```text
<org>/<devops-repo-lz-repo>/           # リポジトリ + 環境プロビジョニング用の別リポジトリ
├── repo_github/                       # GitHub リポジトリ用 Terraform ルートモジュール
│   ├── _variables.tf
│   ├── _variables.environments.tf
│   ├── repo.tf                        # GitHub リポジトリ + ブランチ保護
│   ├── workflows.tf                   # CI/CD ワークフロー生成
│   ├── environments.tf                # GitHub 環境 + 保護ルール
│   ├── identity.tf                    # オプションのリポジトリ別 UAMI
│   └── ...
├── repo_azuredevops/                  # ADO リポジトリ用 Terraform ルートモジュール
│   ├── _variables.tf
│   ├── _variables.environments.tf
│   ├── repo.tf                        # ADO リポジトリ + ブランチポリシー
│   ├── pipelines.tf                   # CI/CD パイプライン生成
│   ├── environments.tf                # ADO 環境 + 承認
│   └── ...
├── modules/                           # リポジトリプロビジョニング用共有サブモジュール
│   ├── project_repo/                  # 抽象: リポジトリ作成 (GH/ADO ディスパッチ)
│   ├── environment/                   # 抽象: 環境作成 (GH/ADO ディスパッチ)
│   └── runner/                        # 抽象: ランナー登録 (GH/ADO)
└── README.md
```

### 4.4 GitOps ガバナンスリポジトリ

**GitOps ガバナンスリポジトリ**（Issue 駆動のプロジェクト/リポジトリ オンボーディング用 — [ADR-007](./adr/ADR-007-gitops-onboarding.ja.md) 参照）は、Project LZ と Repo LZ の両リポジトリを Git サブモジュールとして参照する。これにより、すべてのプロビジョニングコードの単一の信頼できるソースが保証される。

```text
<org>/<gitops-governance-repo>/         # GitOps オンボーディング用の独立リポジトリ
├── .github/
│   ├── CODEOWNERS                      # プロジェクト領域ごとの承認チームを定義
│   ├── ISSUE_TEMPLATE/
│   │   ├── project-request.yaml        # 新規プロジェクトリクエスト用の Issue テンプレート
│   │   └── repo-request.yaml           # 新規リポジトリリクエスト用の Issue テンプレート
│   └── workflows/
│       ├── project-request-to-pr.yaml  # Issue を PR（YAML 定義付き）に変換
│       ├── project-create.yaml         # PR マージ時: terraform apply を実行（プロジェクト）
│       └── repo-create.yaml            # PR マージ時: terraform apply を実行（リポジトリ）
│
├── projects/                           # プロジェクト定義（信頼できる情報源）
│   ├── contoso-ecommerce.yaml          # プロジェクト定義（ID、ネットワーク等）
│   ├── contoso-payments.yaml
│   └── ...
│
├── repos/                              # リポジトリ定義（信頼できる情報源）
│   ├── contoso-ecommerce/
│   │   ├── repo-infra.yaml             # リポジトリ定義（プロファイル、環境）
│   │   └── repo-app.yaml
│   └── ...
│
├── infra/
│   ├── devops-project-lz/              # Git サブモジュール → <org>/<devops-project-lz-repo>
│   └── devops-repo-lz/                 # Git サブモジュール → <org>/<devops-repo-lz-repo>
│
└── README.md
```

> **注記:** **DevOps Landing Zone リポジトリ**、**GitOps ガバナンスリポジトリ**、および他の利用リポジトリは、**同じ** Project LZ と Repo LZ リポジトリを Git サブモジュールとして参照する。これにより、すべてのパス（直接 `terraform apply` と GitOps 駆動オンボーディング）でプロビジョニングコードが常に一貫することが保証される。

---

## アーキテクチャ決定記録 (ADR)

以下のADRドキュメントには、各トピック領域の詳細な設計決定が含まれています。各ADRには、コンテキスト、決定内容、完全な技術的詳細、および関連する決定が記載されています。

| ADR                                                         | トピック                                 | 概要                                                                                                            |
| ----------------------------------------------------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| [ADR-001](./adr/ADR-001-platform-lz-resource-scoping.ja.md) | プラットフォーム LZ リソーススコーピング | 組織レベル vs. プロジェクトレベルのリソース配置。主要な発見：ACA Environment はプロジェクトスコープであるべき。 |
| [ADR-002](./adr/ADR-002-runner-compute-model.ja.md)         | ランナーコンピュートモデル               | 5つのアーキテクチャ上の理由により、ACA 上のセルフホストランナーを GitHub ホスト + APES よりも選択。             |
| [ADR-003](./adr/ADR-003-project-multi-repo-model.ja.md)     | プロジェクトとマルチリポジトリモデル     | プロジェクト定義、CI/CD プロファイル付きマルチリポジトリサポート、ID 割り当て戦略、サブセット環境。             |
| [ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md)       | GitHub / Azure DevOps 抽象化             | 統一されたプラットフォーム非依存「プロジェクト」概念と共有入力インターフェース。                                |
| [ADR-005](./adr/ADR-005-vnet-architecture.ja.md)            | VNet アーキテクチャ (Platform & BYO)     | 3 階層 VNet モデル、`platform` と `byo` ネットワークモード、7 つの一貫性ルール、詳細なネットワーク図。          |
| [ADR-006](./adr/ADR-006-organization-governance.ja.md)      | 組織レベルガバナンス                     | GitHub ルールセットと ADO ブランチポリシーを駆動するプラットフォーム非依存ガバナンス変数。                      |
| [ADR-007](./adr/ADR-007-gitops-onboarding.ja.md)            | GitOps オンボーディング                  | 自己完結型ガバナンスリポジトリを介した Issue → PR → マージ → `terraform apply` パイプライン。                   |
| [ADR-008](./adr/ADR-008-naming-collision-resistance.ja.md)  | 命名規則と衝突耐性                       | ポートフォリオセーフな命名パターン、tfstate キー規約、ハッシュベースの衝突耐性を持つ UAMI 命名。                |

---

## 6. 現行設計からの移行パス

### 6.1 後方互換性の保証

| 機能                        | 現在の動作 | 新しい動作                                              | 破壊的変更？ |
| --------------------------- | ---------- | ------------------------------------------------------- | ------------ |
| `repositories = []`         | N/A        | `project_name` を使用する単一リポジトリにフォールバック | いいえ       |
| `network_mode = "platform"` | 暗黙的     | 明示的なデフォルト                                      | いいえ       |
| `byo_vnet = null`           | N/A        | `network_mode = "platform"` の場合は無視                | いいえ       |
| `shared_identities = true`  | 暗黙的     | 明示的なデフォルト、同じ環境ごとの UAMI 動作            | いいえ       |
| LZ ガバナンス出力           | N/A        | 新しい出力; プロジェクトは無視可能                      | いいえ       |

### 6.2 推奨される移行ステップ

1. **フェーズ 0 — ディレクトリ再構成:**
   - `infra/bootstrap/` を作成する（`infra/_bootstrap/` の新レイアウト）。
   - `infra/devops-org-lz/` を作成する（`infra/devops/lz/` の新レイアウト）。
   - Project LZ リポジトリを作成し、`infra/devops-project-lz/` を Git サブモジュールとして追加する。
   - Repo LZ リポジトリを作成し、`infra/devops-repo-lz/` を Git サブモジュールとして追加する。
   - 移行中は旧ディレクトリを保持する — 新レイアウトの検証完了後に削除。

2. **フェーズ 1 — 非破壊的な追加:**
   - デフォルト値で `network_mode` / `byo_vnet` 変数を追加する。
   - Org LZ にガバナンス変数と出力を追加する（GitHub + Azure DevOps）。
   - Getting Started ガイドに 2 層ブートストラップモデルを文書化する。
   - 既存の tfvars ファイルの変更は不要。

3. **フェーズ 2 — モジュールのリファクタリング（Project LZ）:**
   - 抽象サブモジュール（`project_state`、`project_identity`、`project_network`、`aca_env`、`devbox_project`、`runner`）で `devops-project-lz` を実装する。
   - Org LZ に governance.github.tf と governance.azuredevops.tf を追加する。

4. **フェーズ 3 — Repo LZ の分離:**
   - 抽象サブモジュール（`project_repo`、`environment`、`runner`）で `devops-repo-lz` を実装する。
   - 旧 `project_github` からリポジトリ + 環境プロビジョニングを `devops-repo-lz` に抽出する。
   - 各リポジトリが独自の tfstate キー（`repos/<project>/<repo_name>.terraform.tfstate`）を持つ。

5. **フェーズ 4 — GitOps オンボーディング:**
   - GitOps ガバナンスリポジトリテンプレートを作成する。
   - プロジェクトおよびリポジトリリクエスト用の Issue テンプレートを追加する。
   - プロビジョニングワークフロー（Issue から PR、プロジェクト作成、リポジトリ作成）を追加する。
   - GitOps ガバナンスリポジトリに Project LZ と Repo LZ の両リポジトリを Git サブモジュールとして追加する。
   - GitOps オンボーディングワークフローを文書化する。

6. **フェーズ 5 — ドキュメントと例:**
   - マルチリポジトリの例示 tfvars を追加する。
   - BYO VNet の例示 tfvars を追加する。
   - 両モードのアーキテクチャ図を追加する。
   - GitHub vs Azure DevOps の比較ガイドを追加する。
   - パス参照を修正する（`infra/terraform/…` → `infra/…`）。
   - 新レイアウトの検証完了後に旧ディレクトリレイアウトを削除する。

---

## 7. 決定ログ（解決済みの質問）

| #   | 質問                                                                                                                              | 選択肢                                                                | 推奨事項                                                                                                                                                                                                                                                                                                                                                                                               |
| --- | --------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | GitOps ガバナンスリポジトリは Platform LZ（Tier 1）の一部として作成すべきか、独立して設定すべきか？                               | LZ の一部 / 独立 / テンプレートリポジトリ                             | **✅ 決定:** 独立した **テンプレートリポジトリ** として設定する。ガバナンスリポジトリは **Project LZ リポジトリ** を Git サブモジュールとして参照する（DevOps Landing Zone リポジトリの `infra/devops-project-lz/` と同じサブモジュール）。これにより、直接 apply パスと GitOps 駆動オンボーディングパスの両方で、プロジェクトプロビジョニングコードの唯一の信頼できるソースが保証される。             |
| 2   | BYO VNet は **LZ レベル**（LZ 自体が外部 VNet を使用）でサポートすべきか、**プロジェクトレベル** のみか？                         | LZ レベルの BYO / プロジェクトレベルの BYO / 両方                     | **✅ 決定:** まず **プロジェクトレベルの BYO VNet** から開始する。LZ レベルの BYO はより大きな変更であり、後から追加できる。リポジトリレベルの BYO VNet（プロジェクト内のリポジトリごとに異なる VNet）は **実用的ではない** — 分析については[ADR-005](./adr/ADR-005-vnet-architecture.ja.md) を参照。                                                                                                  |
| 3   | リポジトリごとの ID は、Azure の命名制限内で、どのように命名すべきか？                                                            | `uami-<project>-<repo>-<env>-<job>-<rand>` / ハッシュベースの短い名前 | **✅ 決定:** 混合アプローチ — `uami-<project>-<repo>-<hash>`。プロジェクト名とリポジトリ名は識別のために人間が読める形式を維持; `<hash>` は env + ジョブタイプ + ランダムシードから導出される短いハッシュ。env/ジョブを名前に表示する必要はない — 衝突耐性のためにハッシュにエンコードされ、Azure の 128 文字制限内に収まる。詳細は[ADR-008](./adr/ADR-008-naming-collision-resistance.ja.md) を参照。 |
| 4   | リポジトリプロファイルはユーザーが拡張可能にすべきか、固定にすべきか？                                                            | 固定セット / HCL 経由のユーザー定義プロファイル                       | **✅ 決定:** まず **固定セット**（`infra`、`app`、`library`、`docs`）から開始; ユーザー定義の拡張は後から許可する。固定セットがユースケースの大多数をカバーする。プロファイル定義と設計思想については[ADR-003](./adr/ADR-003-project-multi-repo-model.ja.md) を参照。                                                                                                                                  |
| 5   | 組織レベルのルールセットは強制にすべきか、アドバイザリーにすべきか？                                                              | `active` / `evaluate`（監査のみ）                                     | **✅ 決定:** デフォルトは **`active`**（強制）で組織管理者にバイパスを設定する。アドバイザリーモード（`evaluate`）はロールアウト中に使用できるが、デフォルトはブランチ保護を強制すべき。[ADR-006](./adr/ADR-006-organization-governance.ja.md) を参照（`enforcement = "active"`、`OrganizationAdmin` のバイパス）。                                                                                    |
| 6   | BYO VNet プロジェクトはプラットフォーム ACA 環境を共有すべきか、独自に作成すべきか？                                              | 共有 / プロジェクトごと / 設定可能                                    | **✅ 決定:** BYO VNet 内に **プロジェクトごとの ACA 環境** を作成する。プロジェクトが異なる VNet を使用する場合、プラットフォームの ACA 環境の共有は不可能 — ACA 環境にはプロジェクトの VNet 内のサブネット委任が必要。ネットワーク解決ロジックについては[ADR-005](./adr/ADR-005-vnet-architecture.ja.md) を参照。                                                                                     |
| 7   | 環境のサブセット（例: dev + prod のみ）のみが必要なプロジェクトをどう扱うか？                                                     | `subscriptions` をサブセットとして許可 / 4 つすべてを必須             | **✅ 決定:** **サブセットを許可** — 提供されたサブスクリプションに対応する環境のみを作成する。モジュールは `subscriptions` に存在する環境に対してのみ GitHub Actions Environment、UAMI、およびフェデレーション ID 資格情報を作成する。dev + prod のみのサンプル `terraform.tfvars` については[ADR-003](./adr/ADR-003-project-multi-repo-model.ja.md) を参照。                                          |
| 8   | Azure DevOps の場合、DevOps LZ は常に新しい ADO プロジェクトを作成すべきか、既存のものを参照するサポートもすべきか？              | 常に作成 / 既存を参照 / 両方                                          | **✅ 決定:** **両方** — `create_project` 変数は既に `azure_devops` モジュールに存在する。`create_project = false` の場合、モジュールは名前で既存の ADO プロジェクトを参照する。変数定義については[ADR-004](./adr/ADR-004-github-ado-abstraction.ja.md) を参照。                                                                                                                                        |
| 9   | GitOps プロビジョニングワークフローは GitHub ホステッドランナーとセルフホステッドランナーのどちらを使用すべきか？                 | GitHub ホステッド / セルフホステッド / 設定可能                       | **✅ 決定:** **セルフホステッドランナー**（tfstate ストレージやプライベートエンドポイント背後の Azure リソースへのプライベートネットワークアクセスに必要）。プロビジョニングワークフローは `runs-on: [self-hosted, devops-lz]` を使用する。ワークフロー定義については[ADR-007](./adr/ADR-007-gitops-onboarding.ja.md) を参照。                                                                         |
| 10  | GitHub の組織レベルルールセットと Azure DevOps のブランチポリシー（プロジェクトスコープ）の両方を使用する場合、どう同期を保つか？ | 手動 / 共有ガバナンス変数 / ドリフト検出                              | **✅ 決定:** プラットフォーム LZ の **共有ガバナンス変数**（`org_default_branch_rules`）を使用し、各プロジェクトモジュールがプロジェクト作成時に適用する。GitHub は組織レベルのルールセットを使用; Azure DevOps は同じルールをプロジェクトレベルのブランチポリシーとして適用する。ガバナンスの対応表については[ADR-006](./adr/ADR-006-organization-governance.ja.md) を参照。                          |

---

> **次のステップ:** すべてのオープンな質問は解決済み。フェーズ 1 の実装（非破壊的な変数追加）に進む。
