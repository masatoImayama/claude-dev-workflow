---
name: goal
description: 全自動モード。plannerが仕様ヒアリング〜issue作成を行い、ユーザー承認後にgenerator+evaluatorが自律実装する。
argument-hint: "[実装したい機能や仕様の説明]"
---

## 目的

計画フェーズ（plan）と実行フェーズ（run）を一気通貫で実行する全自動モード。

## フロー

```
plan（planner）→ ユーザー承認 → run（generator + evaluator）
```

## Phase 1: 計画（@planner）

plannerに以下を依頼する:

```
@planner
「$ARGUMENTS」について計画フェーズを実行してください。

1. ユーザーに1つずつ質問し、仕様を確定させる
2. docs/specs/ に仕様書と実装計画書を作成する
3. GitHub issueを作成する（epic + task）
4. 成果物の一覧を表示してユーザーに確認を求める
```

## Phase 2: ユーザー承認

plannerの出力を確認し、ユーザーに承認を求める:

```
══════════════════════════════════════════
  計画フェーズ完了
  Epic: #[番号] - [機能名]
  Tasks: [タスク数] 件
  
  仕様書: docs/specs/[機能名]/spec.md
  計画書: docs/specs/[機能名]/plan.md
══════════════════════════════════════════

上記の内容で実装を開始してよろしいですか？
```

**承認された場合** → Phase 3 へ
**修正が必要な場合** → plannerに修正を依頼

## Phase 3: 自律実装（@generator + @evaluator）

承認されたEpic issueに対して、generatorとevaluatorの自律ループを開始する。
`/dev-workflow:run #[epic番号]` と同じ動作:

1. 未完了Task issueをPhase順に選定
2. @generator がworktreeで実装
3. @evaluator がレビュー（APPROVE / REQUEST_CHANGES）
4. APPROVE → マージ・クローズ → 次のタスクへ
5. REQUEST_CHANGES → generatorに修正依頼 → 再レビュー
6. 全タスク完了 → Epic クローズ

## 安全装置

- 同一タスクで3回REQUEST_CHANGESが出た場合、ユーザーに相談する
- テストが5回連続で失敗した場合、ユーザーに相談する
- 予期しないエラーが発生した場合、ユーザーに相談する
