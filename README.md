# Dev Workflow Plugin for Claude Code

3エージェント自律開発ワークフロー。  
仕様ヒアリングからGitHub issue管理、自律実装までを一気通貫で行うClaude Codeプラグイン。

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

### ローカルでテスト（インストール不要）

```bash
claude --plugin-dir /path/to/claude-dev-workflow
```

## 前提条件

- [GitHub CLI (`gh`)](https://cli.github.com/) がインストール・認証済み
- Git リポジトリ内で実行
- 上記が満たされない場合、セッション開始時にブロックされます

## コマンド

### 段階的に実行

```
/dev-workflow:plan ユーザーがワンクリックで作業を開始できるボタンを追加したい
```
→ planner がヒアリング → 仕様書・計画書作成 → GitHub issue作成 → **ユーザー承認で停止**

```
/dev-workflow:run #123
```
→ 承認済みEpicに対して generator + evaluator が自律実装

### 全自動

```
/dev-workflow:goal リアルタイムで他ユーザーの存在が分かるプレゼンス機能を実装したい
```
→ plan → ユーザー承認 → run を一気通貫

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
| **generator** (青) | コード実装・テスト | Sonnet | worktree隔離 |
| **evaluator** (緑) | コードレビュー・品質保証 | Opus | 読み取り専用 |

## ワークフロー

```
/plan [自然言語の指示]
  │
  ├─ planner: 仕様ヒアリング（1問ずつ）
  ├─ planner: 仕様書作成 (docs/specs/*/spec.md)
  ├─ planner: 実装計画書作成 (docs/specs/*/plan.md)
  ├─ planner: Epic issue + Task issue 作成
  └─ ユーザー承認待ち
        │
        ▼
/run #[epic番号]
  │
  ├─ タスク選定（Phase順・自動）
  ├─ generator: worktreeで実装 + テスト
  ├─ evaluator: レビュー → APPROVE / REQUEST_CHANGES
  ├─ APPROVE → マージ → 次のタスクへ
  ├─ REQUEST_CHANGES → generator修正 → 再レビュー
  └─ 全タスク完了 → Epic クローズ
```

## 安全装置

- 同一タスクで3回REQUEST_CHANGES → ユーザーに相談
- テスト5回連続失敗 → ユーザーに相談
- 予期しないエラー → ユーザーに相談

## プロジェクト固有のカスタマイズ

エージェントはプロジェクトの `CLAUDE.md` と `.claude/rules/` を自動的に読み込みます。  
プロジェクト固有のルール（コーディング規約、禁止事項、設計思想）はそこに記載してください。

## ライセンス

MIT
