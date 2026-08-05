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
EPIC_NUM=$(printf '%s' "$EPIC_BRANCH" | grep -oP 'epic\d+' | head -1)   # 例: epic259（sandbox-exec.sh の --epic 用の識別子）
EPIC_ISSUE_NUM="${EPIC_NUM#epic}"   # 例: 259（plan-waves.sh の --epic 用。数値のEpic issue番号。ブランチ名の命名規則epic/epicXX上、epicXXの数値部分=Epic issue番号）

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

run マーカーが置かれた直後に、ハング・スリープを検知する watchdog を起動する（`--start`
自体は自己デタッチして**即座に返る**。監視ループはプロセス外で動く常駐プロセスに移る）。
watchdog は run マーカー（`.claude/.dev-workflow-run`）の消失を自己終了条件の1つにしているため、
**マーカーより後に起動すること**（先に起動するとマーカーがまだ無い一瞬で誤って自己終了しうる）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --start --epic "$EPIC_NUM" --label "Epic #$ARGUMENTS"
```

### Docker sandbox の準備

**まず作業 worktree に移動してから**、`sandbox-exec.sh` でサンドボックスを準備する（以降 `pwd` は
`$EPIC_WT`。マウント・イメージ解決はこの worktree を基点に行う）。

**`docker build` / `docker compose up` を直接叩いてはならない。** イメージのビルド・
コンテナの起動・compose サービスの起動はすべて `sandbox-exec.sh` に集約されている（後述）。
スキル側がやることは、`--print-plan` で解決結果を確認し、`--warm` を1回流すことだけである。

```bash
cd "$EPIC_WT"   # 以降の作業ディレクトリを Epic 専用 worktree に固定

# docker に一切触れず、解決結果（mode / container / image / compose_* 等）を表示する
PLAN="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --print-plan)"
echo "$PLAN"

if printf '%s\n' "$PLAN" | grep -q '^mode=none$'; then
  echo "ERROR: Dockerfile.dev または docker-compose.dev.yml が見つかりません"
  echo "プロジェクトルートに開発用Dockerfileまたはcomposeファイルを配置してください"
  exit 1
fi

# キャッシュを温める（イメージが無ければここで自動ビルドされる。最初のタスクにビルドコストを負担させない）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --warm '[build-command]'
```

コンテナ内でコードをマウントし、全ての実装・テスト・ビルドコマンドをコンテナ内で実行する。
Gitオペレーション（commit, push等）はホスト側で実行する。

#### プロジェクト固有の準備コマンド（Epic 本文の `## 準備コマンド` 節）

生成物の配置（wasm 等）のような**タスクに依らず同じ結果になる**プロジェクト固有の準備は、
タスクごとに generator へ繰り返させず、ここ（Epic 開始時）で1回だけ実行する。

```bash
# Epic本文に「## 準備コマンド」節があれば、その中身（フェンスコードブロックの内容）を取り出す
PREP_CMD="$(gh issue view $ARGUMENTS --json body -q '.body' \
  | awk '/^## 準備コマンド/{f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' | sed '1d;$d')"

if [ -n "$PREP_CMD" ]; then
  echo "Epic本文の準備コマンドを実行します:"
  echo "$PREP_CMD"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --warm "$PREP_CMD"
fi
```

- **節が無ければ何もしない**（上記の `[build-command]` による `--warm` だけが従来どおり走る）。
  既存の Epic（`## 準備コマンド` 節が無いもの）はこの追加ステップの影響を受けない
- `--warm` は失敗してもループを止めない（`sandbox-exec.sh` の既存挙動）。準備コマンドが失敗しても
  表示だけしてそのまま先へ進む
- コンテナは Epic 単位で常駐するため、この1回の準備が以降の全ウェーブ・全レーンに効く。
  generator 側には「タスクごとに再実行しない」旨を明記済み（`core/roles/generator.md`）

### サンドボックスへのコマンド投入は sandbox-exec.sh 経由に統一する

**`docker run` を直接組み立ててはならない。** 以下をすべて `scripts/sandbox-exec.sh` が引き受ける:

- **イメージの解決とビルド** — `Dockerfile.dev` があれば内容の hash でタグ付けして自動ビルドする
  （`DEV_WORKFLOW_DOCKER_IMAGE` を指定すれば既存イメージをそのまま使い、ビルドはしない）
- **ビルドキャッシュの永続化** — `docker run --rm` はコンテナ層を毎回捨てるため、`GOCACHE` 等に
  貯まったコンパイル結果が次回に残らない。言語ごとのキャッシュディレクトリを named volume 化する
  （対象パスは `DEV_WORKFLOW_CACHE_PATHS` で上書きできる）
- **コンテナの再利用** — Epic 単位で常駐させ `docker exec` で叩き、起動オーバーヘッドを消す。
  `--epic` を渡し忘れても環境変数 `DEV_WORKFLOW_EPIC` が設定されていれば同じコンテナに載る
- **Windows のパス変換対策** — Git Bash（MSYS）は `-w /workspace` を
  `C:/Program Files/Git/workspace` に変換してしまい、`docker run` がそのまま失敗する。
  `MSYS_NO_PATHCONV=1` と `pwd -W` で回避する
- **イメージタグの安定化** — タグをリポジトリ名基準（+ Dockerfile の内容 hash）にし、worktree
  ごとに別イメージをビルドし直す事故を防ぐ。COPY 対象だけを変更した場合は hash が変わらないため、
  その場合は `--rebuild` で強制的に再ビルド・コンテナ作り直しを行う

```bash
# 実行（複数コマンドは1回にまとめる。後述）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" 'make test'
```

終了コードは実行したコマンドのものがそのまま返るので、機械的ゲートの判定に使える。

### compose を使う場合の要求仕様

`docker-compose.dev.yml` を使う場合、素直に「ビルド・テストを実行する compose ファイル」を
書くと常駐サービスが存在せず `sandbox-exec.sh` が `exec` できない。次の要求仕様を満たすこと:

- **常駐サービス名**: 既定 `app`（`DEV_WORKFLOW_COMPOSE_SERVICE` で変更可）
- **マウント**: 当該サービスが `.:/workspace` をマウントすること
  （異なるマウント先にする場合は `DEV_WORKFLOW_COMPOSE_WORKDIR` で上書きする）
