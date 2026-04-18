[English](./ADR-007-gitops-onboarding.md) | [日本語](./ADR-007-gitops-onboarding.ja.md)

# ADR-007: GitOps 駆動のプロジェクト・リポジトリ オンボーディング

> **ステータス:** 承認済み
> **コンテキスト:** [ターゲットアーキテクチャ仕様](../Target-Architecture-Spec.ja.md)

## 概要

Issue → PR → マージ → `terraform apply` パイプラインを使用したGitOpsガバナンスリポジトリ経由でプロジェクトとリポジトリをオンボーディング。

---

> **注記:** このセクションは GitOps オンボーディングワークフローのターゲット設計を記述する。

### 10.1 課題

現在、新しいプロジェクトのオンボーディングには以下が必要:

1. `terraform.tfvars.sample` を `terraform.tfvars` にコピーする
2. すべての値を手動で入力する
3. `terraform init` + `terraform apply` を実行する

多くのプロジェクト（10 以上）を持つ組織では、これはエラーが起きやすく、監査が困難。セルフサービスの仕組みも承認ワークフローもない。

### 10.2 ターゲット: Issue 駆動の GitOps ワークフロー

[github-gitops-samples](https://github.com/shigeyf/github-gitops-samples) にインスパイアされ、オンボーディングモデルは Issue → PR → マージ → プロビジョニング パイプラインを持つ **GitOps ガバナンスリポジトリ** を使用する:

**ワークフローステップ（テキスト説明）:**

1. ユーザーがプロジェクト/リポジトリリクエストテンプレートを使用して Issue を作成する。
2. GitHub Actions ワークフローが Issue を解析し、YAML プロジェクト定義ファイルを生成する。
3. ワークフローが YAML ファイルを含むプルリクエストを作成する。
4. CODEOWNERS 指定の承認者が PR をレビューし承認する（これが承認ゲート）。
5. PR がメインブランチにマージされる。
6. プロビジョニングワークフローが新しい YAML ファイルを検出し、`terraform plan` + `terraform apply` を実行する。
7. プロジェクトとそのリポジトリがプロビジョニングされる。

```mermaid
flowchart LR
    A[ユーザーが Issue を作成] --> B[Issue テンプレート:<br/>プロジェクト/リポジトリリクエスト]
    B --> C[ワークフロー:<br/>Issue から PR へ]
    C --> D[PR 内に YAML 定義<br/>を生成]
    D --> E[CODEOWNERS が<br/>レビューと承認]
    E --> F[PR マージ]
    F --> G[ワークフロー:<br/>terraform apply]
    G --> H[プロジェクト + リポジトリ<br/>がプロビジョニングされる]
```

### 10.3 GitOps ガバナンスリポジトリの構造

GitOps ガバナンスリポジトリは **独立して設定される**（Terraform で作成されない）、組織がクローンする **テンプレートリポジトリ** として設定される。GitHub Enterprise の **GitOps ガバナンス組織** でプラットフォーム LZ リポジトリと並んでホストされる。Terraform 経由で GitHub リポジトリを作成するのは複雑で脆弱 — テンプレートリポジトリのアプローチがよりシンプルで信頼性が高い。

ガバナンスリポジトリは、プロジェクト定義、それらをプロビジョニングするワークフロー、**そして** ワークフローが実行する IaC モジュール（`project_github`、`project_azuredevops`、共有モジュール）を保持する。これにより、GitOps リポジトリは **自己完結型** となり — プロビジョニング時に DevOps Landing Zone リポジトリをクローンする必要がない。

```text
# GitHub Enterprise 組織レイアウト:
<governance-org>/
├── devops-landing-zone/           # プラットフォーム LZ IaC リポジトリ (Tier 0 + Tier 1)
└── devops-gitops/                 # GitOps ガバナンスリポジトリ (プロジェクト IaC、テンプレートリポジトリ)
```

```text
<org>/devops-gitops/                    # GitOps ガバナンスリポジトリ
├── .github/
│   ├── CODEOWNERS                      # プロジェクト領域ごとの承認チーム
│   │   # 例:
│   │   # /.github/ @org/gitops-admins
│   │   # /projects/team-a/ @org/team-a-leads
│   │   # /projects/team-b/ @org/team-b-leads
│   │
│   ├── ISSUE_TEMPLATE/
│   │   ├── config.yml
│   │   └── project-request.yaml        # 新規プロジェクトリクエスト用の Issue テンプレート
│   │
│   └── workflows/
│       ├── project-request-to-pr.yaml  # Issue を解析 → YAML を生成 → PR を作成
│       └── project-create.yaml         # PR マージ時 → terraform init/apply
│
├── projects/                           # プロジェクト定義（信頼できる情報源）
│   ├── contoso-ecommerce.yaml
│   ├── contoso-payments.yaml
│   └── contoso-analytics.yaml
│
├── infra/                              # プロジェクトプロビジョニング用 IaC
│   ├── project_github/                 # Terraform ルートモジュール: GitHub プロジェクト
│   │   ├── _variables.tf
│   │   ├── _variables.repositories.tf
│   │   ├── _variables.network.tf
│   │   ├── github.tf
│   │   ├── github.workflow.tf
│   │   ├── uami.tf
│   │   ├── uami.federation.tf
│   │   ├── network.tf
│   │   └── ...
│   │
│   ├── project_azuredevops/            # Terraform ルートモジュール: Azure DevOps プロジェクト
│   │   ├── _variables.tf
│   │   ├── _variables.repositories.tf
│   │   └── ...
│   │
│   └── modules/                        # 共有 Terraform モジュール
│       ├── github/                     # GitHub リポジトリ/チーム/環境リソース
│       ├── azure_devops/               # ADO プロジェクト/リポジトリ/パイプラインリソース
│       ├── github_workflows/           # ワークフローファイル生成
│       └── ...
│
└── README.md
```

> **IaC を DevOps Landing Zone と同期する:**
> `infra/` ディレクトリには DevOps Landing Zone リポジトリと同じ `project_github`、`project_azuredevops`、および共有モジュールが含まれる。組織は以下のいずれかの方法で同期を維持する:
>
> - **Git サブモジュール**: `git submodule add <DevOps-Landing-Zone-repo> infra` — GitOps リポジトリがアップストリームの固定コミットを参照する。
> - **Terraform モジュールレジストリ**: モジュールをプライベート Terraform レジストリに公開し、ルートモジュールでバージョン指定で参照する。
> - **バージョン追跡付きの直接コピー**: モジュールをコピーし、`VERSION` ファイルでアップストリームバージョンを追跡する。
>
> **推奨** されるアプローチは、トレーサビリティと再現性のために Git サブモジュールまたは Terraform モジュールレジストリである。

### 10.4 プロジェクト定義フォーマット（YAML）

各プロジェクトは `projects/` ディレクトリ内の YAML ファイルで定義される。このファイルはプロジェクト設定の **宣言的な信頼できる情報源** として機能する:

```yaml
# projects/contoso-ecommerce.yaml
project_name: contoso-ecommerce
location: japaneast
vcs_platform: github # "github" または "azuredevops"
network_mode: platform

tags:
  appTag: contoso-ecommerce
  envTag: prod

repositories:
  - name: contoso-ecommerce-infra
    profile: infra
    description: 'Contoso e-commerce 用 Azure インフラストラクチャ'
  - name: contoso-ecommerce-api
    profile: app
    description: 'バックエンド API サービス'
  - name: contoso-ecommerce-web
    profile: app
    description: 'フロントエンド Web アプリケーション'
    environments: [development, staging, production]

subscriptions:
  features:
    id: '11111111-1111-1111-1111-111111111111'
  development:
    id: '22222222-2222-2222-2222-222222222222'
  staging:
    id: '33333333-3333-3333-3333-333333333333'
  production:
    id: '44444444-4444-4444-4444-444444444444'

runners:
  use_self_hosted_runners: true
  self_hosted_runners_type: aca
```

### 10.5 プロジェクトリクエスト用の Issue テンプレート

```yaml
# .github/ISSUE_TEMPLATE/project-request.yaml
name: プロジェクト作成リクエスト
description: 新しい DevOps Landing Zone プロジェクトの作成をリクエストします。
title: '[新規プロジェクト]: '
labels: ['gitops-project-request']
body:
  - type: input
    id: project-name
    attributes:
      label: プロジェクト名
      placeholder: contoso-ecommerce
    validations:
      required: true

  - type: dropdown
    id: vcs-platform
    attributes:
      label: VCS プラットフォーム
      options:
        - github
        - azuredevops
    validations:
      required: true

  - type: dropdown
    id: network-mode
    attributes:
      label: ネットワークモード
      options:
        - platform
        - byo
    validations:
      required: true

  - type: textarea
    id: repositories
    attributes:
      label: リポジトリ
      description: '1 行に 1 つ: 名前:プロファイル:説明'
      placeholder: |
        contoso-ecommerce-infra:infra:Azure インフラストラクチャ
        contoso-ecommerce-api:app:バックエンド API サービス
    validations:
      required: true

  - type: textarea
    id: subscriptions
    attributes:
      label: Azure サブスクリプション
      description: '1 行に 1 つ: 環境:サブスクリプション ID'
      placeholder: |
        development:22222222-2222-2222-2222-222222222222
        production:44444444-4444-4444-4444-444444444444
    validations:
      required: true
```

### 10.6 プロビジョニングワークフロー

PR マージ時、`project-create.yaml` ワークフローは:

1. `projects/` 内の新規/変更された YAML ファイルを検出する。
2. 新規または変更されたプロジェクト定義ごとに:
   a. YAML を Terraform `tfvars` フォーマットに変換する。
   b. 適切なバックエンド設定（状態キー: `projects/<project_name>.terraform.tfstate`）で `terraform init` を実行する。
   c. `terraform plan` を実行し、監査用にワークフローログ/アーティファクトにプラン出力を保存する。
   d. プラットフォーム VNet 内のセルフホステッドランナー上で `terraform apply` を実行する（tfstate ストレージやプライベートエンドポイント背後の Azure リソースへのプライベートネットワークアクセスのため）。

> **検証に関する注記:** このワークフローは `main` への `push` 時に実行されるため、このジョブコンテキストでは PR コメントは利用できない。マージ前にプランフィードバックを PR に投稿する必要がある場合は、マージ前に `plan` を実行する別の `pull_request` 検証ワークフローを追加する。

```yaml
# .github/workflows/project-create.yaml（簡略版）
name: DevOps プロジェクトのプロビジョニング
on:
  push:
    branches: [main]
    paths: ['projects/**']

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      files: ${{ steps.changed.outputs.files }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - id: changed
        run: |
          FILES=$(git diff --name-status ${{ github.event.before }} ${{ github.sha }} \
            | awk '$1~/[AM]/ && $2 ~ /^projects\/.*\.yaml$/ {print $2}' \
            | jq -R -s -c 'split("\n") | map(select(length > 0))')
          echo "files=$FILES" >> "$GITHUB_OUTPUT"

  provision:
    needs: detect-changes
    if: needs.detect-changes.outputs.files != '[]'
    runs-on: [self-hosted, devops-lz] # プラットフォームランナー上で実行
    strategy:
      fail-fast: false
      matrix:
        file: ${{ fromJson(needs.detect-changes.outputs.files) }}
    steps:
      - uses: actions/checkout@v4
      - name: YAML を tfvars に変換して適用
        run: |
          PROJECT_NAME=$(yq '.project_name' ${{ matrix.file }})
          VCS_PLATFORM=$(yq '.vcs_platform' ${{ matrix.file }})
          # ... YAML を terraform.tfvars に変換して tfvars ファイルに書き込み
          # IaC モジュールはこのリポジトリの infra/ 配下にある
          cd infra/project_${VCS_PLATFORM}
          terraform init -backend-config="key=projects/${PROJECT_NAME}.terraform.tfstate"
          terraform plan -out=tfplan
          # 注: PR のレビュー/承認 (CODEOWNERS) が承認ゲートとして機能する。
          # プランは既に PR 経由でレビュー済みのため、自動承認は安全。
          terraform apply tfplan
```

### 10.7 既存プロジェクトへのリポジトリ追加

既存のプロジェクトに新しいリポジトリを追加するには:

1. 「リポジトリ追加リクエスト」テンプレートを使用して Issue を作成する（または直接 YAML を編集する）。
2. ワークフローがプロジェクトの YAML ファイルに新しいリポジトリエントリを追加する PR を生成する。
3. CODEOWNERS がレビューし承認する。
4. マージ時、`terraform apply` が増分的に実行される — 新しいリポジトリとその関連リソースのみが作成される。

これは **増分的** である — Terraform の `repositories` に対する `for_each` により、新しいリポジトリのみがプロビジョニングされ、既存のものは変更されない。

### 10.8 既存の手動ワークフローとの関係

GitOps オンボーディングは **追加的かつオプション** である。現在の手動ワークフロー（`terraform.tfvars` + `terraform apply`）は引き続き動作する。組織は以下を選択できる:

| アプローチ                      | 使用場面                                                             |
| ------------------------------- | -------------------------------------------------------------------- |
| **手動** (`terraform.tfvars`)   | 小規模チーム、初期セットアップ、一回限りのプロジェクト               |
| **GitOps** (Issue → PR → apply) | エンタープライズ、多数のプロジェクト、監査証跡が必要、セルフサービス |

> **注記:** GitOps を使用する場合、GitOps リポジトリ内のプロジェクト YAML 定義が **信頼できる情報源** となる。これらは `terraform.tfvars` と同等だが、レビュー/承認ワークフローが組み込まれている。

---

## 関連する決定

- [ADR-003](./ADR-003-project-multi-repo-model.ja.md)
