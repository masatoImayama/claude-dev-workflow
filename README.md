# Dev Workflow Plugin for Claude Code

3エージェント自律開発ワークフロー。  
仕様ヒアリングからGitHub issue管理、自律実装までを一気通貫で行うClaude Codeプラグイン。

## ワークフロー

```
/dev-workflow:grill-me [機能名]    仕様を徹底ヒアリング → 仕様サマリー出力
         ↓
/dev-workflow:spec [機能名]        仕様書 + 実装計画書を docs/specs/ に作成
         ↓
/dev-workflow:epic [機能名]        Epic issue + Task issue をGitHubに作成
         ↓
/dev-workflow:goal #[epic番号]     3エージェントで自律開発ループ開始
```

## 3エージェント

| エージェント | 役割 | モデル |
|---|---|---|
| **Planner** (紫) | 仕様把握・タスク選定・依存関係管理 | Opus |
| **Executor** (青) | worktree隔離でコード実装・テスト | Sonnet |
| **Reviewer** (緑) | 読み取り専用でレビュー・判定 | Opus |

## インストール

```bash
/plugin install https://github.com/masatoImayama/claude-dev-workflow.git
```

または、ローカルでテスト:

```bash
claude --plugin-dir /path/to/claude-dev-workflow
```

## プロジェクト固有のカスタマイズ

このプラグインはプロジェクトの `CLAUDE.md` を自動的に読み込みます。  
プロジェクト固有のルール（コーディング規約、禁止事項、設計思想）は `CLAUDE.md` や `.claude/rules/` に記載してください。  
エージェントはそれらのルールに従って動作します。

## 前提条件

- [GitHub CLI (`gh`)](https://cli.github.com/) がインストール・認証済みであること
- Git リポジトリ内で実行すること

## ライセンス

MIT
