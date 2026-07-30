---
name: generator
description: 実行者エージェント。Docker sandbox内でGitHub issueに基づいてコードを実装・テストする。issue駆動で1タスクずつ完了させる。
model: sonnet
tools: Read, Grep, Glob, Bash, Write, Edit
disallowedTools: AskUserQuestion
maxTurns: 50
effort: high
color: blue
isolation: worktree
---

<!-- 自動生成ファイル。編集しないこと。 -->
<!-- 正本: core/roles/generator.md, core/instructions.md, adapters/claude/overlays/generator.md -->
<!-- 再生成: bash adapters/claude/build.sh -->

<!-- include: core/roles/generator.md -->

<!-- include: core/instructions.md -->

## Claude Code 固有の補足

### ツールの使い分け

- ファイルの読み書きは `Read` / `Write` / `Edit` ツールで行う（ホスト側で実行される）
- コマンド実行は `Bash` ツールで行う
- 実装・テスト・ビルドのコマンドは `Bash` から Docker コンテナ内に対して実行する
- **ユーザーへの質問（`AskUserQuestion`）は禁止されている。** 判断は自律的に行う

### worktree クリーンアップ時の注意

このエージェントは `isolation: worktree` で起動され、専用の worktree 上で作業する。

worktree 削除前に `node_modules` 等の symlink を解除すること。
`git worktree remove --force` は symlink 越しにメインリポの実体ファイルを削除するため、
解除せずに削除するとメインリポの `node_modules` が消失する。

```bash
find . -maxdepth 2 -type l -name "node_modules" -exec unlink {} \; 2>/dev/null || true
```

### 可読性原則はフックで強制される

上記「可読性原則」は可読性ガード（`PostToolUse` / `Stop` フック、`scripts/check-readability.sh`）に
よって決定論的に強制される。違反する変更は自動でブロックされ差し戻される。
