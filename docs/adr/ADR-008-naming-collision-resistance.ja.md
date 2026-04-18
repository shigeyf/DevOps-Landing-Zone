[English](./ADR-008-naming-collision-resistance.md) | [日本語](./ADR-008-naming-collision-resistance.ja.md)

# ADR-008: 命名規則・状態管理・衝突耐性

> **ステータス:** 承認済み
> **コンテキスト:** [ターゲットアーキテクチャ仕様](../Target-Architecture-Spec.ja.md)

## 概要

リソース命名はポートフォリオセーフなパターンを使用し、UAMIは可読性とAzureの128文字制限に収まるようにハッシュを組み合わせたアプローチを採用。

---

### 11.1 現在の命名規則

リソースは衝突を避けるためにランダムな 4 文字のサフィックス（`rand_id`）を使用する。命名パターンは:

```
<resource_type>-<project_name>-devops-<region_short>-<rand_id>
```

### 11.2 改善点

1. **ポートフォリオセーフな命名**: すべてのリソース名にカスタマイズ可能な `org_prefix`（LZ の `naming_suffix` から）を追加し、同じテナント内の複数の DevOps Landing Zone が衝突しないようにする:

   ```
   <resource_type>-<org_prefix>-<project_name>-<region_short>-<rand_id>
   ```

2. **Tfstate キー規則**: バックエンドキーのフォーマットを標準化する:

   ```
   projects/<project_name>.terraform.tfstate
   ```

   これにより、プロジェクトの状態が Blob コンテナー内の既知のプレフィックスの下に整理される。

3. **リポジトリ命名規則**: デフォルトのリポジトリ名は `<project_name>-<repo_role>` に従う:

   ```
   contoso-ecommerce-infra
   contoso-ecommerce-api
   contoso-ecommerce-templates
   ```

   ユーザーは `repositories` 変数で名前をオーバーライドできる。

4. **状態キーの安定性ガードレール**: バックエンドキーに不変の `project_id`（スラッグ/UUID ライクなトークン）を使用し、`project_name` は人間が読める表示専用にする:

   ```text
   projects/<project_id>.terraform.tfstate
   ```

   - `project_id` はプロジェクト作成時に一度設定され、変更してはならない。
   - 表示名が変更されても、バックエンドキーの変更は不要。
   - レガシープロジェクトでバックエンドキーフォーマットを変更する必要がある場合は、制御された操作として明示的に `terraform init -migrate-state` を実行する。

### 11.3 UAMI 命名規則

リポジトリごとの UAMI 名は、可読性と Azure の命名制限（最大 128 文字）のバランスを取る **混合** アプローチを使用する:

```
uami-<project>-<repo>-<hash>
```

| セグメント  | ソース                                               | 目的                                                                         |
| ----------- | ---------------------------------------------------- | ---------------------------------------------------------------------------- |
| `uami-`     | 固定プレフィックス                                   | リソースタイプの識別子                                                       |
| `<project>` | `var.project_name`                                   | 人間が読めるプロジェクト識別                                                 |
| `<repo>`    | `repositories` リストのリポジトリ名                  | 人間が読めるリポジトリ識別                                                   |
| `<hash>`    | `substr(sha256("<env>-<job_type>-<rand_id>"), 0, 8)` | 環境、ジョブタイプ、ランダムシードをエンコードした衝突耐性のあるサフィックス |

**主要な設計決定:**

- **プロジェクトとリポジトリは人間が読める**: Azure ポータルや CLI で UAMI を閲覧する際、オペレーターはどのプロジェクトとリポジトリに UAMI が属するかを即座に識別できる。
- **環境とジョブタイプはハッシュ化**: 環境（dev/staging/prod）とジョブタイプ（plan/apply）は名前に表示する必要がない — ハッシュにエンコードされている。オペレーターは Terraform の状態やリソースタグを通じてマッピングを確認できる。
- **ハッシュが衝突耐性を提供**: 8 文字の 16 進ハッシュ（SHA-256 から）はプロジェクト-リポジトリペアごとに約 40 億の組み合わせを提供し、十分以上である。
- **タグが完全なメタデータを保持**: 各 UAMI には、名前に依存しない完全なトレーサビリティのために `environment`、`job_type`、`project`、`repo` のタグを付けるべきである。

**名前の例:**

```
uami-contoso-ecom-infra-a3f7b2c1        # project=contoso-ecom, repo=infra, env=prod/apply
uami-contoso-ecom-infra-e9d4c8f0        # project=contoso-ecom, repo=infra, env=dev/plan
uami-contoso-ecom-api-7b2e1a9d          # project=contoso-ecom, repo=api, env=prod/apply
```

**`shared_identities = true` の場合**（後方互換モード）、`<repo>` セグメントは省略される:

```
uami-<project>-<hash>
```

**Terraform 実装のスケッチ:**

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

## 関連する決定

- [ADR-003](./ADR-003-project-multi-repo-model.ja.md)
