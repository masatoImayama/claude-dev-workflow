---
name: goal
description: 全自動YOLOモード。plannerが仕様ヒアリング〜issue作成を行い、承認後にDocker sandbox内でgenerator+evaluatorが完全自律実装する。
argument-hint: "[実装したい機能や仕様の説明]"
---

## 目的

計画フェーズ（plan）と実行フェーズ（run）を一気通貫で実行する全自動YOLOモード。
実装・テストは全てDocker sandbox内で行い、ユーザー確認なしで完全自律動作する。

## フロー

```
plan（planner）→ ユーザー承認 → run（generator + evaluator in Docker sandbox）[YOLO]
```

## Phase 1: 計画（@planner）

plannerに以下を依頼する:

```
@planner
「$ARGUMENTS」について計画フェーズを実行してください。

1. ユーザーに1つずつ質問し、仕様を確定させる
2. 仕様書と実装計画書を作成する（ファイル出力不要）
3. Epicブランチを作成する
4. GitHub issueを作成する（epic本文に仕様書・計画書を埋め込み + task）
5. 成果物の一覧を表示してユーザーに確認を求める
```

## Phase 2: ユーザー承認

plannerの出力を確認し、ユーザーに承認を求める:

```
══════════════════════════════════════════
  計画フェーズ完了
  Epic: #[番号] - [機能名]
  ブランチ: epic/epicXX/[機能名]
  Tasks: [タスク数] 件
  Sandbox: Docker
  
  仕様書・計画書: Epic issue本文に添付済み
══════════════════════════════════════════

上記の内容で実装を開始してよろしいですか？
（承認後はYOLOモードで完全自律実行します）
```

**承認された場合** → Phase 3 へ（以降ユーザー確認なし）
**修正が必要な場合** → plannerに修正を依頼

## Phase 3: 完全自律実装（@generator + @evaluator in Docker sandbox）[YOLO]

承認されたEpic issueに対して、Docker sandbox内でgeneratorとevaluatorの自律ループを開始する。
`/dev-workflow:run #[epic番号]` と同じ動作:

1. Docker sandboxを起動
2. 未完了Task issueをPhase順に選定
3. @generator がworktree上・Docker sandbox内で実装
4. @evaluator がDocker sandbox内でテスト検証・レビュー（APPROVE / REQUEST_CHANGES）
5. APPROVE → Epicブランチにマージ・タスククローズ → 次のタスクへ
6. REQUEST_CHANGES → generatorに修正依頼 → 再レビュー
7. 全タスク完了 → main向けPR作成（人間がレビュー・マージ）
8. Docker sandboxをクリーンアップ

## 自律動作ポリシー（YOLOモード）

- **Phase 3以降、ユーザーへの確認・質問は一切行わない**
- 同一タスクで3回REQUEST_CHANGES → タスクをスキップし、issueにコメントを残して次へ
- テスト5回連続失敗 → issueにデバッグログをコメントし、次のタスクへ
- 予期しないエラー → issueにエラー詳細をコメントし、次のタスクへ
- スキップしたタスクはPR本文に明示する
- **mainブランチには絶対にマージしない**
