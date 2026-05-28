---
name: goal
description: Epic issueを指定し、配下の全Task issueが完了するまで3エージェント（計画者・実行者・レビュアー）が自律的に開発を進める。
argument-hint: "#[epic issue番号]"
disallowed-tools: AskUserQuestion
---

## 目的

Epic issue $ARGUMENTS 配下の全Task issueを、3エージェント体制で自律的に完了させる。

## 起動時の確認

!`gh issue view $ARGUMENTS 2>/dev/null || echo "ERROR: issue $ARGUMENTS が見つかりません"`

!`gh issue list --label "task" --state open --json number,title,labels,body --limit 100 2>/dev/null | head -200`

## 3エージェント体制

| エージェント | 役割 | 判断権限 |
|-------------|------|----------|
| **計画者 (Planner)** | タスク選定・依存関係管理・進捗追跡 | 作業順序の決定 |
| **実行者 (Executor)** | コード実装・テスト・コミット | 実装方針の判断 |
| **レビュアー (Reviewer)** | コードレビュー・品質保証 | APPROVE / REQUEST_CHANGES |

## 自律ループ

以下のサイクルを全Taskが完了するまで繰り返す:

### Step 1: 計画者 - 次のタスクを選定

計画者エージェントに以下を依頼する:
- Epic issue $ARGUMENTS の仕様書を確認する
- 未完了のTask issueを確認する
- 依存関係（Phase順）を考慮して次に着手すべきタスクを1つ選ぶ
- タスクの作業指示を作成する

```
@planner
Epic $ARGUMENTS の次のタスクを選定してください。
- 未完了タスク一覧を確認
- Phase順・依存関係を考慮
- 選定したタスクの作業指示を出力
```

### Step 2: 実行者 - タスクを実装

実行者エージェントをworktreeで起動し、選定されたタスクを実装する:

```
@executor
Task #[番号] を実装してください。
- issueの要件を確認
- テストファーストで実装
- 全テストが通ることを確認
- 変更をコミット
```

### Step 3: レビュアー - 変更をレビュー

レビュアーエージェントに実行者の変更をレビューさせる:

```
@reviewer
Task #[番号] の変更をレビューしてください。
- 変更差分を確認
- 仕様との照合
- チェックリストに基づくレビュー
- APPROVE or REQUEST_CHANGES を判定
```

### Step 4: 結果に基づく分岐

- **APPROVE** の場合:
  1. 変更をmainにマージ
  2. Task issueをクローズ: `gh issue close [番号]`
  3. Epic issueの進捗を更新
  4. → Step 1 に戻る（次のタスクへ）

- **REQUEST_CHANGES** の場合:
  1. レビュアーの指摘を実行者に伝える
  2. → Step 2 に戻る（修正）

## 進捗表示

各サイクルの開始時に進捗を表示する:

```
═══════════════════════════════════════
  Goal: Epic $ARGUMENTS
  進捗: [完了数] / [全タスク数] tasks
  現在: Task #[番号] - [タスク名]
  Phase: [現在のPhase]
═══════════════════════════════════════
```

## 完了条件

以下がすべて満たされたらゴール達成:

1. Epic配下の全Task issueがクローズされている
2. 全テストが通っている
3. コンパイル/ビルドが成功する

完了時:
```bash
gh issue close $ARGUMENTS
```

## 安全装置

- 同一タスクで3回REQUEST_CHANGESが出た場合、ユーザーに相談する
- テストが5回連続で失敗した場合、ユーザーに相談する
- 予期しないエラーが発生した場合、ユーザーに相談する
