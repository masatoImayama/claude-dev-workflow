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
EPIC_NUM=$(printf '%s' "$EPIC_BRANCH" | grep -oE 'epic[0-9]+' | head -1)

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
```

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

## 自律ループ

全 Task issue が完了するまで以下を繰り返す。**タスクごとに evaluator を起動しない。**

### Step 1: 次のタスクを選定

未クローズの Task issue を Phase 順、同一 Phase 内は issue番号の小さい順に並べ、先頭を選ぶ。

```bash
gh issue list --label task --state open --json number,title,body --limit 100
```

### Step 2: Epicブランチを最新に同期

```bash
git fetch origin && git checkout "${EPIC_BRANCH}" && git pull origin "${EPIC_BRANCH}"
```

### Step 3: generator サブエージェントで実装

`generator` エージェントを起動し、以下を渡す。

```
Task #<番号> を実装してください。
- Epicブランチ: <EPIC_BRANCH>（最新は commit <ハッシュ>）
- 作業開始前に `git fetch origin` で同期し、`git merge-base --is-ancestor origin/<EPIC_BRANCH> HEAD`
  でベースを検証すること。偽なら実装を始めず、実出力を添えて報告し停止すること
- 作業ディレクトリ: <EPIC_WT>（ここから移動しないこと）
- サンドボックスへのコマンド投入は `${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh` 経由で行い、
  ビルド・テストは1回の呼び出しにまとめること（分けると待ち時間が倍増する）
- `sandbox-exec.sh` を呼ぶ際は必ず `--epic "$EPIC_NUM"` を渡すこと。省略すると環境変数
  `DEV_WORKFLOW_EPIC` が参照されるので、渡し忘れた場合は `export DEV_WORKFLOW_EPIC="$EPIC_NUM"`
  してから叩くこと。渡し忘れると Epic 単位のコンテナに載らずタスクごとに別コンテナが生まれる
- 回帰確認はプロジェクトの全テストで行うこと。`-run` で絞った結果を「回帰なし」と報告しないこと
- SKIP されたテストがあれば件数と内容を報告に含めること
- issueの要件と、親Epic issue本文の仕様書・計画書を確認すること
- テストファーストで実装すること
- 変更をコミットすること
- 報告には「実際に叩いたテストコマンドの全文」と「ベース検証の実出力」を含めること
```

### Step 4: 機械的ゲート（レビューなし）

```bash
# テスト＋ビルド（サンドボックス内）— 1回にまとめる
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" '<全テストを走らせるコマンド>'