- **長時間常駐**: `sleep infinity` 等でプロセスが終了しないこと（サービスが running であり
  続けないと `sandbox-exec.sh` は `up -d` を試みた上で、原因の分かるエラーを出して停止する）
- **`container_name:` と固定ホストポート（例: `- "8080:8080"`）を使わないこと** —
  `sandbox-exec.sh` は `-p <project>` でプロジェクト名を epic 単位に分離するが、これらは
  `-p` では解決できない衝突であり、epic の並行実行ができなくなる。`sandbox-exec.sh` は
  検出時に stderr へ警告するが、自動では直せない

サンプル（そのまま貼り付けて使える最小構成）:

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/workspace
    working_dir: /workspace
    command: ["sleep", "infinity"]
```

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
 └─ epic/epicXX/[機能名] (Epic単位のブランチ。統合ゲートを通ったコミットだけが載る)
     └─ 作業 worktree: .claude/worktrees/epicXX/  ← このツリー内で全作業（許可済み領域・兄弟ディレクトリは作らない）
         └─ wave/epicXX/<ウェーブ番号>  ← レーンを取り込み統合ゲートに掛ける一時ブランチ（originへpushしない）
             └─ 各レーンの作業ブランチ（generator の isolation worktree 由来）
```

- Epic 専用 worktree は **`.claude/worktrees/<epicN>`** に作る（`../<repo>-epicN` の兄弟は作らない）。additionalDirectories はリポジトリルート許可で足り、他リポジトリに権限が及ばない。
- 各レーン（generator の isolation worktree）は、そのウェーブ開始時点のEpicブランチtip（`WAVE_BASE`）から分岐する
- レーンは wave ブランチを経由し、**統合ゲート通過後にのみ** `--ff-only` でEpicブランチへ合流する
- 実装・テスト・ビルドは全てDockerコンテナ内で実行する
- 全タスク完了後、Epicブランチ→mainのPRを作成する
- mainへのマージは人間が行う
- wave ブランチはローカルの一時ブランチであり、originへはpushしない。**Epicブランチへのforce pushは行わない**

## タスク選定・実行方式（ウェーブ単位の並列実行）

plannerは介在しない。タスクの実行順序は`- 前提: #N`が作る**依存グラフだけ**を根拠に決める
（`core/instructions.md`「タスク選定順序」参照）。Phaseは人間向けの区分であり、実行順序の決定には
使わない。ウェーブ分解は `scripts/plan-waves.sh` に切り出されており、散文としてこのスキルが
解釈し直すことはしない。

```bash
# ドライラン: 現在のウェーブ分解を人間向けに確認する（依存宣言のレビューにも使える）
# plan-waves.sh の --epic は数値のEpic issue番号（$EPIC_ISSUE_NUM）。sandbox-exec.sh の
# --epic（epicXX形式の $EPIC_NUM）とは別の契約なので取り違えないこと
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh" --epic "$EPIC_ISSUE_NUM" --lanes "$LANES" --print
```

### `--lanes`（並列度）の受け取り

- 既定は **3**。`$ARGUMENTS` に `--lanes N` が含まれていればそれを使う。無ければ環境変数
  `DEV_WORKFLOW_MAX_LANES` を使う。どちらも無ければ既定の3を使う（優先順位: `--lanes` 引数 >
  `DEV_WORKFLOW_MAX_LANES` > 既定3）
- **ホスト性能からの自動算出はしない**（ボトルネックはI/Oでありコア数と相関しないため）
- **`--lanes 1` を指定すると、現行（並列化前）と等価な逐次実行になる。** 障害発生時のロール
  バック手段として使える。並列用と逐次用でコードパスを分けていないため、値を変えるだけで
  安全に落とせる

```bash
LANES="${DEV_WORKFLOW_MAX_LANES:-3}"
# $ARGUMENTS に --lanes N が含まれていれば LANES をその値で上書きする
```

## 自律ループ（YOLOモード、ウェーブ単位）

**ユーザー確認なしで**、以下のサイクルをウェーブが無くなるまで繰り返す。

