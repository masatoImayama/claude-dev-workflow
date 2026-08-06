---
name: dev-workflow-run
description: 承認済みのEpic issueを、generator/evaluatorサブエージェントで自律的に実装しPRを作成する。Epic issue番号を受け取って開始する。
---

# Dev Workflow Run（Codex）

承認済みの Epic issue 配下の全 Task issue を自律的に完了させ、main向けPRを作成する。
**ユーザー確認は行わない。**

## 入力

Epic issue 番号（例: `#42`）。指定がなければ `gh issue list --label epic --state open` で候補を示して確認する。

## 前提

このスキルは `.codex/agents/` に planner / generator / evaluator が設置されていることを前提とする。
未設置なら `install-codex-agents` スキルを先に実行する。

```bash
ls .codex/agents/   # generator.toml / evaluator.toml / planner.toml があるはず
```

役割定義・ワークフロー規約・可読性原則・安全ルールは**すべてサブエージェント側に埋め込まれている**。
このスキルはループの制御だけを担う。

## Epic ブランチと作業 worktree の準備

Epic issue 本文の「ブランチ」セクションからブランチ名を取得する。

```bash
EPIC_BRANCH=$(gh issue view <epic番号> --json body -q '.body' | grep -oE 'epic/epic[0-9]+/[^`]+' | head -1)
EPIC_NUM=$(printf '%s' "$EPIC_BRANCH" | grep -oE 'epic[0-9]+' | head -1)   # sandbox-exec.sh の --epic 用の識別子（epicXX形式）
EPIC_ISSUE_NUM="${EPIC_NUM#epic}"   # plan-waves.sh の --epic 用（数値のEpic issue番号。ブランチ名epic/epicXXのXX部分=Epic issue番号）

git fetch origin
git rev-parse --verify "origin/${EPIC_BRANCH}" >/dev/null 2>&1 || { echo "ERROR: ブランチ ${EPIC_BRANCH} が見つかりません"; exit 1; }
git show-ref --verify --quiet "refs/heads/${EPIC_BRANCH}" || git branch "${EPIC_BRANCH}" "origin/${EPIC_BRANCH}"

EPIC_WT=".codex/worktrees/${EPIC_NUM}"
if [ -d "$EPIC_WT" ]; then
  git -C "$EPIC_WT" checkout "${EPIC_BRANCH}" 2>/dev/null || true
else
  git worktree add "$EPIC_WT" "${EPIC_BRANCH}"
fi
cd "$EPIC_WT"
```

以降のすべての作業をこの worktree 内で行う。**メインリポのチェックアウトを切り替えてはならない。**

**重要:** Codex のサブエージェントは**専用 worktree を持たない**（Claude Code の `isolation: worktree` に
相当する機構がない）。したがって generator を**並行実行してはならない。** 1タスクずつ逐次で回す。

このスキルは**「仕様が違う」のではなく「設定値（`lanes`）が `1` に固定されているだけ」**という
位置づけである。ウェーブの概念・`- 前提: #N` による依存グラフ・merge-base 完全一致検証・
`--ff-only` によるベース検証の廃止・wave ブランチ経由の統合ゲート・cherry-pick 載せ替えの禁止・
スキップの推移的伝播は、すべて Claude 版（`skills/run/SKILL.md`）と同じ仕様を適用する。
`lanes=1` のとき「1レーンのウェーブ」として**同じコードパス**を通るため、両 run スキルの記述は
一致する。**非対応なのはレーンの並列起動（`--lanes` > 1）だけ**であり、それは前段落の worktree
の制約に起因する。

## ブランチ戦略

```
main（保護: 人間のみマージ可）
 └─ epic/epicXX/[機能名]  ← 統合ゲートを通ったコミットだけが載る
     └─ wave/epicXX/<通し番号>  ← レーンを取り込み統合ゲートに掛ける一時ブランチ（origin へ push しない）
         └─ task/epicXX/<Task issue番号>  ← generator が実装するレーンの作業ブランチ
```

`lanes=1` 固定のため、1ウェーブ = 1レーン = 1タスクとして扱う（Claude の `--lanes 1` と同じ
コードパスを通り、履歴は自然に fast-forward の直線になる）。

- 各タスクの作業ブランチ（レーン）は、そのタスク開始時点の Epic ブランチ tip（`WAVE_BASE`）から分岐する
- レーンは wave ブランチを経由し、**統合ゲート通過後にのみ** `--ff-only` で Epic ブランチへ合流する
- **Epic ブランチへの force push は行わない。wave ブランチは origin へ push しない**（ローカルの一時ブランチ）

## サンドボックスの準備

**`docker build` / `docker compose up` を直接叩いてはならない。** イメージのビルド・
コンテナの起動・compose サービスの起動はすべて `sandbox-exec.sh` に集約されている。
やることは `--print-plan` で解決結果を確認し、`--warm` を1回流すことだけである。

