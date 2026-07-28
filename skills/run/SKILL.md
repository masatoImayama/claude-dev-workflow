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

**ファイルツール（Read/Edit/Write）の権限について**: 本 run は Epic 専用 worktree を
`.claude/worktrees/<epicN>` に作る（後述）。この配下は**リポジトリルートの一部**なので、
`permissions.additionalDirectories` にリポジトリルート（例: `.../github/<repo>`）を1つ入れておけば
worktree もサブエージェントの isolation worktree も**追加設定なしで自動許可**され、確認が入らない。
逆に worktree を `../<repo>-epicN` のような**リポジトリ外の兄弟ディレクトリに作ると許可外**となり、
generator の Read/Edit のたびに確認が入る（＝自律動作が止まる）。だから worktree は必ず
`.claude/worktrees/` 配下に作る。

## 起動時の確認

!`gh issue view $ARGUMENTS 2>/dev/null || echo "ERROR: issue $ARGUMENTS が見つかりません"`

!`gh issue list --label "task" --state open --json number,title,labels,body --limit 100 2>/dev/null | head -200`

### Epicブランチ + 作業 worktree の準備

Epic issue本文の「ブランチ」セクションからブランチ名を取得し、**Epic 専用の作業 worktree を
`.claude/worktrees/<epicN>` に作成**する（`../<repo>-epicN` のような**兄弟ディレクトリは作らない**）。

なぜ `.claude/worktrees/` 配下か:
- **並行 epic 実行**が可能（各 epic が独立した worktree を持つ）。
- worktree パスが**プロジェクトツリー内**に収まるため、`.claude/settings.json` の
  `additionalDirectories` がリポジトリルートを許可していれば **追加の権限設定なしで**
  ファイルツール（Read/Edit/Write）が自動許可される。`github` 直下の**他リポジトリには一切及ばない**
  （兄弟ディレクトリ方式だと other-project へ権限が漏れる or 毎回プロンプトが出る）。
- メインリポのチェックアウトを切り替えないので、他の作業を壊さない。

