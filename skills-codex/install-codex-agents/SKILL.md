---
name: install-codex-agents
description: planner/generator/evaluator のサブエージェント定義をこのプロジェクトの .codex/agents/ に設置する。dev-workflow を初めて使うときに実行する。
---

# Install Codex Agents

dev-workflow の3役（planner / generator / evaluator）を、このプロジェクトの
`.codex/agents/` に設置する。

## なぜ設置が必要か

Codex のプラグインマニフェストは `skills` / `hooks` / `mcpServers` / `apps` を配布できるが、
**サブエージェント定義（agents）は配布できない。** そのためプラグイン同梱の雛形を
プロジェクトにコピーする必要がある。

## 手順

```bash
bash "${CLAUDE_PLUGIN_ROOT}/adapters/codex/install-agents.sh" .
```

役割ごとにモデルを変えたい場合は環境変数で指定する（未指定なら親セッションまたは
`[agents] default_subagent_model` から継承される）。

```bash
DEV_WORKFLOW_CODEX_GENERATOR_MODEL=<実装向けモデル> \
DEV_WORKFLOW_CODEX_EVALUATOR_MODEL=<レビュー向けモデル> \
  bash "${CLAUDE_PLUGIN_ROOT}/adapters/codex/install-agents.sh" .
```

設置済みかどうかの確認:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/adapters/codex/install-agents.sh" --check .
```

## 設置後にやること

1. **`.codex/agents/` をコミットする。** Claude Code 障害時に生成処理を実行できない
   可能性があるため、平常時にコミットしておく
2. 可読性ガードを git 側にも二重化する（任意だが推奨）

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/adapters/common/install-git-hooks.sh" .
   ```

3. プラグイン同梱フックの信頼付与を求められたら承認する
   （承認しないと可読性ガードが働かない）

## 確認

設置後、`planner` / `generator` / `evaluator` がサブエージェントとして認識されることを確認する。
`.codex/agents/*.toml` は**生成物なので直接編集しない。**
ルールを変えたい場合はプラグイン側の `core/` を編集して再生成する。
