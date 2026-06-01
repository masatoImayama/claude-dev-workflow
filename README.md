# Dev Workflow Plugin for Claude Code

3エージェント自律開発ワークフロー。  
Docker sandbox内でplanner・generator・evaluatorによる仕様策定から自律実装までを一気通貫で行うClaude Codeプラグイン。

## インストール

### 1. マーケットプレイスを追加

```bash
claude plugin marketplace add https://github.com/masatoImayama/claude-dev-workflow-marketplace.git
```

### 2. プラグインをインストール

```bash
claude plugin install dev-workflow@dev-workflow-marketplace
```

### 3. セッションを再起動

```bash
claude
```

### プラグインの更新（インストール済みの場合）

プラグインが更新された場合、以下の手順で再反映できます:

```bash
# 方法1: マーケットプレイスを更新してリロード
/plugin marketplace update dev-workflow-marketplace
/reload-plugins
```

```bash
# 方法2: 再インストール
/plugin uninstall dev-workflow@dev-workflow-marketplace
/plugin install dev-workflow@dev-workflow-marketplace
/reload-plugins
```

### ローカルでテスト（インストール不要）

```bash
claude --plugin-dir /path/to/claude-dev-workflow
```

## 前提条件

- [GitHub CLI (`gh`)](https://cli.github.com/) がインストール・認証済み
- [Docker](https://docs.docker.com/get-docker/) がインストール・起動済み
- Git リポジトリ内で実行
- プロジェクトルートに `Dockerfile.dev` または `docker-compose.dev.yml` を配置
- 上記が満たされない場合、セッション開始時にブロックされます

### 自動設定（SessionStart時）

プラグインのセッション開始フックが以下を自動的に行います:

- **`gh auth setup-git`** — gitの認証をgh CLIに委任し、push/PR作成時のアカウント選択ポップアップを防止
- **Docker起動チェック** — Docker デーモンが未起動の場合にブロック

## Docker sandbox のセットアップ

プロジェクトルートに開発用Dockerfileを配置してください:

```dockerfile
# Dockerfile.dev の例
FROM node:20-alpine
WORKDIR /workspace
COPY package*.json ./
RUN npm ci
# テスト・ビルドに必要なツールをインストール
```

DB等の依存サービスが必要な場合は `docker-compose.dev.yml` を使用:

```yaml
# docker-compose.dev.yml の例
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/workspace
    working_dir: /workspace
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: dev
```

## コマンド

### 段階的に実行

```
/dev-workflow:plan ユーザーがワンクリックで作業を開始できるボタンを追加したい
```
→ planner がヒアリング → 仕様書・計画書作成 → GitHub issue作成 → **ユーザー承認で停止**

```
/dev-workflow:run #123
```
→ 承認済みEpicに対して Docker sandbox内で generator + evaluator が**YOLOモードで完全自律実装**

### 全自動

```
/dev-workflow:goal リアルタイムで他ユーザーの存在が分かるプレゼンス機能を実装したい
```
→ plan → ユーザー承認 → Docker sandbox内でYOLO run を一気通貫

### 個別スキル

```
/dev-workflow:grill-me WebSocket経由のリアルタイム通知を検討したい
/dev-workflow:spec notifications
/dev-workflow:epic notifications
```

## 3エージェント

| エージェント | 役割 | モデル | 特徴 |
|---|---|---|---|
| **planner** (紫) | 仕様ヒアリング・計画・issue管理 | Opus | 書き込み可 |
| **generator** (青) | Docker sandbox内でコード実装・テスト | Sonnet | worktree隔離 + Docker |
| **evaluator** (緑) | Docker sandbox内でレビュー・テスト検証 | Opus | 読み取り専用 + Docker |

## ワークフロー

```
/plan [自然言語の指示]
  │
  ├─ planner: 仕様ヒアリング（1問ずつ）
  ├─ planner: 仕様書・実装計画書作成
  ├─ planner: Epicブランチ作成 (epic/epicXX/[機能名])
  ├─ planner: Epic issue作成（仕様書・計画書を本文に添付）
  ├─ planner: Task issue 作成
  └─ ユーザー承認待ち
        │
        ▼
/run #[epic番号]  [YOLO]
  │
  ├─ Epicブランチの確認
  ├─ Docker sandbox 起動
  ├─ タスク選定（Phase順・自動）
  ├─ generator: Docker sandbox内でEpicブランチ上に実装 + テスト
  ├─ evaluator: Docker sandbox内でレビュー + テスト検証
  ├─ APPROVE → Epicブランチにマージ → 次のタスクへ
  ├─ REQUEST_CHANGES → generator修正 → 再レビュー
  ├─ 全タスク完了 → main向けPR作成（人間がレビュー・マージ）
  └─ Docker sandbox クリーンアップ
```

## ブランチ戦略

```
main (保護: 人間のみマージ可)
 ├─ epic/epic10/feature-a  ← Epic #10 の全タスク
 ├─ epic/epic11/feature-b  ← Epic #11 の全タスク（並行開発可）
 └─ ...
```

- 各Epicは専用ブランチで開発し、mainには直接変更を加えない
- 複数Epicの並行開発に対応（ブランチ・Docker sandboxが独立）
- 各タスク開始前にEpicブランチを最新に同期（古いベースからの分岐を防止）
- 全タスク完了後にmain向けPRを作成し、人間がレビュー・マージする

### worktree運用の注意

`node_modules` 等がsymlinkの場合、`git worktree remove --force` がsymlink越しにメインリポの実体ファイルを削除する。worktree削除前に必ずsymlinkを解除すること。

## YOLOモード（完全自律動作）

実装フェーズ（run）ではユーザー確認を一切行わず完全自律で動作する。

### パーミッション設定（必須）

YOLOモードではClaude Code本体のパーミッション確認を無効化する必要がある。
プロジェクトの `.claude/settings.json` に許可・拒否コマンドを設定する:

```json
{
  "permissions": {
    "deny": [
      "Bash(rm *)",
      "Bash(rm)",
      "Bash(rmdir *)",
      "Bash(unlink *)",
      "Bash(shred *)",
      "Bash(* rm *)",
      "Bash(* rmdir *)",
      "PowerShell(Remove-Item *)",
      "PowerShell(* Remove-Item *)",
      "PowerShell(del *)",
      "PowerShell(* del *)",
      "PowerShell(rd *)",
      "PowerShell(* rd *)"
    ],
    "allow": [
      "Bash(*)",
      "PowerShell(*)",
      "Edit",
      "Write",
      "NotebookEdit"
    ]
  }
}
```

> **ルール優先度:** `deny` は `allow` より常に優先される。  
> `rm` 系コマンドはパイプや `&&` 経由でも個別にブロックされる。  
> プロジェクトのビルド・テストコマンドは `allow` に追加してください。

### 自律動作ポリシー

- ユーザーへの質問・確認は行わない
- 問題発生時はissueにコメントを残してスキップし、次のタスクへ進む
- 同一タスクで3回REQUEST_CHANGES → スキップ
- テスト5回連続失敗 → スキップ
- スキップしたタスクはPR本文に明示される

### テスト時の注意事項

- **メール送信:** テスト実行時に実ユーザーにメールが送信されないよう細心の注意を払うこと。テスト用の受信アドレス（mailhog, mailtrap等）が設定されていない場合は、タスクを中断し、issueにコメントを残して開発者（人間）にテスト用メール設定を促すこと
- **本番データの保護:** いかなる理由においても本番環境のデータを編集・削除・変更しないこと。本番データは常に非侵襲であること。テスト時はDocker sandbox内のテスト用データベースのみを使用すること

## プロジェクト固有のカスタマイズ

エージェントはプロジェクトの `CLAUDE.md` と `.claude/rules/` を自動的に読み込みます。  
プロジェクト固有のルール（コーディング規約、禁止事項、設計思想）はそこに記載してください。

## ライセンス

MIT