```bash
# Epic issueからブランチ名を取得 (形式: epic/epicXX/[機能名])
EPIC_BRANCH=$(gh issue view $ARGUMENTS --json body -q '.body' | grep -oP '`epic/epic\d+/[^`]+`' | tr -d '`' | head -1)
EPIC_NUM=$(printf '%s' "$EPIC_BRANCH" | grep -oP 'epic\d+' | head -1)   # 例: epic259

# ブランチの存在確認
git fetch origin
git rev-parse --verify "origin/${EPIC_BRANCH}" >/dev/null 2>&1 || { echo "ERROR: ブランチ ${EPIC_BRANCH} が見つかりません"; exit 1; }

# ローカル追跡ブランチを用意（無ければ origin から作成）
git show-ref --verify --quiet "refs/heads/${EPIC_BRANCH}" || git branch "${EPIC_BRANCH}" "origin/${EPIC_BRANCH}"

# Epic 専用 worktree を .claude/worktrees/<epicN> に作成（既存なら再利用）
EPIC_WT=".claude/worktrees/${EPIC_NUM}"
if [ -d "$EPIC_WT" ]; then
  git -C "$EPIC_WT" checkout "${EPIC_BRANCH}" 2>/dev/null || true
else
  git worktree add "$EPIC_WT" "${EPIC_BRANCH}"
fi
```

**重要**: 以降の**すべてのステップ**（Docker 準備・タスクループ・generator/evaluator 起動・
commit/push・PR 作成・クリーンアップ）は、この `$EPIC_WT`（= `.claude/worktrees/<epicN>`）を
**作業ディレクトリ**として実行すること（`cd "$EPIC_WT"` してから、または `git -C "$EPIC_WT"` で操作）。
**メインリポのチェックアウトを epic ブランチに切り替えてはならない**（兄弟 worktree も作らない）。

### 自律実行の開始を記録

Slack通知が「完全な完了」と「途中停止」を区別できるよう、ループ開始前にマーカーを置く:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-start "Epic #$ARGUMENTS"
```

worktree内から実行してもマーカーはメインリポのルートに置かれるため、実行場所は問わない。

### Docker sandbox の準備

**まず作業 worktree に移動してから**、実装・テスト用のDockerコンテナを起動する（以降 `pwd` は
`$EPIC_WT`。マウント・ビルドはこの worktree を基点に行う）:

```bash
cd "$EPIC_WT"   # 以降の作業ディレクトリを Epic 専用 worktree に固定

# Dockerfile.dev / docker-compose.dev.yml は worktree にも存在する（フルチェックアウトのため）
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

| エージェント | 役割 | 起動頻度 | 判断権限 |
|-------------|------|----------|----------|
| **generator** | Docker内でコード実装・テスト・コミット | タスクごと | 実装方針の判断 |
| **evaluator** | Epic全差分の一括レビュー | **Epicにつき1〜3回** | APPROVE / REQUEST_CHANGES |

### レビューはEpic単位でまとめて行う

**タスクごとにevaluatorを起動してはならない。** レビューは最もコストの高い工程であり、
タスクのたびにOpusで全文脈を読み直すとレビュー費用が実装費用を上回る。

代わりに:

1. **タスクごと**は機械的ゲート（テスト・ビルド・可読性ガード）だけで通す — LLM呼び出しなし
2. **全タスク完了後**にevaluatorを1回起動し、`main...epicブランチ` の全差分をレビュー
3. 指摘は**個別のissueに変換**し、generatorが対応する
4. 対応後は**その差分だけ**を再レビュー（最大2巡）

これにより、evaluatorの起動回数はタスク数に比例せず、Epicあたり1〜3回に固定される。

## ブランチ戦略

```
main (保護: 人間のみマージ可)
 └─ epic/epicXX/[機能名] (Epic単位のブランチ)
     └─ 作業 worktree: .claude/worktrees/epicXX/  ← このツリー内で全作業（許可済み領域・兄弟ディレクトリは作らない）
         └─ generator の isolation worktree (Docker sandbox内で実装 → epicブランチにマージ)
```

- Epic 専用 worktree は **`.claude/worktrees/<epicN>`** に作る（`../<repo>-epicN` の兄弟は作らない）。additionalDirectories はリポジトリルート許可で足り、他リポジトリに権限が及ばない。
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
同期は**メインリポではなく Epic 専用 worktree（`$EPIC_WT`）内で**行う。

```bash
cd "$EPIC_WT"            # 作業 worktree に居ることを保証
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

### Step 4: 機械的ゲート（LLMレビューなし）

**evaluatorは起動しない。** 以下をbashで実行し、結果だけで通過判定する:

```bash
cd "$EPIC_WT"

# 1) テスト（Docker sandbox内）— 落ちたら不合格
docker run --rm -v "$(pwd):/workspace" -w /workspace dev-sandbox:$(basename $(pwd)) [test-command]

# 2) ビルド/型チェック — プロジェクトに定義があれば実行
docker run --rm -v "$(pwd):/workspace" -w /workspace dev-sandbox:$(basename $(pwd)) [build-command]

# 3) 可読性ガード — 差分に対して実行（PostToolUseフックと同じ判定）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh" --git
```

- **全て通過** → Step 5 へ
- **いずれか失敗** → 失敗ログをgeneratorに渡して Step 3 に戻る（同一タスクで3回失敗したらスキップ）

品質・設計・セキュリティの観点はここでは見ない。**それらはEpic完了後の一括レビューで見る。**

### Step 5: Epicブランチに取り込んで次のタスクへ

1. 変更をEpicブランチにマージ（mainではない）
2. Epicブランチをリモートにpush: `git push origin ${EPIC_BRANCH}`
3. Task issueをクローズ: `gh issue close [番号]`
4. Epic issueの進捗を更新
5. → Step 1 に戻る（次のタスクへ）

全タスクが完了したら **「Epic一括レビュー」** へ進む。

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

## Epic一括レビュー（全タスク完了後・PR作成前）

全Task issueがクローズされた時点で、**ここで初めてevaluatorを起動する。**

### R1: 一括レビューの実行

```
@evaluator
Epic #$ARGUMENTS の全変更をレビューしてください。
- モード: epic-review
- 差分範囲: main...[epic/epicXX/機能名]
- 作業ディレクトリ: .claude/worktrees/[epicN]
- 親Epic issueの仕様書と照合し、実装漏れも指摘すること
- テストをDocker sandbox内で実行して検証すること
- 最後に必ずJSONブロック（verdict / reviewed_commit / findings）を出力すること
```

### R2: 指摘をissue化

evaluatorの出力末尾のJSONを読み、**high と medium の指摘だけ**をissueにする。
low は issue化せず、PR本文の「レビューで挙がった軽微な指摘」に列挙するだけに留める。

JSONのパースは**あなた（runの実行者）が直接行う。** `jq` は環境によっては入っていないため、
パイプラインで機械的に処理しようとしない。findingsを読み取り、1件ずつ以下を実行する:

```bash
# reviewラベルを用意（初回のみ。既存なら --force で上書き）
gh label create review --color B60205 --description "一括レビューの指摘" --force

# 指摘1件につき1つのissueを作成（[]内はfindingの値で置き換える）
gh issue create --label "task,review" --title "Review: [title]" --body "$(cat <<'BODY'
## 指摘（重要度: [severity]）

[detail]

## 該当箇所
`[location]`

## 修正方針
[fix]

## 由来
- Epic: #[epic番号]
- 起因タスク: [task_ref]
- レビュー時点: `[reviewed_commit]`
BODY
)"
```

`reviewed_commit` は次の delta-review の起点になるので、**必ず控えておく。**

作成したissueの番号一覧をEpic issueにコメントし、追跡できるようにする。

### R3: 指摘対応ループ

`APPROVE` なら何もせずPR作成へ進む。`REQUEST_CHANGES` の場合:

1. 作成した review issue を**1件ずつ** generator に渡して修正させる（通常のタスクと同じ Step 3〜5）
2. 全件対応したら **delta-review** で再レビューする:

```
@evaluator
Epic #$ARGUMENTS の指摘対応を確認してください。
- モード: delta-review
- 差分範囲: [R1のreviewed_commit]..[epic/epicXX/機能名]
- 指定範囲外の蒸し返しはしないこと
- 最後に必ずJSONブロックを出力すること
```

3. `APPROVE` → PR作成へ / `REQUEST_CHANGES` → R2 に戻る

### R4: 打ち切り条件

**レビューは最大2巡まで**（初回 + delta-review 1回。合わせてevaluator起動は最大3回）。

2巡目でも `REQUEST_CHANGES` が残る場合は、**そこで打ち切ってPRを作成する。**
未対応の指摘は:

1. issueは**オープンのまま残す**（クローズしない）
2. PR本文の「未対応の指摘」セクションに issue 番号付きで列挙する
3. 人間のレビュアーがPR上で判断する

無限ループでコストを溶かすより、人間に判断を渡す方が安い。

### レビュー粒度の調整

Epicが大きく差分が膨大になる場合（目安: 変更50ファイル超）は、
R1をPhase単位に分割して起動してよい。その場合も**タスク単位には戻さない**。

```
@evaluator
Epic #$ARGUMENTS のうち Phase 1 の変更をレビューしてください。
- 差分範囲: main...[epic-branch] のうち [Phase1で変更されたファイル群]
```

## 完了条件

以下がすべて満たされたらゴール達成:

1. Epic配下の全Task issueがクローズされている（スキップ分はissueにコメント済み）
2. Docker sandbox内で全テストが通っている
3. コンパイル/ビルドが成功する
4. **Epic一括レビューが実施されている**（APPROVE、または2巡で打ち切り済み）
5. **main向けPRが作成されている**

### PR作成（runの最終責務）

一括レビューまで終えたら、**必ずPRを作成する。** これがrunコマンドの最終出力であり、PRのURLを表示して完了とする。
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

## レビュー結果
- 一括レビュー: [APPROVE / 2巡で打ち切り]
- 対応済みの指摘: #XX, #XX

### 未対応の指摘（人間の判断が必要）
- [ ] #XX [タイトル] — [なぜ未対応か]

### レビューで挙がった軽微な指摘（issue化せず記録のみ）
- [重要度lowの指摘]

## Test plan
- [ ] 全テスト通過確認済み（Docker sandbox内）
- [ ] レビュー完了

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

**注意: Epic issueはクローズしない。PRがマージされた時点で人間がクローズする。**

### 完了通知（PR作成後）

PRのURLが取れた時点が「完全な完了」。ここでのみ完了通知を出す:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-complete \
  "全[N]タスク完了（スキップ[M]件）
PR: [PRのURL]"
```