```bash
# docker に一切触れず、解決結果（mode / container / image / compose_* 等）を表示する
PLAN="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --print-plan)"
echo "$PLAN"

if printf '%s\n' "$PLAN" | grep -q '^mode=none$'; then
  echo "ERROR: Dockerfile.dev または docker-compose.dev.yml が見つかりません"
  echo "プロジェクトルートに開発用Dockerfileまたはcomposeファイルを配置してください"
  exit 1
fi

# キャッシュを温めておく（イメージが無ければここで自動ビルドされる。最初のタスクにキャッシュ構築コストを負担させない）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --warm '<build-command>'

# Epic本文に「## 準備コマンド」節があれば、プロジェクト固有の準備（wasm配置等）もここで1回だけ実行する
PREP_CMD="$(gh issue view <epic番号> --json body -q '.body' \
  | awk '/^## 準備コマンド/{f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' | sed '1d;$d')"
if [ -n "$PREP_CMD" ]; then
  echo "Epic本文の準備コマンドを実行します:"
  echo "$PREP_CMD"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --warm "$PREP_CMD"
fi

# Epic本文に「## SKIPパターン」節があれば取り出す（built-inランナー以外の形式向け。任意）
SKIP_PATTERN="$(gh issue view <epic番号> --json body -q '.body' \
  | awk '/^## SKIPパターン/{f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' | sed '1d;$d')"
```

**節が無ければ何もしない。** 既存の Epic（`## 準備コマンド` 節が無いもの）は上記の
`<build-command>` による `--warm` だけが従来どおり走り、この追加ステップの影響を受けない。
`--warm` は失敗してもループを止めない（`sandbox-exec.sh` の既存挙動）ので、準備コマンドが
失敗した場合も表示だけしてそのまま先へ進む。

**Codex の generator にはこの準備コマンドを渡さない**（渡すと二重実行になる）。Claude 版では
run の1回は Epic 専用 worktree にしか効かず、generator は別ツリー（isolation worktree）で
作業するためレーンごとの再実行が必要になる（`core/roles/generator.md` 参照）。一方 Codex の
generator は**サブエージェント専用 worktree を持たず、Epic worktree（`<EPIC_WT>`）で直接
作業する**（Step 3 参照）。したがって、ここで実行した1回がそのまま generator の作業ディレクトリに
効いており、二重に実行させる必要が無い。これは「機能差」ではなく、同じ保証（レーンの作業
ディレクトリで準備が効いていること）を worktree 構造の違いに応じて満たしているだけである。

`$SKIP_PATTERN` も**節が無ければ何もしない**（`skips=unknown` になった場合の扱いは
Step 5「SKIP を通過扱いにしない」参照）。空でなければ変数として保持し、Step 3の
generatorプロンプトとStep 5の統合ゲートの両方に `DEV_WORKFLOW_SKIP_PATTERN` として渡す
（節の書き方はREADME「Epic の `## SKIPパターン` 節」参照）。

**サンドボックスへのコマンド投入は `sandbox-exec.sh` 経由に統一する。** `docker run` を直接
組み立ててはならない。イメージの解決とビルド（`Dockerfile.dev` の内容 hash でタグ付けし自動
ビルドする。COPY 対象だけの変更を拾いたい場合は `--rebuild`）・キャッシュの永続化
（`docker run --rm` はコンテナ層ごとビルドキャッシュを毎回捨てる。対象パスは
`DEV_WORKFLOW_CACHE_PATHS` で上書き可）・コンテナの再利用（`--epic` 未指定時は
`DEV_WORKFLOW_EPIC` を参照する）・Windows のパス変換対策（Git Bash は `-w /workspace` を
`C:/Program Files/Git/workspace` に変換して失敗させる）をこのスクリプトが引き受ける。

### compose を使う場合の要求仕様

`docker-compose.dev.yml` を使う場合、常駐サービスが存在しないと `sandbox-exec.sh` が
`exec` できない。次の要求仕様を満たすこと:

- **常駐サービス名**: 既定 `app`（`DEV_WORKFLOW_COMPOSE_SERVICE` で変更可）
- **マウント**: 当該サービスが `.:/workspace` をマウントすること
  （異なるマウント先にする場合は `DEV_WORKFLOW_COMPOSE_WORKDIR` で上書きする）
- **長時間常駐**: `sleep infinity` 等でプロセスが終了しないこと（running でなければ
  `sandbox-exec.sh` は `up -d` を試みた上で、原因の分かるエラーを出して停止する）
- **`container_name:` と固定ホストポート（例: `- "8080:8080"`）を使わないこと** —
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

## 自律実行の開始を記録

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-start "Epic #<epic番号>"
```

run マーカーが置かれた直後に、ハング・スリープを検知する watchdog を起動する（`--start`
自体は自己デタッチして**即座に返る**。監視ループはプロセス外で動く常駐プロセスに移る）。
watchdog は run マーカー（`.claude/.dev-workflow-run`）の消失を自己終了条件の1つにしているため、
**マーカーより後に起動すること**（先に起動するとマーカーがまだ無い一瞬で誤って自己終了しうる）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --start --epic "$EPIC_NUM" --label "Epic #<epic番号>"
```

**Claude Code 版（`skills/run/SKILL.md`）と挙動は完全に同じである。** watchdog は無活動・
ウェーブ予算超過を検知して通知するだけで、**自動でエージェントを打ち切ることはしない**
（Epic #42「決定事項」参照。`codex exec` はプロセス外から中断できる技術的余地はあるが、
Claude Code のサブエージェントには同じことが原理的にできないため、**アダプタ間に機能差を
作らない**方針で両者とも「検知して通知するだけ」に揃えている）。