```bash
SKIPPED_CSV=""   # 3回失敗して見送ったタスク番号のカンマ区切り。ループを回すうちに積み上げる

# WAVE_NO: wave ブランチ名（wave/${EPIC_NUM}/${WAVE_NO}）に使う通し番号。
# plan-waves.sh の出力の「wave番号」とは別物（再計算のたびに wave 1 から始まり直すため、
# 通し番号はここで自前に管理する）。
#
# 0 から始めてはならない（Task #54）。中断→再開（`/dev-workflow:run` の再実行）では
# セッション変数が失われるため 0 から数え直すことになるが、`wave/${EPIC_NUM}/*` ブランチは
# ローカルに残り続ける（originへpushしない設計）。0 から始めると、前回の残骸である古い
# wave ブランチをそのまま掴んでしまい、`merge-lane.sh --create` がそれを「取り込み済み」と
# 誤認する（詳細は「ハングしたときに人間がすること」節の「再開する場合」を参照）。
# 既存の wave ブランチの番号の最大値の次から始めることで、再開時も必ず新しい wave ブランチが
# 使われる。
WAVE_NO=$(git for-each-ref --format='%(refname:short)' "refs/heads/wave/${EPIC_NUM}/*" \
  | sed "s#^wave/${EPIC_NUM}/##" | sort -n | tail -1)
WAVE_NO="${WAVE_NO:-0}"

# --- 計測（並列化とオーバーヘッド削減の寄与を分けて読むための実測。詳細は「進捗表示」節） ---
# 前ウェーブの内訳（次ウェーブ開始時のバナー表示に使う）。ウェーブ1の開始時点では空文字のまま。
PREV_WAVE_IMPL_SEC=""
PREV_WAVE_MERGE_SEC=""
PREV_WAVE_GATE_SEC=""
# Epic全体の累計（PR本文の集計に使う）
TOTAL_IMPL_SEC=0
TOTAL_MERGE_SEC=0
TOTAL_GATE_SEC=0
DONE_TASK_COUNT=0   # 統合ゲートを通過して取り込めたタスク数の累計

# 秒数を "Nm Ss" 形式にする（例: 65 -> 1m05s）。追加の依存物（jq等）は使わず `date +%s` の差分のみで計測する
fmt_duration() {
  local total_sec="$1"
  printf '%dm%02ds' "$((total_sec / 60))" "$((total_sec % 60))"
}
```

### Step 1: ウェーブ計画を取得する

**毎ウェーブ、計画を再計算する**（前ウェーブの完了・スキップを反映するため。1回だけ計算して
使い回さない）。完了したタスクは `gh issue list --state open` から自然に消えるため、
再計算のたびに残りのタスクだけを対象とした**新しいウェーブ1**が得られる。
すなわち、**出力の `wave 1 tasks ...` が常に「次に実行すべきウェーブ」である。**

```bash
cd "$EPIC_WT"
PLAN_ARGS=(--epic "$EPIC_ISSUE_NUM" --lanes "$LANES")
[ -n "$SKIPPED_CSV" ] && PLAN_ARGS+=(--skipped "$SKIPPED_CSV")
PLAN="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh" "${PLAN_ARGS[@]}")"
PLAN_EXIT=$?
echo "$PLAN"
```

- `PLAN_EXIT` が **3**（循環依存）なら、列挙されたタスクをそのままEpic issueにコメントし停止する
- `warn missing-deps <番号>` / `warn unknown-dep <番号> <dep番号>` が出力に含まれる場合、
  該当タスクの宣言漏れ・不明な依存を報告に含める（fail-safeで完全逐次扱いになっている旨も明記）
- 出力に `wave` 行が無い（＝全タスク完了）→ ループを終了し **「Epic一括レビュー」** へ進む
- `wave 1 tasks 4,5,10` のような行から、今回処理するタスク番号の集合を取り出す。各タスクの
  `subbatch` 列（`task` 行）を見て、サブバッチ単位に分割する
- 処理対象のウェーブが決まったら `WAVE_NO=$((WAVE_NO + 1))` する（wave ブランチ名
  `wave/${EPIC_NUM}/${WAVE_NO}` に使う通し番号。plan-waves.sh の出力の「wave番号」とは別物）

今回のウェーブの内容が決まったら、Step 2 に進む前に進捗バナーを表示する（形式は
「進捗表示」節を参照。`PREV_WAVE_*` はウェーブ1の実行前は空文字なので「前ウェーブ: (初回のため計測なし)」
と表示する）。

### Step 2: WAVE_BASE を記録する

```bash
cd "$EPIC_WT"            # 作業 worktree に居ることを保証
git fetch origin
git checkout "${EPIC_BRANCH}"
git pull origin "${EPIC_BRANCH}"
WAVE_BASE=$(git rev-parse HEAD)
IMPL_START_SEC=$(date +%s)   # 「実装」フェーズ（Step 3〜4）の計測開始
```

ウェーブ予算の監視（watchdog）に、このウェーブの内訳を伝える:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --wave --epic "$EPIC_NUM" \
  --wave-no "$WAVE_NO" --tasks "[今回のウェーブのタスク番号のカンマ区切り]"
```

**同期はここ（ウェーブの先頭）でだけ行う。** タスクごとには行わない。この `WAVE_BASE` が、
このウェーブに属する全レーンが共有する唯一の正しい分岐元になる。各レーン（generatorの
isolation worktree）はこの `WAVE_BASE` から分岐するため、generator自身は
`fetch` / `checkout` / `pull` を行わない（`core/roles/generator.md`）。

### Step 3: サブバッチごとに generator を並列起動する

ウェーブ内タスク数が `lanes` を超える場合、Step 1 で取得した `subbatch` 列に従い、
issue番号の小さい順に `lanes` 件ずつのサブバッチへ分割済みである。**統合ゲートはサブバッチ
ごとではなく、ウェーブの全サブバッチが完了した後に1回だけ行う。**

サブバッチ内のタスクは**同一メッセージで複数の generator を同時に起動する**（レーンA・B・C…）:

```
@generator
Task #[番号A] を実装してください（レーン A）。
- Epicブランチ: [epic/epicXX/機能名]
- WAVE_BASE: [WAVE_BASEのコミットハッシュ]（ブランチ名ではなくこのハッシュそのものに対して検証すること）
- 作業開始前に `git merge-base --is-ancestor "[WAVE_BASE]" HEAD` でベースを検証すること。
  偽なら実装を始めず、実出力を添えて報告し停止すること
- **`git fetch` / `git checkout` / `git pull` は実行しないこと。** 同期は run が Epic 専用
  worktree で既に済ませており、あなたの isolation worktree は WAVE_BASE から分岐している
- サンドボックスへのコマンド投入は `${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh` 経由で行い、
  ビルド・テストは1回の呼び出しにまとめること（分けると待ち時間が倍増する）
- `sandbox-exec.sh` を呼ぶ際は必ず `--epic "$EPIC_NUM"` を渡すこと（例: `--epic "$EPIC_NUM" 'make test'`）
- プロジェクト固有の準備（wasm配置等）は Epic 開始時に run が1回実行済み。**タスクごとに
  再実行しないこと**。効いていないと判断した場合も自前で再実行せず、その事実を報告すること
- 回帰確認はプロジェクトの全テストで行うこと。`-run` で絞った結果を「回帰なし」と報告しないこと
- SKIP されたテストがあれば件数と内容を報告に含めること
- issueの要件を確認
- Task issueの記載だけで着手できない場合に限り、親Epic issueの本文を参照すること
- テストファーストで実装
- 変更をコミット
- 作業開始直後に `date +%s` で開始時刻を記録し、報告直前にも `date +%s` で終了時刻を記録すること
- 報告には「実際に叩いたテストコマンドの全文」「ベース検証の実出力」「レーン記号（A）」
  「最終的な作業ブランチ名」「開始時刻・終了時刻（`date +%s` の値、または `HH:MM` 表記でよい）」
  を含めること（作業ブランチ名は Step 5 の merge-lane.sh で使う。開始・終了時刻は Step 4 の
  進捗表示で使う）

@generator
Task #[番号B] を実装してください（レーン B）。
（内容はレーンAと同様。WAVE_BASE は同じハッシュを渡す）
```

Claude Code のサブエージェントは**バッチ全員が終わるまで結果が返らない**ため、
「1本終わったら次を投入する」動的なレーン補充は原理的に実装できない。サブバッチの所要時間は
最長レーンで決まる（バリア同期）。これは harness の制約として受け入れる。

サブバッチが複数ある場合は、直前のサブバッチの完了を待ってから次のサブバッチを起動する
（全サブバッチが順に完了するまでは Step 4 へ進まない）。

### Step 4: レーン内ゲートの結果を確認する

各generatorは自分のisolation worktree内で完了報告（テスト実行結果・SKIP件数・可読性チェック）
を返す。レーン内ゲートに失敗したレーンは**wave へ取り込まず**、試行回数を保持したまま
次ウェーブへ持ち越す（ウェーブ内では再試行しない。理由は Step 8 参照）。

品質・設計・セキュリティの観点はここでは見ない。**それらはEpic完了後の一括レビューで見る。**

全サブバッチの完了直後に、実装フェーズの計測を締める:

```bash
IMPL_END_SEC=$(date +%s)
IMPL_SEC=$((IMPL_END_SEC - IMPL_START_SEC))
```

`IMPL_SEC` は「並列化の寄与」を表す実測値（サブバッチの所要時間は最長レーンで決まるバリア同期の
実測を含む）。各generatorが報告した開始・終了時刻をもとに、レーンごとの結果行を表示する:

```
レーン結果: A=#5(12:03-12:11 8m00s) B=#10(12:03-12:09 6m00s) C=#11(12:03-12:07 4m12s)
```

（レーン内ゲートに失敗したレーンは末尾に `失敗` を添える。例: `C=#11(12:03-12:05 失敗)`）

#### トークン消費の記録（効果測定。Task #76）

各generatorのTask呼び出しが完了すると、ハーネスがツール結果の直後に
`⎿ Done (N tool uses · Xk tokens · Ym Zs)` 形式でトークン消費を報告する（Claude Code既定の挙動。
Epic #42のベースライン実測値もこの表示から得ている）。この値が読み取れたレーンについてのみ、
1レーン1レコードで記録する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role generator --mode "タスク実装" --tokens [読み取ったトークン数] --note "#[タスク番号]"
```

トークン数が読み取れない場合（表示形式が変わった・要約が省略された等）は、そのレーンの記録を
スキップしてよい。**`record-agent-tokens.sh` の成否・トークン数の有無に関わらず、
自律ループは止めない。** 失敗しても標準エラーを読み捨てて次へ進む。

### Step 5: wave ブランチへレーンを取り込む

全サブバッチ完了後、Epic worktreeでwaveブランチを作成し、（レーン内ゲートに通った）レーンを
issue番号順に取り込む。**`--create` は「1本目のレーン」ではなく、最初に実際に取り込むレーンに
付ける。** 取り込み対象はレーン内ゲートに通ったレーンに限られるため、issue番号順で先頭の
レーン（例: レーンA）がレーン内ゲートに失敗していれば、`--create` はレーンBなど次に取り込む
レーンに付く。

```bash
cd "$EPIC_WT"
MERGE_START_SEC=$(date +%s)   # 「統合」フェーズ（merge-lane.sh群）の計測開始

# 最初に実際に取り込むレーン（レーンAとは限らない）: --create でwaveブランチをWAVE_BASEから作成する
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-lane.sh" \
  --wave-branch "wave/${EPIC_NUM}/${WAVE_NO}" --expected-base "$WAVE_BASE" \
  --lane-branch "[レーンAの作業ブランチ]" --task <番号A> --create

# 2本目以降: waveブランチは既に存在するので --create は不要
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-lane.sh" \
  --wave-branch "wave/${EPIC_NUM}/${WAVE_NO}" --expected-base "$WAVE_BASE" \
  --lane-branch "[レーンBの作業ブランチ]" --task <番号B>

MERGE_END_SEC=$(date +%s)
MERGE_SEC=$((MERGE_END_SEC - MERGE_START_SEC))
```

終了コードで扱いを分岐する:

| 終了コード | 意味 | 扱い |
|---|---|---|
| 0 | 取り込み成功 | 次のレーンへ |
| 10 | merge-base ≠ WAVE_BASE（ベース逸脱） | 取り込まず差し戻す。実出力をTask issueにコメント。**cherry-pickによる載せ替えはしない** |
| 11 | マージ競合（`git merge --abort` 済み） | 取り込まず、stdoutの競合ファイル一覧と相手レーンをTask issueにコメント。次ウェーブで再実行 |
| 2 | 引数エラー | runの呼び出しミス。停止して報告する |
| 1 | その他の失敗 | 停止して報告する |

取り込めなかったレーンはこの時点でwaveに含まれない。**先に取り込めたレーンの成果は活かし、
ウェーブ全体は捨てない。**

**取り込めたレーンが0本の場合**（全レーンがレーン内ゲートに失敗した、またはレーン内ゲートに
通った全レーンが `merge-lane.sh` から exit 10/11 で拒否された）、`merge-lane.sh --create` が
一度も成功しておらず `wave/${EPIC_NUM}/${WAVE_NO}` は存在しない。この場合は **Step 6・Step 7 を
実行せず**、このウェーブの各タスクの試行回数を加算したうえで Step 1 に戻る（次ウェーブへ）。

### Step 6: wave ブランチで統合ゲートを1回実行する

全レーンの取り込み（成功分のみ）が終わったら、waveブランチ上で**1回だけ**機械的ゲートを実行する。
**このStepはStep 5で取り込めたレーンが1本以上ある場合のみ実行する**（0本の場合はStep 5末尾の
分岐を参照）。念のため冒頭で wave ブランチの存在を確認してから進む:

```bash
cd "$EPIC_WT"
git rev-parse --verify -q "refs/heads/wave/${EPIC_NUM}/${WAVE_NO}" >/dev/null || {
  echo "ERROR: wave/${EPIC_NUM}/${WAVE_NO} が存在しません（取り込めたレーンが0本）。Step 7を実行せずStep 1へ戻ってください"
  exit 1
}
git checkout "wave/${EPIC_NUM}/${WAVE_NO}"
GATE_START_SEC=$(date +%s)   # 「統合ゲート」フェーズの計測開始

# 1) テスト（Docker sandbox内）— 1回にまとめる。落ちたら不合格
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" '[全テストを走らせるコマンド]'

# 2) 可読性ガード — waveブランチの差分に対して実行（PostToolUseフックと同じ判定）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh" --git

GATE_END_SEC=$(date +%s)
GATE_SEC=$((GATE_END_SEC - GATE_START_SEC))
```

内容の要件は従来と同じ（プロジェクトの全テストを1コマンドで／対象の選択をgeneratorに委ねない／
SKIPを通過扱いにしない。詳細は下記）。

**Epic worktreeに対する単独のゲートは廃止する。** レーンの変更がEpicに入るのは統合ゲート
通過後のマージであり、Epic worktreeを先に検証しても検証対象として意味を持たない。加えて、
generatorが並列に実施するレーン内ゲートと合わせて毎タスク2回フルテストが走る重複も解消される。
検証点は次の2つに整理される。

| 検証点 | 対象ツリー | 頻度 |
|---|---|---|
| レーン内ゲート | generatorのisolation worktree | タスクごと（並列に走るため時間が重ならない） |
| 統合ゲート | waveブランチ（全レーン取り込み後） | ウェーブごとに1回 |

#### 何を実行すれば「回帰なし」と言えるか

ゲートで走らせるのは**プロジェクトの全テスト**とする。`make test` 等のプロジェクト標準
ターゲットがあればそれを優先し、**対象の選択をgeneratorに委ねない。**

- ビルドタグ付きのテスト（`//go:build integration` 等）があるプロジェクトでは、それも含める
- ビルド・vet・テストを**別々の呼び出しに分けない**。サンドボックスはソースツリーを
  バインドマウントしており、フルツリーを走査するコマンドは1回ごとにその走査コストを払う
- テストがビルドを兼ねるなら（`go test ./...` 等）、それ1本で足りる

#### SKIP を通過扱いにしない

依存物が未配置だとテストが無言で `SKIP` され、`ok` と表示されて成功に見える。
**`ok` の有無だけで判定してはならない。** 出力中のSKIP件数を確認し、
検証したかったテストが実際に走ったことを確かめる。想定外のSKIPは不合格として扱う。

- **通過** → Step 7 へ
- **失敗** → Step 8「統合ゲート失敗」のリカバリへ（Epicブランチは無傷のまま）

### Step 7: Epicブランチへ取り込んで次のウェーブへ

#### なぜ `--ff-only` の役割を分離するか

従来は `git merge --ff-only <レーン>` の1本で「ベース逸脱の検出」と「履歴の直線性の強制」を
兼ねていたが、後者が並列実行を構造的に不可能にしていた（同一ベースから分岐した並列ブランチは
原理的にfast-forwardできない）。**この2つの役割は分離できる**: ベース逸脱の検出はStep 5の
`merge-lane.sh`によるmerge-base完全一致検証が引き継ぎ、直線性の強制はやめる。

epicへの取り込みは、waveがWAVE_BASEの子孫であるため統合ゲート通過後は必ずfast-forwardになる。

```bash
cd "$EPIC_WT"
git checkout "${EPIC_BRANCH}"
git merge --ff-only "wave/${EPIC_NUM}/${WAVE_NO}"
git push origin "${EPIC_BRANCH}"
```

**Epicへのforce pushは行わない。waveブランチはoriginへpushしない**（ローカルの一時ブランチ）。

1. 取り込めたレーンに対応するTask issueをクローズする: `gh issue close [番号]`
2. Epic issueの進捗を更新する
3. このウェーブの計測を確定し、次ウェーブのバナー表示・PR本文の集計に使う値を更新する:

```bash
WAVE_TOTAL_SEC=$((IMPL_SEC + MERGE_SEC + GATE_SEC))
echo "前ウェーブ: 実装 $(fmt_duration "$IMPL_SEC") + 統合 $(fmt_duration "$MERGE_SEC") + 統合ゲート $(fmt_duration "$GATE_SEC") = $(fmt_duration "$WAVE_TOTAL_SEC")"

PREV_WAVE_IMPL_SEC="$IMPL_SEC"
PREV_WAVE_MERGE_SEC="$MERGE_SEC"
PREV_WAVE_GATE_SEC="$GATE_SEC"

TOTAL_IMPL_SEC=$((TOTAL_IMPL_SEC + IMPL_SEC))
TOTAL_MERGE_SEC=$((TOTAL_MERGE_SEC + MERGE_SEC))
TOTAL_GATE_SEC=$((TOTAL_GATE_SEC + GATE_SEC))
DONE_TASK_COUNT=$((DONE_TASK_COUNT + N))   # N = 直前の「取り込めたレーンに対応するTask issueをクローズする」で閉じた件数
```

4. → Step 1 に戻る（次のウェーブへ）

全ウェーブが完了したら **「Epic一括レビュー」** へ進む。

**統合ゲートに失敗した場合（Step 8 のリカバリを経由した場合）は、この計測更新を行わない。**
`PREV_WAVE_*` と累計は「統合ゲートを通過して実際に取り込めたウェーブ」だけを反映する
（失敗した試行の時間まで合算すると、並列化とオーバーヘッド削減の寄与という本来の目的が
読み取れない数字になるため）。

### Step 8: 失敗時のリカバリ

**共通原則: 失敗したレーンだけを落とし、先に取り込めたレーンの成果は活かす。ウェーブ全体は捨てない。**

| 失敗パターン | 扱い |
|---|---|
| レーン内ゲート失敗 | waveに取り込まず、試行回数を保持したまま次ウェーブへ持ち越す。**ウェーブ内では再試行しない** |
| `merge-lane.sh` exit 10（ベース逸脱） | 取り込まず差し戻す。実出力をissueにコメント。**cherry-pick載せ替えはしない** |
| `merge-lane.sh` exit 11（競合） | 取り込まず、競合ファイル一覧と相手レーンをissueにコメント。次ウェーブで再実行 |
| 競合で2回失敗 | 次ウェーブで**単独レーン**（`lanes=1`相当のサブバッチ）として実行する |
| 同一タスクで3回失敗 | スキップする。issueにコメントし、`SKIPPED_CSV` に加える（以降の`plan-waves.sh`呼び出しの`--skipped`に反映される） |
| 統合ゲート失敗 | Epicは無傷のまま。WAVE_BASEからwaveブランチを作り直し、レーンを1本ずつ「マージ→ゲート」で積んで原因レーンを一意に特定する。特定したレーンだけ差し戻し、残りは活かす |

**「ウェーブ内で再試行しない」理由**: バリア同期のため、ウェーブ内の再試行は完了済みの他レーンを
待たせ続けるだけになる。次ウェーブに回せばベースが進むだけで、「先行タスクの変更が無かった
せいで落ちた」「同じ行を触ったせいで競合した」類の失敗は自然に解消する。

#### 統合ゲート失敗時の原因特定手順

この時点で `wave/${EPIC_NUM}/${WAVE_NO}` は checkout 中のブランチであり、`git branch -f` は
チェックアウト中のブランチの強制更新を拒否する。**`git checkout -B` で作り直すこと**
（`git branch -f` の後に `git checkout` を続ける2行構成にはしない）。

```bash
cd "$EPIC_WT"
git checkout -B "wave/${EPIC_NUM}/${WAVE_NO}" "$WAVE_BASE"

# レーンを1本ずつ merge-lane.sh で取り込み、そのつどゲートを実行する
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-lane.sh" \
  --wave-branch "wave/${EPIC_NUM}/${WAVE_NO}" --expected-base "$WAVE_BASE" \
  --lane-branch "[レーン1の作業ブランチ]" --task <番号1>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" '[全テストを走らせるコマンド]'
# 通れば次のレーンを取り込んでまたゲートを実行する。落ちた時点のレーンが原因と一意に特定できる
```

#### スキップの伝播

スキップされたタスクに依存する後続タスクは、`plan-waves.sh` の出力（`skip <番号> reason
depends-on-skipped <依存先番号>`）に従って実行せずスキップし、Task issueにその旨をコメントする
（推移的に伝播する）。スキップ一覧は**Epic一括レビュー前にEpic issueへコメントし、PR本文にも
明記して人間に判断を渡す**（詳細は「Epic一括レビュー」節）。

## サンドボックスの後片付け（正常終了・異常終了を問わず必ず実行）

自律ループが終わる経路は複数ある（全タスク完了 → Epic一括レビュー → PR作成、機械的ゲートの
失敗が続いてタスクをスキップし続けた末の停止、予期しないエラーによる中断）。
**どの経路で run が終わる場合も、後続処理（PR作成や中断報告）に進む前に、必ず次のクリーンアップを
実行すること。** 完了通知の後ろに置いて成功時にしか実行されない、ということがあってはならない。

```bash
# 常駐コンテナの削除（epic 単位。キャッシュ volume は次の Epic のために残す）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --down

# watchdog の停止（正常終了・異常終了を問わず必ず実行する。--down と同じ強さで必須）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --stop
```

watchdog は run マーカーの消失でも自己終了するが、消失までに1 tick分のタイムラグがある
（既定60秒）ため、後続処理へ進む前に `--stop` で確実に止める。**これを怠ると、run が
終了した後も無活動を検知し続けて的外れな stall 通知が届く。**

**キャッシュ volume は削除しない。** 次の Epic でそのまま効くのが利点であり、消すと
毎回キャッシュ構築コストを払い直すことになる。明示的に消したい場合のみ `--reset-cache` を使う。
`--reset-cache` の**作用範囲は epic ではなくリポジトリ全体**であることに注意し、
同一リポジトリの他 epic のコンテナが running なら中断される（続けるには `--force`。
他 epic の実行中コンテナのキャッシュも壊れるため、本当に必要な場合のみ使うこと）。

### 人間向けの手動クリーンアップ

自律実行の外で、残存コンテナの棚卸しをしたい場合は次を使う:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --ls          # 管理コンテナを一覧表示（他リポジトリ分も含む）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --down --all   # 現在のリポジトリに属する管理コンテナを全て削除
```

## ハングしたときに人間がすること

watchdog は無活動を検知しても**自動では打ち切らない**（Epic #42「決定事項」参照）。
Slack に `:rotating_light: 応答なし` が届いたら、人間が次の手順で判断・対処する。

1. **通知本文の `state` を見る**（`scripts/watchdog.sh` の通知文言がそのまま切り分けの根拠になる）
   - `ツール実行中に停止` → サンドボックス（Docker）側を疑う。
     `bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --ls` でコンテナの状態を確認する
   - `モデルの応答待ちで停止` → API 側のスロットリングの疑い。待つか、打ち切るかを判断する
2. **打ち切る場合**: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --abort "理由"` を実行する。
   **これはエージェントが次にツールを呼んだ瞬間に効く**（`heartbeat.sh pre` がフラグを見て
   拒否する経路のため）。**応答待ちの最中には効かない。** 即座に止めたい場合は Claude Code 側の
   セッションを中断する。**セッションを中断した場合は Stop フックが走らず run マーカー
   （`.dev-workflow-run`）が削除されないまま残るため、続けて
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --stop` を実行して watchdog を止めること。**
   放置すると watchdog は打ち切りに気付かず無活動検知（15分）・エスカレーション（30分ごと最大3回）を
   続け、既に打ち切ったはずの run について「応答なし」の通知が届き続ける
3. **再開する場合**: `/dev-workflow:run #<epic番号>` を再実行する。次の3点により、中断→再開でも
   安全に途中から続けられる（Task #54）。
   - **残タスクは open な Task issue から再計算される。** クローズ済みのタスクは
     `plan-waves.sh` の対象から自然に外れるため、完了分をやり直すことはない
   - **wave ブランチは採番し直される。** `WAVE_NO` はセッション変数のため再実行のたびに
     失われるが、上記「自律ループ」節のとおり既存の `wave/${EPIC_NUM}/*` ブランチの番号の
     最大値から数え直すため、前回の残骸ブランチを再利用しない。万一 `merge-lane.sh --create`
     が残骸 wave ブランチ（tip が `--expected-base` と不一致）を掴んだ場合は exit 1 で拒否され、
     epic ブランチ・wave ブランチのどちらも変更されない
   - **取り込み済みのコミットは失われない。** 統合ゲートを通過して Epic ブランチへ
     `git merge --ff-only` 済みのコミットは Epic ブランチ上に残り続ける。再実行後にやり直すのは
     「取り込みが完了していないウェーブ」だけである

**Claude Code 側では「自動で打ち切って再投入する」ことは原理的にできない。** サブエージェントは
独立した OS プロセスではなく同一プロセス内の API 呼び出しであり、外部から中断する手段が無いためである
（Epic #42「2. サブエージェントを外部から中断する手段は無い」参照）。watchdog にできるのは検知して
通知することまでであり、打ち切りの主体は常に人間である。

## 進捗表示

本Epicは並列化とオーバーヘッド削減の2つを同時に行うため、**両者の寄与を別々に読めるように**
計測を分けて表示する（「実装」= 並列化の寄与、「統合」「統合ゲート」= 並列化が追加で持ち込むコスト・
直列に残るコスト）。時刻の取得に追加の依存物（`jq` 等）は使わず、`date +%s` の差分だけで計測する
（`fmt_duration` ヘルパーは「自律ループ」節冒頭で定義済み）。

### Step 1 の直後（ウェーブ開始時）に表示するバナー

```
═══════════════════════════════════════
  Run: Epic $ARGUMENTS [YOLO / lanes=[LANES]]
  ウェーブ: [ウェーブ番号] / [総ウェーブ数]   タスク: [完了数] / [全タスク数] 完了（スキップ [スキップ数]）
  レーン: A=#[番号A] B=#[番号B] C=#[番号C]
  前ウェーブ: [PREV_WAVE_*が空なら「(初回のため計測なし)」／それ以外は下記の内訳]
═══════════════════════════════════════
```

「前ウェーブ」の行は次の形式（Step 7 で確定させた `PREV_WAVE_*` を使う）:

```bash
if [ -n "$PREV_WAVE_IMPL_SEC" ]; then
  PREV_TOTAL_SEC=$((PREV_WAVE_IMPL_SEC + PREV_WAVE_MERGE_SEC + PREV_WAVE_GATE_SEC))
  echo "前ウェーブ: 実装 $(fmt_duration "$PREV_WAVE_IMPL_SEC") + 統合 $(fmt_duration "$PREV_WAVE_MERGE_SEC") + 統合ゲート $(fmt_duration "$PREV_WAVE_GATE_SEC") = $(fmt_duration "$PREV_TOTAL_SEC")"
else
  echo "前ウェーブ: (初回のため計測なし)"
fi
```

「[総ウェーブ数]」は `plan-waves.sh` の出力からは得られない（残タスクからの再計算のため、既に
完了したウェーブ数を含む総数は自明ではない）。**Epic issueの「タスク一覧」節に列挙されたウェーブ
数を初回に数えて控えておき、以降はその値を使い回す**（スキップの伝播で後続ウェーブが減っても、
「予定していたウェーブ数」としてそのまま使ってよい。厳密な再計算は要求しない）。

### Step 4 の直後（サブバッチ完了時）に表示するレーン結果

```
レーン結果: A=#5(12:03-12:11 8m00s) B=#10(12:03-12:09 6m00s) C=#11(12:03-12:07 4m12s)
```

各generatorが報告した開始・終了時刻（Step 3 のプロンプトで要求済み）をもとに組み立てる。
レーン内ゲートに失敗したレーンは末尾に `失敗` を添える。

### Step 7 の直後（ウェーブ完了時）に表示するウェーブ合計

```bash
echo "前ウェーブ: 実装 $(fmt_duration "$IMPL_SEC") + 統合 $(fmt_duration "$MERGE_SEC") + 統合ゲート $(fmt_duration "$GATE_SEC") = $(fmt_duration "$WAVE_TOTAL_SEC")"
```

これは次ウェーブのバナーで使う文言と同じ（`PREV_WAVE_*` に格納した値をそのまま使う）。

### PR本文への集計（Epic完了時）

全ウェーブ完了後、PR本文（後述「PR作成」節）に次の集計を載せる。`TOTAL_IMPL_SEC` /
`TOTAL_MERGE_SEC` / `TOTAL_GATE_SEC` は Step 7 で毎ウェーブ加算した累計、`WAVE_NO` は
実行した総ウェーブ数、`DONE_TASK_COUNT` は取り込めたタスク数である。

```
## 実行時間
- ウェーブ数: [WAVE_NO] / タスク数: [DONE_TASK_COUNT] / 並列度: [LANES]
- 実装（レーン）合計: [fmt_duration TOTAL_IMPL_SEC] / 統合合計: [fmt_duration TOTAL_MERGE_SEC] / 統合ゲート合計: [fmt_duration TOTAL_GATE_SEC]
- 総所要時間: [fmt_duration (TOTAL_IMPL_SEC + TOTAL_MERGE_SEC + TOTAL_GATE_SEC)]
```

これにより、次に何を削るべきか（LLM時間か、統合ゲートの待ち時間か、統合処理か）が実測で分かる。
並列化タスク（#15・#16・#18・#20・#21・#22）とオーバーヘッド削減タスク（#17・#19・#23）の
どちらの寄与が大きかったかは、複数Epicでこの集計を比較することで読み取れる。

### PR本文への「トークン消費」集計（効果測定。Task #76）

「実行時間」の隣に、`record-agent-tokens.sh --summary` の出力をそのまま載せる:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" --summary --epic "$EPIC_NUM"
```

```
## トークン消費
[record-agent-tokens.sh --summary --epic "$EPIC_NUM" の出力をそのまま貼る]

比較対象（Epic #42実測。docs/optional-mcp-tools.md「効果測定のベースライン」参照）:
generator タスク実装 81k〜150k / evaluator delta-review 83k / evaluator epic-review 139k。
```

1件も記録できていない場合（トークン数が一度も読み取れなかった等）は、このセクション自体を
省略してよい。**記録の有無はPR作成のブロッカーにしない。**

## Epic一括レビュー（全タスク完了後・PR作成前）

全Task issueがクローズされた時点で、**ここで初めてevaluatorを起動する。**

### R0: スキップ一覧をEpic issueにコメントする

3回失敗してスキップしたタスク、または依存先のスキップが伝播して未実行のままとなったタスクが
あれば、一括レビューの前に一覧をEpic issueへコメントする。無ければこの節は省略する。

```bash
gh issue comment "$ARGUMENTS" --body "$(cat <<'BODY'
## スキップされたタスク

- #[番号]: [スキップ理由（3回失敗 / 依存先 #[番号] のスキップの伝播）]
BODY
)"
```

### R1: 一括レビューの実行

起動前に「レビュー粒度の調整」の3分岐に従う（変更50ファイル以下なら以下の基本形のまま起動する）。

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

evaluatorのTask呼び出しが完了したら、Step 4と同じ作法でトークン消費を記録する
（読み取れた場合のみ。読み取れなくても止めない）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role evaluator --mode epic-review --tokens [読み取ったトークン数]
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

1. 作成した review issue を**1件ずつ** generator に渡して修正させる
   （通常のタスクと同じ自律ループの手順を通す。Step 1〜7）
2. 全件対応したら **delta-review** で再レビューする:

```
@evaluator
Epic #$ARGUMENTS の指摘対応を確認してください。
- モード: delta-review
- 差分範囲: [R1のreviewed_commit]..[epic/epicXX/機能名]
- 指定範囲外の蒸し返しはしないこと
- 最後に必ずJSONブロックを出力すること
```

R1と同じ作法でこのdelta-review呼び出しのトークン消費も記録する（`--mode delta-review`）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role evaluator --mode delta-review --tokens [読み取ったトークン数]
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

R1の起動前に変更ファイル数を数え、既存のしきい値（目安: 変更50ファイル超）で3つに分岐する。
**新しいしきい値の軸は増やさず、この50ファイル超のしきい値に相乗りする。**

dev-workflowは**駆動先プロジェクト**でこのSKILL.mdを実行するプラグインであり、駆動先の
デフォルトブランチが `main` とは限らない。**ベースブランチを `master`/`main` に決め打ちしない**
（dev-workflow自身のリポジトリのデフォルトブランチが `master` であっても、それを駆動先の値として
埋め込んではならない）。`gh repo view` で駆動先の実際のデフォルトブランチを解決する:

```bash
BASE_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
BASE_BRANCH="${BASE_BRANCH:-main}"

if CHANGED_FILES_LIST="$(git diff --name-only "${BASE_BRANCH}...${EPIC_BRANCH}")"; then
  CHANGED_FILES="$(printf '%s\n' "$CHANGED_FILES_LIST" | grep -c '.')"
else
  echo "WARN: git diff ${BASE_BRANCH}...${EPIC_BRANCH} に失敗し、変更ファイル数を数えられなかった。Phase単位分割にフォールバックする" >&2
  CHANGED_FILES=""
fi
```

`git diff` を `wc -l` に直接パイプしない。パイプすると `git diff` が失敗しても `wc -l` は0を
返して**失敗を握り潰し**、「CHANGED_FILES <= 50 → 従来どおり」に誤判定してしまう
（ベースブランチが存在しない等で起きうる）。上記のとおり `git diff` 自体の終了コードを見て、
失敗時は `CHANGED_FILES` を空にし、**サイズ不明のまま「従来どおり（分割なし）」に倒さず**
Phase単位分割へフォールバックする。

| 条件 | 挙動 |
|---|---|
| `CHANGED_FILES` を数えられなかった（`git diff` 失敗） | **Phase単位分割にフォールバックする**（下記の既存の回避策。サイズ不明の場合に安全側へ倒す） |
| `CHANGED_FILES` <= 50 | **従来どおり。** code-review-graphには一切触れない（グラフ構築もしない） |
| `CHANGED_FILES` > 50 かつ code-review-graphが利用可能（`command -v code-review-graph`） | evaluatorのプロンプトに「blast radiusの算出を使って読む優先順位を付けてよい」旨を含めて起動する |
| `CHANGED_FILES` > 50 かつ code-review-graphが未導入 | **従来どおり**、R1をPhase単位に分割して起動する（下記の既存の回避策） |

code-review-graphが利用可能な場合でも、Phase単位の分割を**禁止はしない**（両立してよい）。
どちらの場合も**タスク単位には戻さない**。

blast radiusを使う場合のプロンプト例（R1の基本形に1行加えるだけでよい）:

```
@evaluator
Epic #$ARGUMENTS の全変更をレビューしてください。
- モード: epic-review
- 差分範囲: main...[epic/epicXX/機能名]
- 変更ファイル数が50超のため、code-review-graphのblast radiusの算出を使って読む優先順位を付けてよい
- 最後に必ずJSONブロック（verdict / reviewed_commit / findings）を出力すること
```

code-review-graphが未導入の場合（従来どおりPhase単位に分割する既存の回避策）:

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

### スキップされたタスク（未実装。人間の判断が必要）
- [ ] #XX [タイトル] — [スキップ理由（3回失敗 / 依存先スキップの伝播）]

## レビュー結果
- 一括レビュー: [APPROVE / 2巡で打ち切り]
- 対応済みの指摘: #XX, #XX

### 未対応の指摘（人間の判断が必要）
- [ ] #XX [タイトル] — [なぜ未対応か]

### レビューで挙がった軽微な指摘（issue化せず記録のみ）
- [重要度lowの指摘]

## 実行時間
- ウェーブ数: [WAVE_NO] / タスク数: [DONE_TASK_COUNT] / 並列度: [LANES]
- 実装（レーン）合計: [fmt_duration TOTAL_IMPL_SEC] / 統合合計: [fmt_duration TOTAL_MERGE_SEC] / 統合ゲート合計: [fmt_duration TOTAL_GATE_SEC]
- 総所要時間: [fmt_duration (TOTAL_IMPL_SEC + TOTAL_MERGE_SEC + TOTAL_GATE_SEC)]

## トークン消費
[record-agent-tokens.sh --summary --epic "$EPIC_NUM" の出力（1件も記録できていない場合は本セクションを省略）]

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

サンドボックスの後片付け（常駐コンテナの `--down`）は「自律ループ（YOLOモード、ウェーブ単位）」の
直前の節で**既に実行済み**である（正常終了・異常終了を問わず必ず実行する節）。ここで重複して
実行する必要はない。

## 自律動作ポリシー（YOLOモード）

- **ユーザーへの確認・質問は一切行わない**
- 同一タスクで（レーン内ゲート・統合ゲートを合わせて）3回失敗した場合 → タスクをスキップし、
  issueにコメントを残して次のウェーブへ進む
- 障害が続く場合は `--lanes 1` を指定すれば現行と等価な逐次実行にロールバックできる
  （並列用と逐次用でコードパスを分けていないため、値を変えるだけで安全に落とせる）
- **タスクループ中にevaluatorを起動しない**（レビューはEpic完了後の一括レビューのみ）
- Epic一括レビューは最大2巡で打ち切り、未対応の指摘はissueを残したままPR本文に明記する
- 予期しないエラーが発生した場合 → issueにエラー詳細をコメントし、次のウェーブへ進む
- スキップしたタスクと依存先スキップの伝播は、Epic issueの進捗表示・コメント・PR本文で明示する
- **Epicブランチには統合ゲートを通過したコミットだけを載せる。force pushは行わない**
- **mainブランチには絶対にマージしない**
- **テスト時に実ユーザーにメールを送信しないこと。** テスト用受信アドレス（mailhog, mailtrap等）が未設定の場合はタスクを中断し、issueにコメントを残して開発者に設定を促す
- **本番環境のデータは絶対に編集・削除・変更しないこと。** テストはDocker sandbox内のテスト用データのみ使用する
