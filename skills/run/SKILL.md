---
name: run
description: 承認済みのEpic issueに対して、Docker sandbox内でgenerator+evaluatorが完全自律で開発を進める。
argument-hint: "#[epic issue番号]"
disallowed-tools: AskUserQuestion
---

## 目的

承認済みの Epic issue $ARGUMENTS 配下の全Task issueを、Docker sandbox内でgenerator+evaluatorの2エージェント体制で完全自律的に完了させる。
全作業はEpicブランチ上で行い、mainブランチには直接変更を加えない。
**YOLOモード: ユーザー確認は一切行わず、完全自律で動作する。**

## パーミッション確認

YOLOモードで動作するためには、プロジェクトの `.claude/settings.json` で必要なBashコマンドが
`allow` に設定されている必要がある（推奨サンプルはREADME参照）。

- `deny` に `rm`, `rmdir`, `unlink` 等の破壊的コマンドを設定してブロック
- `allow` に `git`, `gh`, `docker`, ビルド・テスト系コマンドを設定して自動承認

未設定の場合、Bash実行のたびに「Do you want to proceed?」と確認が入り自律動作が中断される。

## 起動時の確認

!`gh issue view $ARGUMENTS 2>/dev/null || echo "ERROR: issue $ARGUMENTS が見つかりません"`

!`gh issue list --label "task" --state open --json number,title,labels,body --limit 100 2>/dev/null | head -200`

### Epicブランチの確認

Epic issue本文の「ブランチ」セクションからブランチ名を取得し、存在を確認する:

```bash
# Epic issueからブランチ名を取得
# Epic issueからブランチ名を取得 (形式: epic/epicXX/[機能名])
EPIC_BRANCH=$(gh issue view $ARGUMENTS --json body -q '.body' | grep -oP '`epic/epic\d+/[^`]+`' | tr -d '`' | head -1)

# ブランチの存在確認
git fetch origin
git rev-parse --verify "origin/${EPIC_BRANCH}" 2>/dev/null || echo "ERROR: ブランチ ${EPIC_BRANCH} が見つかりません"
```

### Docker sandbox の準備

実装・テスト用のDockerコンテナを起動する:

```bash
# プロジェクトルートに Dockerfile.dev があればビルド、なければ設定されたイメージを使用
if [ -f Dockerfile.dev ]; then
  docker build -f Dockerfile.dev -t dev-sandbox:$(basename $(pwd)) .
  SANDBOX_IMAGE="dev-sandbox:$(basename $(pwd))"
elif [ -f docker-compose.dev.yml ]; then
  docker compose -f docker-compose.dev.yml up -d
  SANDBOX_IMAGE="" # docker compose経由で実行
else
  echo "ERROR: Dockerfile.dev または docker-compose.dev.yml が見つかりません"
  echo "プロジェクトルートに開発用Dockerfileを配置してください"
  exit 1
fi
```

コンテナ内でコードをマウントし、全ての実装・テスト・ビルドコマンドをコンテナ内で実行する。
Gitオペレーション（commit, push等）はホスト側で実行する。

## 2エージェント体制

| エージェント | 役割 | 判断権限 |
|-------------|------|----------|
| **generator** | Docker内でコード実装・テスト・コミット | 実装方針の判断 |
| **evaluator** | Docker内でレビュー・テスト検証 | APPROVE / REQUEST_CHANGES |

## ブランチ戦略

```
main (保護: 人間のみマージ可)
 └─ epic/epicXX/[機能名] (Epic単位のブランチ)
     └─ generator worktree (Docker sandbox内で実装 → epicブランチにマージ)
```

- generatorはworktreeでEpicブランチをベースに作業する
- 実装・テスト・ビルドは全てDockerコンテナ内で実行する
- タスク完了後はEpicブランチにマージする（mainではない）
- 全タスク完了後、Epicブランチ→mainのPRを作成する
- mainへのマージは人間が行う

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

## 自律ループ（YOLOモード）

**ユーザー確認なしで**以下のサイクルを全Taskが完了するまで繰り返す:

### Step 1: 次のタスクを選定

未完了のTask issueからPhase順で次のタスクを選ぶ。

### Step 2: Epicブランチを最新に同期

**各タスク開始前に必ずEpicブランチを最新に同期する。**
前のタスクの変更が反映されていない古いベースでworktreeを作ると、コンフリクトやファイル不整合が発生する。

```bash
git fetch origin
git checkout ${EPIC_BRANCH}
git pull origin ${EPIC_BRANCH}
```

### Step 3: generator - Docker sandbox内でタスクを実装

generatorをworktreeで起動し、Docker sandbox内でEpicブランチ上のタスクを実装する:

```
@generator
Task #[番号] を実装してください。
- Epicブランチ: [epic/epicXX/機能名] （必ず最新を同期してから作業開始すること）
- Docker sandbox内で実装・テストを実行すること
- issueの要件を確認
- 親Epic issueの本文から仕様書・計画書を参照
- テストファーストで実装
- 全テストが通ることを確認（Docker内で実行）
- 変更をコミット
```

### Step 4: evaluator - Docker sandbox内で変更をレビュー

evaluatorにgeneratorの変更をレビューさせる:

```
@evaluator
Task #[番号] の変更をレビューしてください。
- Epicブランチ: [epic/epicXX/機能名]
- 変更差分を確認
- 親Epic issueの仕様書との照合
- チェックリストに基づくレビュー
- テストをDocker sandbox内で実行して検証
- APPROVE or REQUEST_CHANGES を判定
```

### Step 5: 結果に基づく分岐

- **APPROVE** の場合:
  1. 変更をEpicブランチにマージ（mainではない）
  2. Epicブランチをリモートにpush: `git push origin ${EPIC_BRANCH}`
  3. Task issueをクローズ: `gh issue close [番号]`
  4. Epic issueの進捗を更新
  5. → Step 1 に戻る（次のタスクへ）

- **REQUEST_CHANGES** の場合:
  1. evaluatorの指摘をgeneratorに伝える
  2. → Step 3 に戻る（修正）

## 進捗表示

各サイクルの開始時に進捗を表示する:

```
═══════════════════════════════════════
  Run: Epic $ARGUMENTS [YOLO]
  ブランチ: epic/epicXX/[機能名]
  Sandbox: Docker
  進捗: [完了数] / [全タスク数] tasks
  現在: Task #[番号] - [タスク名]
  Phase: [現在のPhase]
═══════════════════════════════════════
```

## 完了条件

以下がすべて満たされたらゴール達成:

1. Epic配下の全Task issueがクローズされている（スキップ分はissueにコメント済み）
2. Docker sandbox内で全テストが通っている
3. コンパイル/ビルドが成功する
4. **main向けPRが作成されている**

### PR作成（runの最終責務）

全タスク完了後、**必ずPRを作成する。** これがrunコマンドの最終出力であり、PRのURLを表示して完了とする。
PRを作成せずにrunを終了してはならない。

```bash
# Epicブランチの最新をpush
git push origin epic/epicXX/[機能名]

# mainへのPRを作成
gh pr create \
  --base main \
  --head "epic/epicXX/[機能名]" \
  --title "Epic: [機能名]" \
  --body "$(cat <<'BODY'
## Summary
Closes $ARGUMENTS

[仕様書の概要]

## 完了タスク
- [x] #XX Task: [タスク1]
- [x] #XX Task: [タスク2]
...

## Test plan
- [ ] 全テスト通過確認済み（Docker sandbox内）
- [ ] レビュー完了

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

**注意: Epic issueはクローズしない。PRがマージされた時点で人間がクローズする。**

## worktree クリーンアップ

**重要:** `git worktree remove` はworktree内のファイルを削除するが、`node_modules` 等がメインリポへのsymlinkの場合、symlink越しに実体ファイルが削除される。

worktreeを削除する前に、必ずsymlinkを解除すること:

```bash
# worktree内のsymlinkを解除してからworktreeを削除
cd [worktree-path]
find . -maxdepth 2 -type l -name "node_modules" -exec unlink {} \; 2>/dev/null || true
cd -
git worktree remove [worktree-path] --force 2>/dev/null || true
```

## Docker sandbox クリーンアップ

全タスク完了後またはエラー終了時にDockerリソースを停止・削除する:

```bash
# docker compose使用時
docker compose -f docker-compose.dev.yml down 2>/dev/null || true

# 単体コンテナ使用時
docker rm -f dev-sandbox-$(basename $(pwd)) 2>/dev/null || true
```

## 自律動作ポリシー（YOLOモード）

- **ユーザーへの確認・質問は一切行わない**
- 同一タスクで3回REQUEST_CHANGESが出た場合 → タスクをスキップし、issueにコメントを残して次のタスクへ進む
- テストが5回連続で失敗した場合 → issueにデバッグログをコメントし、次のタスクへ進む
- 予期しないエラーが発生した場合 → issueにエラー詳細をコメントし、次のタスクへ進む
- スキップしたタスクはEpic issueの進捗表示で明示する
- **mainブランチには絶対にマージしない**
- **テスト時に実ユーザーにメールを送信しないこと。** テスト用受信アドレス（mailhog, mailtrap等）が未設定の場合はタスクを中断し、issueにコメントを残して開発者に設定を促す
- **本番環境のデータは絶対に編集・削除・変更しないこと。** テストはDocker sandbox内のテスト用データのみ使用する