## 自律ループ（`lanes=1` 固定のウェーブ実行）

**ユーザー確認なしで**、以下のサイクルをタスクが無くなるまで繰り返す。
**タスクごとに evaluator を起動しない。**

```bash
SKIPPED_CSV=""   # 3回失敗して見送ったタスク番号のカンマ区切り。ループを回すうちに積み上げる

# WAVE_NO: wave ブランチ名（wave/${EPIC_NUM}/${WAVE_NO}）の通し番号。1タスク=1レーン=1ウェーブ
# として扱う。0 から始めてはならない（Task #54）。中断→再開（このスキルの再実行）では
# セッション変数が失われるため 0 から数え直すことになるが、`wave/${EPIC_NUM}/*` ブランチは
# ローカルに残り続ける（origin へ push しない設計）。0 から始めると前回の残骸 wave ブランチを
# そのまま掴んでしまう。既存の wave ブランチの番号の最大値から始めることで、再開時も必ず
# 新しい wave ブランチが使われる（残骸を掴んだ場合も Step 4 の `merge-lane.sh --create` が
# tip 不一致を検出し exit 1 で拒否する）。
WAVE_NO=$(git for-each-ref --format='%(refname:short)' "refs/heads/wave/${EPIC_NUM}/*" \
  | sed "s#^wave/${EPIC_NUM}/##" | sort -n | tail -1)
WAVE_NO="${WAVE_NO:-0}"
```

### Step 1: 次のタスクを依存グラフから選定する

`gh issue list` の先頭を素朴に取るのではなく、`scripts/plan-waves.sh` の出力から選ぶ。
`--lanes 1` を渡すため、常にウェーブ1のタスクが issue 番号の小さい順に並ぶ。
そのうち**先頭の1件だけ**を今回処理するタスクとする。

```bash
# plan-waves.sh の --epic は数値のEpic issue番号（$EPIC_ISSUE_NUM）。sandbox-exec.sh の
# --epic（epicXX形式の $EPIC_NUM）とは別の契約なので取り違えないこと
PLAN_ARGS=(--epic "$EPIC_ISSUE_NUM" --lanes 1)
[ -n "$SKIPPED_CSV" ] && PLAN_ARGS+=(--skipped "$SKIPPED_CSV")
PLAN="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh" "${PLAN_ARGS[@]}")"
PLAN_EXIT=$?
echo "$PLAN"
```

- `PLAN_EXIT` が **3**（循環依存）なら、列挙されたタスクをそのまま Epic issue にコメントし停止する
- `warn missing-deps <番号>` / `warn unknown-dep <番号> <dep番号>` が出力に含まれる場合、
  該当タスクの宣言漏れ・不明な依存を報告に含める（fail-safe で完全逐次扱いになっている旨も明記）
- 出力に `wave	1	tasks	...` の行が無い（＝全タスク完了）→ ループを終了し
  **「Epic一括レビュー」** へ進む
- `wave	1	tasks	4,5,10` のような行の**先頭（最小番号）**を今回のタスクとする

完了したタスクは `gh issue list --state open` から自然に消えるため、次回呼び出しの
`wave 1 tasks ...` は常に「次に処理すべきタスクを含む集合」になる（毎回再計算し、使い回さない）。

### Step 2: WAVE_BASE を記録し、レーン（作業ブランチ）を作る

```bash
git fetch origin && git checkout "${EPIC_BRANCH}" && git pull origin "${EPIC_BRANCH}"
WAVE_BASE=$(git rev-parse HEAD)
WAVE_NO=$((WAVE_NO + 1))
LANE_BRANCH="task/${EPIC_NUM}/<番号>"
git checkout -B "$LANE_BRANCH" "$WAVE_BASE"
```

`WAVE_BASE` は、このタスク（＝このウェーブ唯一のレーン）が分岐する唯一の正しい起点である。

ウェーブ予算の監視（watchdog）に、このウェーブの内訳を伝える（generator を起動する前に）。
**Codex は `lanes=1` 固定の縮退版なので、1タスク = 1ウェーブとして扱う**:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --wave --epic "$EPIC_NUM" \
  --wave-no "$WAVE_NO" --tasks "<番号>"
```

### Step 3: generator サブエージェントで実装

`generator` エージェントを起動し、以下を渡す。

```
Task #<番号> を実装してください。
- WAVE_BASE: <WAVE_BASEのコミットハッシュ>（ブランチ名ではなくこのハッシュそのものに対して検証すること）
- あなたの作業ブランチ（<LANE_BRANCH>）は Step 2 で `git checkout -B` によって WAVE_BASE から
  作成済みであり、既に WAVE_BASE の子孫のはずである。**Claude 版の generator と同じ保証を
  同じ手順で確認するため**、実装に着手する前に次の手順を1回だけこの順序で実行すること
  （通常はno-opになる）。**自分のコミットを積んだ後に再実行しないこと**（手順2を再実行すると
  積んだコミットが失われる）。
  1) `git status --short`（空であることを確認。空でなければ実装を始めず、実出力を添えて
     報告し停止すること）
  2) `git reset --hard <WAVE_BASE>`（HEADをWAVE_BASEに合わせる。fetch/checkout/pullでは
     ないためネットワーク不要）
  3) `git merge-base --is-ancestor <WAVE_BASE> HEAD && echo BASE_OK`（偽なら実装を始めず、
     実出力を添えて報告し停止すること）
  4) `git log --oneline -1`（実際のHEADを報告に載せる）
  手順1〜4の実出力を報告に含めること（自己申告にしない）
- **`git fetch` / `git checkout` / `git pull` は実行しないこと。** 同期は run が Epic 専用
  worktree で既に済ませている。手順2の `git reset --hard` のみが例外として許可されている
- 作業ディレクトリ: <EPIC_WT>（ここから移動しないこと）
- **サンドボックスに渡すコマンドの中で `cd` して作業ディレクトリを変えないこと。**
  `sandbox-exec.sh` は呼び出し元cwdから workdir を解決するため、`cd` はそれを上書きし、
  自分の変更を含まないツリーを検証してしまう（サブディレクトリだけを対象にしたい場合は
  `cd` ではなく `make -C sub test` のようにコマンド側の相対指定で行うこと）
- サンドボックスへのコマンド投入は `${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh` 経由で行い、
  ビルド・テストは1回の呼び出しにまとめること（分けると待ち時間が倍増する）
- `sandbox-exec.sh` を呼ぶ際は必ず `--epic "$EPIC_NUM"` を渡すこと。省略すると環境変数
  `DEV_WORKFLOW_EPIC` が参照されるので、渡し忘れた場合は `export DEV_WORKFLOW_EPIC="$EPIC_NUM"`
  してから叩くこと。渡し忘れると Epic 単位のコンテナに載らずタスクごとに別コンテナが生まれる
- プロジェクト固有の準備（wasm配置等）は Epic 開始時に run が `<EPIC_WT>`（＝あなたの作業
  ディレクトリそのもの）に対して1回実行済みである。**あなたはその1回がそのまま効く場所で
  作業している**（Claude版のように別ツリーで作業するわけではないため）。準備コマンドは渡されて
  いない。効いていないと判断した場合も自前で追加実行せず、その事実を報告すること
- 回帰確認はプロジェクトの全テストで行うこと。`-run` で絞った結果を「回帰なし」と報告しないこと
- **SKIP件数は `tail` の目視ではなく `scripts/count-skips.sh` で機械的に数えること。**
  テスト出力を `tee` でログに保存してから数え、**数えたコマンドと実出力をそのまま報告に貼ること**
  （`tail` で目視して「0件」と報告することは禁止する）:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" '[全テストコマンド]' \
    2>&1 | tee /tmp/test-output.log
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/count-skips.sh" --file /tmp/test-output.log
  ```
  （`$SKIP_PATTERN` が空でない場合のみ、次の行を追加する。空の場合はこの行を出さない）
  このプロジェクトのテスト出力は built-in ランナー（go/jest/pytest）と形式が異なるため、
  `count-skips.sh` を呼ぶ前に次を実行してから数えること:
  `export DEV_WORKFLOW_SKIP_PATTERN='[SKIP_PATTERNの内容]'`
  - `skips=<件数>`（exit 0）→ その件数を報告する。想定外のSKIPは不合格として扱う
  - `skips=unknown`（exit 1）→ **「0件」と報告してはならない。** built-inランナー以外の
    形式のため数えられなかった事実と、`DEV_WORKFLOW_SKIP_PATTERN`（Epic本文の
    `## SKIPパターン` 節）の設定が必要である旨を報告すること。この場合に限り、
    `tail` ではなく生のテスト出力全体を読み、SKIPを示す行が無いか自分の目でも確認すること
- issueの要件を確認すること。Task issueの記載だけで着手できない場合に限り、
  親Epic issue本文の仕様書・計画書を確認すること
- テストファーストで実装すること
- 変更を `<LANE_BRANCH>` にコミットすること
- 報告には「実際に叩いたテストコマンドの全文」と「ベース検証の実出力」を含めること
```

#### トークン消費の記録（効果測定。Task #76・決定3でClaude版と同じ結線を入れる）

Codex にはClaude Codeの「Task完了時に `N tool uses · Xk tokens · Ym Zs` を表示する」に相当する
既定の要約表示が無い。**Codex側でトークン数が取得できない場合は、その事実を明記した上で
記録をスキップする。** `codex exec` を JSON 出力形式（`--json` 等、上流の対応状況に応じて）で
起動し使用量が取得できた場合に限り記録する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role generator --mode "タスク実装" --tokens [取得できたトークン数] --note "#<番号>"
```

取得できない場合は何も呼ばず、次のStepへ進む。**`record-agent-tokens.sh` の成否・トークン数の
有無に関わらず、自律ループは止めない。**

### Step 4: レーンを wave ブランチへ取り込む

```bash
WAVE_BRANCH="wave/${EPIC_NUM}/${WAVE_NO}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-lane.sh" \
  --wave-branch "$WAVE_BRANCH" --expected-base "$WAVE_BASE" \
  --lane-branch "$LANE_BRANCH" --task <番号> --create
```

終了コードで扱いを分岐する:

| 終了コード | 意味 | 扱い |
|---|---|---|
| 0 | 取り込み成功 | Step 5 へ |
| 10 | merge-base ≠ WAVE_BASE（ベース逸脱） | 取り込まず差し戻す。実出力を issue にコメント。**cherry-pick による載せ替えはしない** |
| 11 | マージ競合（`git merge --abort` 済み） | 取り込まず、stdout の競合ファイル一覧を issue にコメント |
| 2 | 引数エラー | run の呼び出しミス。停止して報告する |
| 1 | その他の失敗 | 停止して報告する |

10 / 11 のときは Step 6 のリカバリへ進む。

### Step 5: wave ブランチで統合ゲートを実行し、Epic ブランチへ取り込む

```bash
git checkout "$WAVE_BRANCH"

# 1) テスト（Docker sandbox内）— 1回にまとめる。落ちたら不合格
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" '[全テストを走らせるコマンド]' \
  2>&1 | tee /tmp/gate-test-output.log

# 1b) SKIP件数はgeneratorの自己申告に依存せず、run自身がcount-skips.shで機械的に数える。
#     0件でも必ず表示する（黙って省略しない）
[ -n "$SKIP_PATTERN" ] && export DEV_WORKFLOW_SKIP_PATTERN="$SKIP_PATTERN"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/count-skips.sh" --file /tmp/gate-test-output.log

# 2) 可読性ガード — waveブランチの差分に対して実行（PostToolUseフックと同じ判定）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh" --git
```

品質・設計・セキュリティの観点はここでは見ない。**それらは Epic完了後の一括レビューで見る。**

内容の要件は Claude 版（`skills/run/SKILL.md` Step 6）と同じ2コマンド構成（全テスト + 可読性
ガード）とする。**対象の選択を generator に委ねない。** ゲートで走らせるのは**プロジェクトの
全テスト**とする。`make test` 等のプロジェクト標準ターゲットがあればそれを優先する。

- ビルドタグ付きのテスト（`//go:build integration` 等）があるプロジェクトでは、それも含める
- ビルド・vet・テストを**別々の呼び出しに分けない**。サンドボックスはソースツリーを
  バインドマウントしており、フルツリーを走査するコマンドは1回ごとにその走査コストを払う
- テストがビルドを兼ねるなら（`go test ./...` 等）、それ1本で足りる

#### SKIP を通過扱いにしない

依存物が未配置だとテストが無言で `SKIP` され、`ok` と表示されて成功に見える。
**`ok` の有無だけで判定してはならない。** SKIP件数の数え方は自然言語の依頼にせず、
`scripts/count-skips.sh` に固定する（`tail` の目視で「0件」と判定することを禁止する。
上記1b参照）。

- `skips=<件数>`（exit 0）→ その件数を確認し、検証したかったテストが実際に走ったことを
  確かめる。**想定外のSKIPは不合格として扱う**
- `skips=unknown`（exit 1）→ **「0件」として扱ってはならない。** built-inランナー
  （go/jest/pytest）以外の形式であるため数えられなかったことを Epic issue に明記し、
  `DEV_WORKFLOW_SKIP_PATTERN`（Epic本文の `## SKIPパターン` 節）の設定を促す。
  この1件のために run 全体を必ず停止させるわけではないが、「0件」への読み替えは常に禁止する。
  **恒久対処として、次の run までに Epic issue 本文へ `## SKIPパターン` 節（ERE1行）を
  追加することを明記する。** 都度コメントで済ませるだけでは同じ run が来るたびに
  `skips=unknown` を繰り返すだけで、SKIP件数が検証されないまま進む状態が固定化する
  （書き方は `core/roles/planner.md`「SKIPパターン（該当する場合のみ）」節を参照）

- **通過** →

```bash
git checkout "${EPIC_BRANCH}"
git merge --ff-only "$WAVE_BRANCH"
git push origin "${EPIC_BRANCH}"
gh issue close <番号>
```

`WAVE_BASE` から wave ブランチまでは常に fast-forward 可能である（`merge-lane.sh` が
merge-base を `WAVE_BASE` に一致させることを Step 4 で保証しているため）。取り込めたら
Epic issue の進捗チェックリストを更新し、Step 1 に戻る。

- **失敗** → Step 6 のリカバリへ（Epic ブランチは無傷のまま）

### Step 6: 失敗時のリカバリ

**共通原則: cherry-pick による載せ替えは行わない。** 検証されていないツリーを作る経路を残さない。

| 失敗パターン | 扱い |
|---|---|
| `merge-lane.sh` exit 10（ベース逸脱） | 取り込まず差し戻す。実出力を issue にコメントし、レーンを作り直して再試行する |
| `merge-lane.sh` exit 11（マージ競合） | 取り込まず、競合ファイル一覧を issue にコメントし、レーンを作り直して再試行する |
| 統合ゲート失敗（Step 5） | Epic は無傷のまま。`lanes=1` のため原因はこのタスクのレーンに一意に特定できる。レーンを作り直して再試行する |
| 同一タスクで3回失敗 | スキップする。issue にコメントし、`SKIPPED_CSV` に加える（以降の `plan-waves.sh` 呼び出しの `--skipped` に反映される） |

**スキップの伝播**: スキップされたタスクに依存する後続タスクは、`plan-waves.sh` の出力
（`skip	<番号>	reason	depends-on-skipped	<依存先番号>`）に従って実行せずスキップし、
issue にその旨をコメントする（推移的に伝播する）。**`plan-waves.sh` はタスクループのたびに
再計算されるため、同じ `skip` 行は該当タスクが解消される（依存が完了する／`--skipped` から
外れる）まで繰り返し出力される。** 一度コメントしたタスク番号は憶えておき、二重にコメント
しないこと。スキップ一覧は Epic 一括レビュー前に Epic issue へコメントし、PR 本文にも明記して
人間に判断を渡す。

## サンドボックスの後片付け（正常終了・異常終了を問わず必ず実行）

自律ループが終わる経路は複数ある（全タスク完了 → Epic一括レビュー → PR作成、機械的ゲートの
失敗が続いてタスクをスキップし続けた末の停止、予期しないエラーによる中断）。
**どの経路で終わる場合も、後続処理（PR作成や中断報告）に進む前に、必ず次のクリーンアップを
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

**キャッシュ volume は削除しない。** 次の Epic でそのまま効くのが利点である。明示的に消したい
場合のみ `--reset-cache` を使う（**作用範囲は epic ではなくリポジトリ全体**。同一リポジトリの
他 epic のコンテナが running なら中断され、続けるには `--force` が必要）。

自律実行の外で残存コンテナを棚卸ししたい場合は次を使う:

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
   **Claude Code版とは異なり、これはツール呼び出しを強制的にブロックしない。** Codex の
   `PreToolUse` フックは `systemMessage` のみに対応し `continue` は読まないため
   （`docs/dev-workflow-multi-vendor-guide.md` §3.5.2）、`heartbeat.sh pre` が次にツールを
   呼んだ瞬間に打ち切り理由入りの `systemMessage` を返しても、そのツール呼び出し自体は
   そのまま実行される。**モデルがそのメッセージを読んで自発的に停止することを期待する
   ソフトな打ち切り依頼にとどまる。** 確実に・即座に止めたい場合は Codex 側の
   セッション（`codex exec` プロセス。無人ループなら `run-loop.sh` ごと）を人間が中断する。
   **セッションを中断した場合は Stop フックが走らず run マーカー（`.dev-workflow-run`）が
   削除されないまま残るため、続けて
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --stop` を実行して watchdog を止めること。**
   放置すると watchdog は打ち切りに気付かず無活動検知（15分）・エスカレーション（30分ごと最大3回）を
   続け、既に打ち切ったはずの run について「応答なし」の通知が届き続ける

   **`--abort` が届く保証があるのは `run-loop.sh`（`adapters/codex/run-loop.sh`）経由で
   `codex exec -C "$EPIC_WT"` として起動される generator/evaluator セッションに限られる**
   （`heartbeat.sh` が拒否対象と判定する cwd パターン `.codex/worktrees/` は、この起動経路の
   セッションを想定したものである。詳細は `scripts/heartbeat.sh` 冒頭コメント参照）。
   **このスキル（`dev-workflow-run`）をセッション内で直接回している場合は `--abort` に
   依存できない。** このスキルは冒頭で `cd "$EPIC_WT"` した後、同一セッション内で
   generator/evaluator サブエージェントを呼ぶ。Codex のカスタムエージェントには cwd 相当の
   設定項目が無くセッションの cwd をそのまま継承するため（`docs/dev-workflow-multi-vendor-guide.md`
   §3.3.3）、メインループ（このスキル自身）とサブエージェントのツール呼び出しを cwd で
   区別できず、`--abort` はメインループのツール呼び出しにも及びうる（あるいは全く効かない）。
   **このスキルをセッション内で直接回している場合、確実に止められる唯一の手段は本節冒頭のとおり
   セッションそのものを中断し、続けて `watchdog.sh --stop` を実行することである。**
3. **再開する場合**: `dev-workflow-run` スキルを再実行する。次の3点により、中断→再開でも
   安全に途中から続けられる（Task #54）。
   - **残タスクは open な Task issue から再計算される。** クローズ済みのタスクは
     `plan-waves.sh` の対象から自然に外れるため、完了分をやり直すことはない
   - **wave ブランチは採番し直される。** `WAVE_NO` はセッション変数のため再実行のたびに
     失われるが、上記「自律ループ」節のとおり既存の `wave/${EPIC_NUM}/*` ブランチの番号の
     最大値から数え直すため、前回の残骸ブランチを再利用しない。万一 Step 4 の
     `merge-lane.sh --create` が残骸 wave ブランチ（tip が `--expected-base` と不一致）を
     掴んだ場合は exit 1 で拒否され、Epic ブランチ・wave ブランチのどちらも変更されない
   - **取り込み済みのコミットは失われない。** 統合ゲートを通過して Epic ブランチへ
     `git merge --ff-only` 済みのコミットは Epic ブランチ上に残り続ける

**Codex 側でも「自動で打ち切って再投入する」ことは実装しない。** `adapters/codex/run-loop.sh`
は `codex exec` を子プロセスとして起動しているため、プロセス外から TERM/KILL を送るハード
タイムアウトと自動再投入は技術的には実装できる。しかし Claude Code 側ではサブエージェントが
同一プロセス内の API 呼び出しであり、**同じことが原理的にできない**（Epic #42「2. サブ
エージェントを外部から中断する手段は無い」参照）。Codex だけに自動打ち切りを入れると
「どちらの CLI で回したか」で挙動と運用手順が変わってしまうため、**アダプタ間に機能差を
作らない**方針であえて実装しない。watchdog にできるのは検知して通知することまでであり、
打ち切りの主体は常に人間である。

## Epic一括レビュー（全タスク完了後・PR作成前）

ここで初めて evaluator を起動する。**最大2巡**（初回 + delta-review 1回）。

### R1: 一括レビュー

`evaluator` エージェントを起動する。`sandbox_mode = "read-only"` なので
コンテナ起動によるテスト実行ができない場合がある。その場合はテスト結果を
こちらで取得して渡す。

```
Epic #<epic番号> の全変更をレビューしてください。
- モード: epic-review
- 差分範囲: main...<EPIC_BRANCH>
- 作業ディレクトリ: <EPIC_WT>
- 親Epic issueの仕様書と照合し、実装漏れも指摘すること
- テスト実行結果: <Step 3 で generator が報告した結果>
- 最後に必ずJSON（verdict / reviewed_commit / findings）を出力すること
```

ヘッドレスで起動する場合は判定JSONをスキーマで強制できる。

```bash
codex exec --output-schema "${CLAUDE_PLUGIN_ROOT}/adapters/codex/schemas/evaluator-verdict.json" \
  -o /tmp/verdict.json -C "$EPIC_WT" \
  "evaluator として Epic #<epic番号> の main...<EPIC_BRANCH> をレビューせよ"
```

トークン数が取得できた場合のみ記録する（取得できない場合はその事実を明記し、記録をスキップする。
Task #76・自律ループは止めない）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role evaluator --mode epic-review --tokens [取得できたトークン数]
```

### R2: 指摘をissue化

`high` と `medium` の指摘だけを issue にする。`low` は PR本文に記録するだけ。

```bash
gh label create review --color B60205 --description "一括レビューの指摘" --force

gh issue create --label "task,review" --title "Review: <title>" --body "$(cat <<'BODY'
## 指摘（重要度: <severity>）

<detail>

## 該当箇所
`<location>`

## 修正方針
<fix>

## 由来
- Epic: #<epic番号>
- 起因タスク: <task_ref>
- レビュー時点: `<reviewed_commit>`
BODY
)"
```

`reviewed_commit` は次の delta-review の起点になるので必ず控える。

### R3: 指摘対応

`APPROVE` ならPR作成へ。`REQUEST_CHANGES` なら review issue を1件ずつ generator に渡し
（通常タスクと同じ Step 2〜6）、全件対応後に delta-review を1回だけ行う。

```
Epic #<epic番号> の指摘対応を確認してください。
- モード: delta-review
- 差分範囲: <R1のreviewed_commit>..<EPIC_BRANCH>
- 指定範囲外の蒸し返しはしないこと
- 最後に必ずJSONを出力すること
```

R1と同じ作法でこのdelta-review呼び出しのトークン消費も記録する（取得できた場合のみ。
取得できなければスキップし、自律ループは止めない）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role evaluator --mode delta-review --tokens [取得できたトークン数]
```

### R4: 打ち切り

2巡目でも `REQUEST_CHANGES` が残る場合は**打ち切ってPRを作成する。** 未対応の指摘は
issue をオープンのまま残し、PR本文に列挙して人間の判断に委ねる。

### レビュー粒度の調整

R1 の起動前に変更ファイル数を数え、しきい値（目安: 変更50ファイル超。`skills/run/SKILL.md`
の既存しきい値と同じ）で3つに分岐する。**新しいしきい値の軸は増やさず、この50ファイル超の
しきい値に相乗りする。**

dev-workflow は**駆動先プロジェクト**でこの SKILL.md を実行するプラグインであり、駆動先の
デフォルトブランチが `main` とは限らない。**ベースブランチを `master`/`main` に決め打ちしない**
（dev-workflow 自身のリポジトリのデフォルトブランチが `master` であっても、それを駆動先の値
として埋め込んではならない）。`gh repo view` で駆動先の実際のデフォルトブランチを解決する:

```bash
BASE_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
BASE_BRANCH="${BASE_BRANCH:-main}"

if CHANGED_FILES_LIST="$(git diff --name-only "${BASE_BRANCH}...${EPIC_BRANCH}")"; then
  CHANGED_FILES="$(printf '%s\n' "$CHANGED_FILES_LIST" | grep -c '.')"
else
  echo "WARN: git diff ${BASE_BRANCH}...${EPIC_BRANCH} に失敗し、変更ファイル数を数えられなかった。Phase 単位分割にフォールバックする" >&2
  CHANGED_FILES=""
fi
```

`git diff` を `wc -l` に直接パイプしない。パイプすると `git diff` が失敗しても `wc -l` は0を
返して**失敗を握り潰し**、「CHANGED_FILES <= 50 → 従来どおり」に誤判定してしまう
（ベースブランチが存在しない等で起きうる）。上記のとおり `git diff` 自体の終了コードを見て、
失敗時は `CHANGED_FILES` を空にし、**サイズ不明のまま「従来どおり（分割なし）」に倒さず**
Phase 単位分割へフォールバックする。

| 条件 | 挙動 |
|---|---|
| `CHANGED_FILES` を数えられなかった（`git diff` 失敗） | **Phase 単位分割にフォールバックする**（既存の回避策。サイズ不明の場合に安全側へ倒す） |
| `CHANGED_FILES` <= 50 | **従来どおり。** code-review-graph には一切触れない（グラフ構築もしない） |
| `CHANGED_FILES` > 50 かつ code-review-graph が利用可能（`command -v code-review-graph`） | evaluator への指示に「blast radius の算出を使って読む優先順位を付けてよい」旨を含めて起動する |
| `CHANGED_FILES` > 50 かつ code-review-graph が未導入 | **従来どおり**、R1 を Phase 単位に分割して起動する |

code-review-graph が利用可能な場合でも、Phase 単位の分割を**禁止はしない**（両立してよい）。
どちらの場合も**タスク単位には戻さない**。

blast radius を使う場合の指示例（R1 の基本形に1行加えるだけでよい）:

```
Epic #<epic番号> の全変更をレビューしてください。
- モード: epic-review
- 差分範囲: main...<EPIC_BRANCH>
- 変更ファイル数が50超のため、code-review-graph の blast radius の算出を使って読む優先順位を付けてよい
- 最後に必ずJSON（verdict / reviewed_commit / findings）を出力すること
```

code-review-graph が未導入の場合（従来どおり Phase 単位に分割する既存の回避策）:

```
Epic #<epic番号> のうち Phase 1 の変更をレビューしてください。
- 差分範囲: main...<EPIC_BRANCH> のうち <Phase1で変更されたファイル群>
```

## PR作成（最終責務）

```bash
git push origin "${EPIC_BRANCH}"
gh pr create --base main --head "${EPIC_BRANCH}" --title "Epic: <機能名>" --body "..."
```

PR本文には Summary（`Closes #<epic番号>`）、完了タスク、レビュー結果、未対応の指摘、
軽微な指摘、Test plan を含める。**PRを作成せずに終了してはならない。**

### PR本文への「トークン消費」集計（効果測定。Task #76・決定3）

Claude版（`skills/run/SKILL.md`）と同じく、「実行時間」相当の集計の隣に
`record-agent-tokens.sh --summary` の出力をそのまま載せる:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" --summary --epic "$EPIC_NUM"
```

```
## トークン消費
[record-agent-tokens.sh --summary --epic "$EPIC_NUM" の出力をそのまま貼る]

比較対象（Epic #42実測。docs/optional-mcp-tools.md「効果測定のベースライン」参照）:
generator タスク実装 81k〜150k / evaluator delta-review 83k / evaluator epic-review 139k。
```

Codex側でトークン数が一度も取得できず1件も記録が無い場合は、その旨を一行明記した上で
このセクションを省略してよい。**記録の有無はPR作成のブロッカーにしない。**

## 完了通知

PRのURLが取れた時点だけで実行する。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-complete \
  "全<N>タスク完了（スキップ<M>件）
PR: <PRのURL>"
```

到達せず終了した場合は Stop フックが「自律実行が停止」として自動通知する。

## クリーンアップ（worktree）

サンドボックスの後片付け（常駐コンテナの `--down`）は「自律ループ」の直後の節で
**既に実行済み**である（正常終了・異常終了を問わず必ず実行する節）。ここでは worktree のみを
片付ける。

```bash
# worktree の削除前に node_modules 等の symlink を解除する
# （symlink 越しにメインリポの実体が消えるため）
cd "$(git rev-parse --show-toplevel)"
find ".codex/worktrees/${EPIC_NUM}" -maxdepth 2 -type l -name node_modules -exec unlink {} \; 2>/dev/null || true
git worktree remove ".codex/worktrees/${EPIC_NUM}" --force 2>/dev/null || true
git worktree prune
```

**`scripts/cleanup-lane-worktrees.sh`（レーンworktreeの片付け）は該当なし。** Codex の
generatorはサブエージェント専用worktreeを持たず、Epic worktree（`<EPIC_WT>`）で直接作業する
ため、Claude Codeの`.claude/worktrees/agent-*`に相当するレーンworktreeの蓄積自体が起きない。
上記のEpic worktree削除だけで足りる。

## 自律動作ポリシー

- ユーザーへの確認・質問は行わない
- 機械的ゲートに同一タスクで3回失敗 → スキップして issue にコメント。依存先スキップの伝播は
  `plan-waves.sh` の出力に従う
- タスクループ中に evaluator を起動しない
- 一括レビューは最大2巡で打ち切る
- **main には絶対にマージしない**
- **Epic ブランチには統合ゲートを通過したコミットだけを載せる。force push は行わない**
- **generator を並行実行しない**（サブエージェント専用 worktree がないため）。`lanes=1` 固定
  だが、ウェーブ・merge-base 検証・wave ブランチ経由の統合は Claude 版と同じ仕様を適用する
- テスト時に実ユーザーへメールを送らない。本番データに触らない