# 可読性ガード
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh" --git
```

ゲートで走らせるのは**プロジェクトの全テスト**とする（`make test` 等の標準ターゲットを優先し、
対象の選択を generator に委ねない）。ビルドタグ付きテストがあれば含める。
ビルド・vet・テストを別々に呼び出すと、バインドマウントのツリー走査コストを毎回払うため
待ち時間が倍増する（実測: 1コマンドあたり約2分）。

**SKIP を通過扱いにしない。** 依存物が未配置だとテストが無言で `SKIP` され `ok` と表示される。
SKIP件数を確認し、検証したかったテストが実際に走ったことを確かめる。

- 全通過 → Step 5
- いずれか失敗 → 失敗ログを generator に渡して Step 3 に戻る（**同一タスクで3回失敗したらスキップ**し、
  issue にコメントを残して次へ）

品質・設計・セキュリティはここでは見ない。**Epic完了後の一括レビューで見る。**

### Step 5: 取り込んで次へ

**マージは必ず `--ff-only` で行う。** generator の「ベースは正しい」という報告を信じてはならない。
指示と異なるベース（例: main）から分岐していてもテストは通ってしまうため、報告では検出できない。

```bash
git checkout "${EPIC_BRANCH}"
git merge --ff-only "<generatorの作業ブランチ>"
```

`fatal: Not possible to fast-forward` で失敗したら、実際の分岐元を確認する:

```bash
git log --oneline -1 "$(git merge-base "${EPIC_BRANCH}" "<作業ブランチ>")"
```

誤ったベースなら cherry-pick で載せ替え、**載せ替え後に Step 4 のゲートを再実行する**
（先行タスクの変更が無いツリーで実装されているため、自動マージ成功＝安全ではない）。

```bash
git push origin "${EPIC_BRANCH}"
gh issue close <番号>
```

Epic issue の進捗チェックリストを更新し、Step 1 に戻る。

## サンドボックスの後片付け（正常終了・異常終了を問わず必ず実行）

自律ループが終わる経路は複数ある（全タスク完了 → Epic一括レビュー → PR作成、機械的ゲートの
失敗が続いてタスクをスキップし続けた末の停止、予期しないエラーによる中断）。
**どの経路で終わる場合も、後続処理（PR作成や中断報告）に進む前に、必ず次のクリーンアップを
実行すること。** 完了通知の後ろに置いて成功時にしか実行されない、ということがあってはならない。

```bash
# 常駐コンテナの削除（epic 単位。キャッシュ volume は次の Epic のために残す）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --down
```

**キャッシュ volume は削除しない。** 次の Epic でそのまま効くのが利点である。明示的に消したい
場合のみ `--reset-cache` を使う（**作用範囲は epic ではなくリポジトリ全体**。同一リポジトリの
他 epic のコンテナが running なら中断され、続けるには `--force` が必要）。

自律実行の外で残存コンテナを棚卸ししたい場合は次を使う:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --ls          # 管理コンテナを一覧表示（他リポジトリ分も含む）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --down --all   # 現在のリポジトリに属する管理コンテナを全て削除
```

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
- テスト実行結果: <Step 4 で取得した結果>
- 最後に必ずJSON（verdict / reviewed_commit / findings）を出力すること
```

ヘッドレスで起動する場合は判定JSONをスキーマで強制できる。

```bash
codex exec --output-schema "${CLAUDE_PLUGIN_ROOT}/adapters/codex/schemas/evaluator-verdict.json" \
  -o /tmp/verdict.json -C "$EPIC_WT" \
  "evaluator として Epic #<epic番号> の main...<EPIC_BRANCH> をレビューせよ"
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
（通常タスクと同じ Step 3〜5）、全件対応後に delta-review を1回だけ行う。

```
Epic #<epic番号> の指摘対応を確認してください。
- モード: delta-review
- 差分範囲: <R1のreviewed_commit>..<EPIC_BRANCH>
- 指定範囲外の蒸し返しはしないこと
- 最後に必ずJSONを出力すること
```

### R4: 打ち切り

2巡目でも `REQUEST_CHANGES` が残る場合は**打ち切ってPRを作成する。** 未対応の指摘は
issue をオープンのまま残し、PR本文に列挙して人間の判断に委ねる。

## PR作成（最終責務）

```bash
git push origin "${EPIC_BRANCH}"
gh pr create --base main --head "${EPIC_BRANCH}" --title "Epic: <機能名>" --body "..."
```

PR本文には Summary（`Closes #<epic番号>`）、完了タスク、レビュー結果、未対応の指摘、
軽微な指摘、Test plan を含める。**PRを作成せずに終了してはならない。**

## 完了通知

PRのURLが取れた時点だけで実行する。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-complete \
  "全<N>タスク完了（スキップ<M>件）
PR: <PRのURL>"
```

到達せず終了した場合は Stop フックが「自律実行が停止」として自動通知する。

## クリーンアップ（worktree）

サンドボックスの後片付け（常駐コンテナの `--down`）は「Step 5: 取り込んで次へ」の直後の節で
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

## 自律動作ポリシー

- ユーザーへの確認・質問は行わない
- 機械的ゲートに同一タスクで3回失敗 → スキップして issue にコメント
- タスクループ中に evaluator を起動しない
- 一括レビューは最大2巡で打ち切る
- **main には絶対にマージしない**
- **generator を並行実行しない**（サブエージェント専用 worktree がないため）
- テスト時に実ユーザーへメールを送らない。本番データに触らない
