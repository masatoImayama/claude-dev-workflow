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

0. 自律実行の開始を記録（Slack通知が完了と途中停止を区別するため）
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-start "Epic #[epic番号]"
   ```
1. Docker sandboxを起動
2. 未完了Task issueをPhase順に選定
3. @generator がworktree上・Docker sandbox内で実装
4. 機械的ゲート（テスト・ビルド・可読性ガード）を通す — **ここでevaluatorは起動しない**
5. 通過 → Epicブランチにマージ・タスククローズ → 次のタスクへ / 失敗 → generatorに差し戻し
6. 全タスク完了 → @evaluator がEpic全差分を**一括レビュー**（起動はここが初回）
7. 指摘（high/medium）を review issue 化 → generatorが対応 → 差分だけ再レビュー（最大2巡）
8. main向けPR作成（未対応の指摘はPR本文に明記し、人間がレビュー・マージ）
9. Docker sandboxをクリーンアップ
10. 完全な完了を通知（PR作成に成功した場合のみ実行する）
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-complete \
     "全[N]タスク完了（スキップ[M]件）
   PR: [PRのURL]"
   ```
   ここに到達せず終了した場合は、Stopフックが「自律実行が停止」として自動通知する。

## 自律動作ポリシー（YOLOモード）

- **Phase 3以降、ユーザーへの確認・質問は一切行わない**
- 同一タスクで機械的ゲートに3回失敗 → タスクをスキップし、issueにコメントを残して次へ
- レビューはEpic完了後にまとめて1回。タスクごとにevaluatorを起動しない（コスト削減のため）
- テスト5回連続失敗 → issueにデバッグログをコメントし、次のタスクへ
- 予期しないエラー → issueにエラー詳細をコメントし、次のタスクへ
- スキップしたタスクはPR本文に明示する
- **mainブランチには絶対にマージしない**