**この行に到達せずrunが終了した場合、Stopフックが自動的に「自律実行が停止」として通知する。**
そのため、エラーで中断する場合も含め、成功時以外にこのコマンドを実行してはならない。

## worktree クリーンアップ

**重要:** `git worktree remove` はworktree内のファイルを削除するが、`node_modules` 等がメインリポへのsymlinkの場合、symlink越しに実体ファイルが削除される。また**カレントディレクトリが対象 worktree 内だと削除できない**ため、必ずメインリポのルートへ戻ってから削除する。

Epic 専用 worktree（`.claude/worktrees/<epicN>`）は **PR 作成後**に削除してよい（epic ブランチは
origin に push 済みのため安全）。フォローアップ修正で使い続けたい場合は残しておいてもよい。

```bash
# 1) メインリポのルートへ戻る（対象 worktree の中からは remove できない）
MAIN_ROOT=$(git -C "$EPIC_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')
cd "$MAIN_ROOT" 2>/dev/null || cd "$(git rev-parse --show-toplevel)"

# 2) symlink（node_modules 等）を解除してから Epic 専用 worktree を削除
if [ -d "$EPIC_WT" ]; then
  find "$EPIC_WT" -maxdepth 2 -type l -name "node_modules" -exec unlink {} \; 2>/dev/null || true
  git worktree remove "$EPIC_WT" --force 2>/dev/null || true
fi

# 3) generator の isolation worktree（.claude/worktrees/agent-*）はハーネスが自動整理するが、
#    残存していれば prune で登録を掃除する
git worktree prune
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
- 同一タスクで機械的ゲートに3回失敗した場合 → タスクをスキップし、issueにコメントを残して次のタスクへ進む
- テストが5回連続で失敗した場合 → issueにデバッグログをコメントし、次のタスクへ進む
- **タスクループ中にevaluatorを起動しない**（レビューはEpic完了後の一括レビューのみ）
- Epic一括レビューは最大2巡で打ち切り、未対応の指摘はissueを残したままPR本文に明記する
- 予期しないエラーが発生した場合 → issueにエラー詳細をコメントし、次のタスクへ進む
- スキップしたタスクはEpic issueの進捗表示で明示する
- **mainブランチには絶対にマージしない**
- **テスト時に実ユーザーにメールを送信しないこと。** テスト用受信アドレス（mailhog, mailtrap等）が未設定の場合はタスクを中断し、issueにコメントを残して開発者に設定を促す
- **本番環境のデータは絶対に編集・削除・変更しないこと。** テストはDocker sandbox内のテスト用データのみ使用する
