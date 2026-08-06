---
name: epic
description: 仕様書・実装計画書からGitHub issueを作成する。epicラベル付きの親issueと、taskラベル付きの子issueを生成。
argument-hint: "[機能名]"
---

## 目的

会話中の仕様書と実装計画書をもとに、GitHub issueを体系的に作成する。
仕様書・計画書はEpic issue本文に直接埋め込む。
Epic専用のブランチ `epic/epicXX/[機能名]` を作成し、mainブランチには直接変更を加えない。

## ブランチ命名規則

```
epic/epic[issue番号]/[機能名]
```

例: Epic issue #42 で機能名が `notifications` の場合 → `epic/epic42/notifications`

## 手順

### 1. 仕様書・計画書の確認

会話履歴から仕様書と実装計画書を探す。
見つからない場合は「先に `/dev-workflow:spec $ARGUMENTS` を実行してください」と案内する。

### 2. ラベルの確認・作成

```bash
gh label list | grep -q "epic" || gh label create "epic" --color "6f42c1" --description "機能単位のまとまり"
gh label list | grep -q "task" || gh label create "task" --color "0075ca" --description "実装タスク"
```

### 3. Epic issue の作成（ブランチ名は後で更新）

仕様書・計画書の全内容をEpic issue本文に埋め込んで作成:

```bash
EPIC_NUMBER=$(gh issue create \
  --title "Epic: [機能名]" \
  --label "epic" \
  --body "$(cat <<'BODY'
## 概要
[仕様書の概要セクション]

## ブランチ
(ブランチ作成後に更新)

## タスク一覧
(子issue作成後にチェックリストを更新)

---

<details>
<summary>仕様書</summary>

[仕様書の全内容をここに埋め込む]

</details>

<details>
<summary>実装計画書</summary>

[実装計画書の全内容をここに埋め込む]

</details>
BODY
)" 2>&1 | grep -oP '\d+$')
```

### 4. Epicブランチの作成

Epic issue番号を使ってブランチを作成し、リモートにpushする:

```bash
EPIC_BRANCH="epic/epic${EPIC_NUMBER}/$ARGUMENTS"

git checkout main && git pull
git checkout -b "${EPIC_BRANCH}"
git push -u origin "${EPIC_BRANCH}"
```

### 5. Epic issue にブランチ名を反映

作成したブランチ名をEpic issue本文に更新:

```bash
# Epic issueのbodyの「(ブランチ作成後に更新)」を実際のブランチ名に置換して更新
gh issue edit ${EPIC_NUMBER} --body "[ブランチ名を反映したbody]"
```

ブランチセクションは以下の形式にする:
```
## ブランチ
`epic/epic[番号]/[機能名]`
```

### 6. Task issue の作成

実装計画書の各タスクに対して子issueを作成する。
`- Epic: #N` と `- 前提: #N` は `scripts/plan-waves.sh` がEpic絞り込みと依存グラフの構築に
使う行であり、**`plan-waves.sh` の書式が真実の源**である。`親 Epic:` や `先行:` のような
表記ゆれは受理されない（`plan-waves.sh` 側は変更しない）。`- 前提:` 行が無いタスクは
宣言漏れとみなされ、`plan-waves.sh` の fail-safe により自分より小さい番号の全タスクに
依存するものとして扱われ完全逐次にフォールバックするため、依存が無い場合も
`- 前提: なし` と明記する。記法・fail-safe・実行順序の決め方は共通ルールの
「タスクの粒度」「タスク選定順序」を参照する（ここでは繰り返さない）。

```bash
gh issue create \
  --title "Task: [タスク名]" \
  --label "task" \
  --body "$(cat <<'BODY'
## 親Epic
#[epic番号]

- Epic: #[epic番号]
- 前提: #[依存タスクのissue番号]（依存が無い場合は `- 前提: なし` と明記する）

## ブランチ
`epic/epic[番号]/[機能名]`

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

### 7. Epic issue の更新

すべてのTask issueを作成したら、Epic issueのタスク一覧を子issue番号で更新:

```bash
gh issue edit [epic番号] --body "[更新したbody]"
```

### 8. 子issueの紐付け

GitHub CLIで子issueをepicに紐付ける:

```bash
gh issue develop [task番号] --issue [epic番号] 2>/dev/null || true
```

### 9. 完了報告

作成したissueの一覧を表示:

```
## 作成したissue

| # | タイトル | ラベル | Phase |
|---|---------|--------|-------|
| #XX | Epic: [機能名] | epic | - |
| #XX | Task: [タスク1] | task | 1 |
| #XX | Task: [タスク2] | task | 2 |

ブランチ: epic/epicXX/[機能名]
```

「`/dev-workflow:run #[epic番号]` で自律的な実装を開始できます」と案内する。
