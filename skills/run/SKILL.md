---
name: run
description: 承認済みのEpic issueに対して、generatorとevaluatorの2エージェントで自律的に開発を進める。
argument-hint: "#[epic issue番号]"
disallowed-tools: AskUserQuestion
---

## 目的

承認済みの Epic issue $ARGUMENTS 配下の全Task issueを、generator+evaluatorの2エージェント体制で自律的に完了させる。

## 起動時の確認

!`gh issue view $ARGUMENTS 2>/dev/null || echo "ERROR: issue $ARGUMENTS が見つかりません"`

!`gh issue list --label "task" --state open --json number,title,labels,body --limit 100 2>/dev/null | head -200`

## 2エージェント体制

| エージェント | 役割 | 判断権限 |
|-------------|------|----------|
| **generator** | コード実装・テスト・コミット | 実装方針の判断 |
| **evaluator** | コードレビュー・品質保証 | APPROVE / REQUEST_CHANGES |

## タスク選定ロジック

plannerは介在しない。代わりに以下のルールで次のタスクを自動選定する:

1. Epic issueのbodyからタスク一覧を取得
2. 未クローズのTask issueをPhase順にソート
3. 同一Phase内では番号が小さい順
4. 最初の未完了タスクを選定

```bash
# 未完了タスクをPhase順で取得
gh issue list --label "task" --state open --json number,title,body --limit 50
```

## 自律ループ

以下のサイクルを全Taskが完了するまで繰り返す:

### Step 1: 次のタスクを選定

未完了のTask issueからPhase順で次のタスクを選ぶ。

### Step 2: generator - タスクを実装

generatorをworktreeで起動し、選定されたタスクを実装する:

```
@generator
Task #[番号] を実装してください。
- issueの要件を確認
- 仕様書 docs/specs/*/spec.md を参照
- テストファーストで実装
- 全テストが通ることを確認
- 変更をコミット
```

### Step 3: evaluator - 変更をレビュー

evaluatorにgeneratorの変更をレビューさせる:

```
@evaluator
Task #[番号] の変更をレビューしてください。
- 変更差分を確認
- 仕様書との照合
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
  1. evaluatorの指摘をgeneratorに伝える
  2. → Step 2 に戻る（修正）

## 進捗表示

各サイクルの開始時に進捗を表示する:

```
═══════════════════════════════════════
  Run: Epic $ARGUMENTS
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
