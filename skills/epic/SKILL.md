---
name: epic
description: 仕様書・実装計画書からGitHub issueを作成する。epicラベル付きの親issueと、taskラベル付きの子issueを生成。
argument-hint: "[機能名]"
---

## 目的

`docs/specs/$ARGUMENTS/` の仕様書と実装計画書をもとに、GitHub issueを体系的に作成する。

## 手順

### 1. ドキュメントの読み込み

```bash
cat docs/specs/$ARGUMENTS/spec.md
cat docs/specs/$ARGUMENTS/plan.md
```

ファイルが見つからない場合は「先に `/dev-workflow:spec $ARGUMENTS` を実行してください」と案内する。

### 2. ラベルの確認・作成

```bash
gh label list | grep -q "epic" || gh label create "epic" --color "6f42c1" --description "機能単位のまとまり"
gh label list | grep -q "task" || gh label create "task" --color "0075ca" --description "実装タスク"
```

### 3. Epic issue の作成

仕様書の内容をもとに親issueを作成:

```bash
gh issue create \
  --title "Epic: [機能名]" \
  --label "epic" \
  --body "$(cat <<'BODY'
## 概要
[仕様書の概要セクション]

## 仕様書
docs/specs/[機能名]/spec.md

## 実装計画書
docs/specs/[機能名]/plan.md

## タスク一覧
(子issue作成後にチェックリストを更新)
BODY
)"
```

### 4. Task issue の作成

実装計画書の各タスクに対して子issueを作成:

```bash
gh issue create \
  --title "Task: [タスク名]" \
  --label "task" \
  --body "$(cat <<'BODY'
## 親Epic
#[epic番号]

## 概要
[タスクの詳細]

## 対象ファイル
- [ファイルパス]

## 完了条件
- [ ] [条件1]
- [ ] [条件2]
- [ ] テストが通る

## Phase
[Phase番号]
BODY
)"
```

### 5. Epic issue の更新

すべてのTask issueを作成したら、Epic issueのタスク一覧を子issue番号で更新:

```bash
gh issue edit [epic番号] --body "[更新したbody]"
```

### 6. 子issueの紐付け

GitHub CLIで子issueをepicに紐付ける:

```bash
gh issue develop [task番号] --issue [epic番号] 2>/dev/null || true
```

### 7. 完了報告

作成したissueの一覧を表示:

```
## 作成したissue

| # | タイトル | ラベル | Phase |
|---|---------|--------|-------|
| #XX | Epic: [機能名] | epic | - |
| #XX | Task: [タスク1] | task | 1 |
| #XX | Task: [タスク2] | task | 2 |
```

「`/dev-workflow:goal #[epic番号]` で自律的な実装を開始できます」と案内する。
