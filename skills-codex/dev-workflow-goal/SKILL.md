---
name: dev-workflow-goal
description: 計画から実装・レビュー・PR作成までを一気通貫で実行する。planner が計画し、ユーザー承認後に generator/evaluator が自律実装する。
---

# Dev Workflow Goal（Codex）

計画フェーズと実行フェーズを一気通貫で回す。

```
dev-workflow-plan（planner）→ ユーザー承認 → dev-workflow-run（generator + evaluator）
```

## Phase 1: 計画

`dev-workflow-plan` の手順を実行する。

## Phase 2: ユーザー承認

planner の出力を確認し、承認を求める。

```
══════════════════════════════════════════
  計画フェーズ完了
  Epic: #<番号> - <機能名>
  ブランチ: epic/epic<番号>/<機能名>
  Tasks: <件数> 件

  仕様書・計画書: Epic issue本文に添付済み
══════════════════════════════════════════

上記の内容で実装を開始してよろしいですか？
（承認後は確認なしで自律実行します）
```

- **承認された場合** → Phase 3 へ（以降ユーザー確認なし）
- **修正が必要な場合** → planner に修正を依頼

## Phase 3: 自律実装

`dev-workflow-run` の手順を Epic issue 番号に対して実行する。
自律実行の開始記録・機械的ゲート・Epic一括レビュー・PR作成・完了通知まで含む。

## 注意

ヘッドレス実行（`codex exec`）では Phase 2 の承認が取れない。
無人で回す場合は Phase 1 と Phase 3 を分け、人間が issue を確認してから
`adapters/codex/run-loop.sh` を起動する運用にする。
