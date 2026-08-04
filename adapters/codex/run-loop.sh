#!/bin/bash
# dev-workflow: Codex CLI による無人自律ループ
#
# ループをシェル側に置き、1回の `codex exec` = 1役 として起動する。
# これにより役割ごとに文脈が分離される（Codex のサブエージェントには専用 worktree が
# ないため、セッションを分けることが最も強い分離手段になる）。
#
# タスクの実行順序は `scripts/plan-waves.sh`（Epic #14）が計算する依存グラフに従う。
# Codex はサブエージェント専用 worktree を持たないため generator を並行実行できず、
# `--lanes 1` 固定で呼び出す。1タスク = 1レーン = 1ウェーブとして扱い、各タスクの成果は
# `scripts/merge-lane.sh` で wave ブランチへ取り込んでから Epic ブランチへ `--ff-only` で
# 合流させる（`skills-codex/dev-workflow-run/SKILL.md` と同じ経路。詳細はそちらを参照）。
#
# 使い方:
#   bash adapters/codex/run-loop.sh <Epic issue番号> [プロジェクトパス]
#
# 環境変数:
#   DEV_WORKFLOW_CODEX_GENERATOR_MODEL  generator に使うモデル
#   DEV_WORKFLOW_CODEX_EVALUATOR_MODEL  evaluator に使うモデル
#   DEV_WORKFLOW_MAX_ATTEMPTS           同一タスクの再試行上限（既定: 3）
#   DEV_WORKFLOW_MAX_TASKS              1回の実行で処理するタスク数の上限（既定: 50）
#   DEV_WORKFLOW_DRY_RUN=1              codex を起動せず、実行予定の内容だけ表示する
#   DEV_WORKFLOW_TEST_CMD                統合ゲート（mechanical_gate）で実行するプロジェクトの
#                                        全テストコマンド（必須。既定値はない）。対象の選択を
#                                        generator に委ねないため、run 側のこの変数で固定する。
#                                        例: DEV_WORKFLOW_TEST_CMD='bash tests/run-tests.sh'
#
# 注意: このスクリプトは `--dangerously-bypass-approvals-and-sandbox` を使う。
#       Codex 側の承認プロンプトを飛ばすため、**信頼できるリポジトリでのみ**使うこと。
#       Codex にはターン数の上限設定がないため、暴走の抑止は
#       このスクリプトの反復回数上限と、各役割のプロンプト規約で担保している。
#
# watchdog（Epic #42 決定事項4。Task #53）: `scripts/watchdog.sh` を Claude Code 版
# （`skills/run/SKILL.md`）と同じ経路（--start → 各タスク開始時に --wave → 終了時に --stop）
# で結線する。**アダプタ間に機能差を作らないため**、Codex 側もハングを検知して通知するだけに
# 揃える。ここに `codex exec` に対するタイムアウト監視・TERM/KILL・打ち切り後の自動再投入は
# 実装しない（`codex exec` は子プロセスとして起動しているため技術的には可能だが、Claude Code の
# サブエージェントには同じことが原理的にできず、CLI ごとに挙動が変わってしまうため）。

set -uo pipefail

PLUGIN_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# watchdog の --stop を、正常終了・異常終了・途中の exit を問わず必ず1回通す。
# 引数エラー等 --start より前に落ちる経路でも安全に呼べる（watchdog.sh --stop は
# 「起動していない」場合 exit 0 で何もしない）。watchdog.sh 自体が無い・失敗する
# 環境でもループを止めないよう `|| true` で握りつぶす。PLUGIN_ROOT_DIR の直後、
# 最初の `exit` より前に trap を仕掛けることで、以降のどの経路で終了しても通る。
_run_loop_watchdog_stop() {
  bash "${PLUGIN_ROOT_DIR}/scripts/watchdog.sh" --stop >/dev/null 2>&1 || true
}
trap '_run_loop_watchdog_stop' EXIT

EPIC_NUMBER="${1:-}"
PROJECT_ROOT="${2:-.}"

if [ -z "$EPIC_NUMBER" ]; then
  echo "使い方: bash adapters/codex/run-loop.sh <Epic issue番号> [プロジェクトパス]" >&2
  exit 1
fi
EPIC_NUMBER="${EPIC_NUMBER#\#}"

SCHEMA="${PLUGIN_ROOT_DIR}/adapters/codex/schemas/evaluator-verdict.json"
MAX_ATTEMPTS="${DEV_WORKFLOW_MAX_ATTEMPTS:-3}"
MAX_TASKS="${DEV_WORKFLOW_MAX_TASKS:-50}"
DRY_RUN="${DEV_WORKFLOW_DRY_RUN:-0}"
TEST_CMD="${DEV_WORKFLOW_TEST_CMD:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 が見つかりません" >&2; exit 1; }; }
need gh
need git
[ "$DRY_RUN" = "1" ] || need codex
if [ -z "$TEST_CMD" ]; then
  echo "ERROR: 環境変数 DEV_WORKFLOW_TEST_CMD が未設定です。統合ゲートで実行するプロジェクトの全テストコマンドを設定してください（例: DEV_WORKFLOW_TEST_CMD='bash tests/run-tests.sh'）。" >&2
  exit 1
fi

cd "$PROJECT_ROOT" || exit 1

# ── サブエージェント定義の確認（worktree を作る前に落とす）────────────
for role in generator evaluator; do
  if [ ! -f ".codex/agents/${role}.toml" ]; then
    echo "ERROR: .codex/agents/${role}.toml がありません。" >&2
    echo "  bash ${PLUGIN_ROOT_DIR}/adapters/codex/install-agents.sh ." >&2
    exit 1
  fi
done

# ── Epic ブランチと worktree ──────────────────────────────────────────
EPIC_BRANCH="$(gh issue view "$EPIC_NUMBER" --json body -q '.body' \
  | grep -oE 'epic/epic[0-9]+/[^`[:space:]]+' | head -1)"
if [ -z "$EPIC_BRANCH" ]; then
  echo "ERROR: Epic issue #${EPIC_NUMBER} の本文からブランチ名を取得できませんでした" >&2
  exit 1
fi
EPIC_NUM="$(printf '%s' "$EPIC_BRANCH" | grep -oE 'epic[0-9]+' | head -1)"
EPIC_WT=".codex/worktrees/${EPIC_NUM}"

echo "Epic  : #${EPIC_NUMBER}"
echo "Branch: ${EPIC_BRANCH}"
echo "WT    : ${EPIC_WT}"

git fetch origin
if ! git rev-parse --verify "origin/${EPIC_BRANCH}" >/dev/null 2>&1; then
  echo "ERROR: origin/${EPIC_BRANCH} が見つかりません" >&2
  exit 1
fi
git show-ref --verify --quiet "refs/heads/${EPIC_BRANCH}" \
  || git branch "${EPIC_BRANCH}" "origin/${EPIC_BRANCH}"

if [ -d "$EPIC_WT" ]; then
  git -C "$EPIC_WT" checkout "${EPIC_BRANCH}" >/dev/null 2>&1 || true
else
  git worktree add "$EPIC_WT" "${EPIC_BRANCH}" || exit 1
fi

# ── プロジェクト固有の準備コマンド（Epic本文の「## 準備コマンド」節。Epic開始時に1回だけ）──
# 生成物の配置（wasm等）のようなタスクに依らず同じ結果になる準備は、タスクごとに generator へ
# 繰り返させず、ここで1回だけ実行する。節が無ければ何もしない（既存Epicへの影響なし）。
# shellcheck disable=SC2016  # フェンス記号はリテラル一致が目的で、展開させない
PREP_CMD="$(gh issue view "$EPIC_NUMBER" --json body -q '.body' \
  | awk '/^## 準備コマンド/{f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' \
  | sed '1d;$d')"
if [ -n "$PREP_CMD" ]; then
  echo "Epic本文の準備コマンドを実行します:"
  echo "$PREP_CMD"
  bash "${PLUGIN_ROOT_DIR}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --warm "$PREP_CMD" || true
fi

# ── codex exec のラッパー ─────────────────────────────────────────────
# $1: 役割名（.codex/agents/<役割>.toml の name）  $2: プロンプト  $3: 追加引数...
run_agent() {
  local role="$1" prompt="$2"; shift 2
  local model=""
  case "$role" in
    generator) model="${DEV_WORKFLOW_CODEX_GENERATOR_MODEL:-}" ;;
    evaluator) model="${DEV_WORKFLOW_CODEX_EVALUATOR_MODEL:-}" ;;
  esac

  local args=(exec --dangerously-bypass-approvals-and-sandbox -C "$EPIC_WT")
  [ -n "$model" ] && args+=(-m "$model")
  args+=("$@")

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] codex ${args[*]}"
    echo "[dry-run] prompt: $(printf '%s' "$prompt" | head -2)"
    return 0
  fi
  codex "${args[@]}" "$prompt"
}

# ── 機械的ゲート（waveブランチ上で実行する） ───────────────────────────
# 1) プロジェクトの全テスト（sandbox-exec.sh 経由・1コマンドにまとめる）
# 2) 可読性ガード（waveブランチの差分に対して実行。PostToolUseフックと同じ判定）
# の AND で合否を返す。対象の選択を generator に委ねないため、テストコマンドは
# DEV_WORKFLOW_TEST_CMD（TEST_CMD）で固定する。SKIP は「通過」ではなく、テスト
# コマンド自身の終了コードのみで合否を判定する（無言SKIPをここで自動検出はしない。
# generator の報告と合わせて確認すること）。
mechanical_gate() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] mechanical_gate: sandbox-exec.sh --epic ${EPIC_NUM} '${TEST_CMD}' && check-readability.sh --git"
    return 0
  fi
  ( cd "$EPIC_WT" \
      && bash "${PLUGIN_ROOT_DIR}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" "$TEST_CMD" \
      && DEV_WORKFLOW_HOOK_VENDOR=exit-code \
         bash "${PLUGIN_ROOT_DIR}/scripts/check-readability.sh" --git </dev/null )
}

# ── 開始を記録 ───────────────────────────────────────────────────────
bash "${PLUGIN_ROOT_DIR}/scripts/notify-slack.sh" run-start "Epic #${EPIC_NUMBER}" || true

# watchdog を起動する（run マーカーの消失を自己終了条件の1つにしているため、
# 必ずマーカーより後に起動すること）。`--start` 自体は自己デタッチして即座に返る。
bash "${PLUGIN_ROOT_DIR}/scripts/watchdog.sh" --start --epic "$EPIC_NUM" --label "Epic #${EPIC_NUMBER}" || true

# ── タスクループ（依存グラフに基づくウェーブ実行。lanes=1 固定）───────
# 1タスク = 1レーン = 1ウェーブとして扱う。plan-waves.sh を毎回再計算し、
# 常に「次に処理すべきタスク」を先頭から1件だけ取り出す（Codexは並列起動しないため）。
processed=0
skipped=0
SKIPPED_CSV=""
PROPAGATED_CSV=""   # 依存先スキップにより伝播スキップ済みとして既にコメントしたタスク番号（重複コメント防止）

# WAVE_NO: wave ブランチ名（wave/${EPIC_NUM}/${WAVE_NO}）の通し番号。0 から始めてはならない
# （Task #54）。中断→再開でこのスクリプトを再実行すると本変数はプロセスごと失われ 0 から
# 数え直すことになるが、`wave/${EPIC_NUM}/*` ブランチはローカルに残り続ける（origin へ push
# しない設計）。0 から始めると前回の残骸 wave ブランチをそのまま掴んでしまう。既存の
# wave ブランチの番号の最大値から始めることで、再開時も必ず新しい wave ブランチが使われる
# （残骸を掴んだ場合も `merge-lane.sh --create` が tip 不一致を検出し exit 1 で拒否する）。
WAVE_NO=$(git -C "$EPIC_WT" for-each-ref --format='%(refname:short)' "refs/heads/wave/${EPIC_NUM}/*" \
  | sed "s#^wave/${EPIC_NUM}/##" | sort -n | tail -1)
WAVE_NO="${WAVE_NO:-0}"

while [ "$processed" -lt "$MAX_TASKS" ]; do
  PLAN_ARGS=(--epic "$EPIC_NUMBER" --lanes 1)
  [ -n "$SKIPPED_CSV" ] && PLAN_ARGS+=(--skipped "$SKIPPED_CSV")
  PLAN="$(bash "${PLUGIN_ROOT_DIR}/scripts/plan-waves.sh" "${PLAN_ARGS[@]}")"
  PLAN_EXIT=$?

  if [ "$PLAN_EXIT" -eq 3 ]; then
    echo "ERROR: 循環依存を検出しました。停止します。" >&2
    printf '%s\n' "$PLAN" >&2
    gh issue comment "$EPIC_NUMBER" --body "自律実行: 循環依存を検出したため停止しました。$(printf '%s' "$PLAN")" || true
    break
  fi
  if [ "$PLAN_EXIT" -ne 0 ]; then
    echo "ERROR: plan-waves.sh が exit ${PLAN_EXIT} で失敗しました" >&2
    printf '%s\n' "$PLAN" >&2
    break
  fi

  while IFS=$'\t' read -r kind sub num extra dep; do
    if [ "$kind" = "warn" ]; then
      if [ "$sub" = "missing-deps" ]; then
        echo "[警告] 前提未宣言（宣言漏れ・完全逐次にフォールバック）: #${num}"
      elif [ "$sub" = "unknown-dep" ]; then
        echo "[警告] 不明な依存（Epic外・存在しない issue。無視されます）: #${num} -> #${extra}"
      fi
    elif [ "$kind" = "skip" ]; then
      # sub=スキップされたタスク番号 num=reason extra=depends-on-skipped dep=依存先番号
      case ",${PROPAGATED_CSV}," in
        *",${sub},"*) ;;  # 既にコメント済み（毎回のplan-waves.sh再計算で重複するため）
        *)
          echo "[警告] 依存先スキップにより伝播スキップ: #${sub}（依存先 #${dep}）"
          gh issue comment "$sub" --body "自律実行: 依存先 #${dep} がスキップされたため、このタスクは実行せずスキップしました（推移的伝播）。" || true
          PROPAGATED_CSV="${PROPAGATED_CSV:+${PROPAGATED_CSV},}${sub}"
          ;;
      esac
    fi
  done <<< "$PLAN"

  WAVE1_LINE="$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="wave" && $2==1 {print; exit}')"
  if [ -z "$WAVE1_LINE" ]; then
    echo "残タスクなし。タスクループを終了します。"
    break
  fi
  TASKS_CSV="$(printf '%s' "$WAVE1_LINE" | cut -f4)"
  task="${TASKS_CSV%%,*}"

  echo ""
  echo "═══ Task #${task}  (処理済 ${processed} / スキップ ${skipped}) ═══"

  # WAVE_BASE を記録する（このタスク専用の1タスクウェーブの唯一の分岐元）
  git -C "$EPIC_WT" fetch origin
  git -C "$EPIC_WT" checkout "${EPIC_BRANCH}"
  git -C "$EPIC_WT" pull origin "${EPIC_BRANCH}"
  WAVE_BASE="$(git -C "$EPIC_WT" rev-parse HEAD)"
  WAVE_NO=$((WAVE_NO + 1))
  WAVE_BRANCH="wave/${EPIC_NUM}/${WAVE_NO}"
  LANE_BRANCH="task/${EPIC_NUM}/${task}"

  # ウェーブ予算の監視（watchdog）に、このウェーブの内訳を伝える。lanes=1 固定のため
  # 1タスク=1ウェーブとして扱う（generator を起動する前に伝えること）
  bash "${PLUGIN_ROOT_DIR}/scripts/watchdog.sh" --wave --epic "$EPIC_NUM" \
    --wave-no "$WAVE_NO" --tasks "$task" || true

  attempt=1
  passed=0
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    echo "-- 試行 ${attempt}/${MAX_ATTEMPTS}"

    # レーン（作業ブランチ）を WAVE_BASE から作り直す（前回試行の変更を引きずらない）
    git -C "$EPIC_WT" checkout -q "${EPIC_BRANCH}"
    git -C "$EPIC_WT" branch -f "$LANE_BRANCH" "$WAVE_BASE"
    git -C "$EPIC_WT" checkout -q "$LANE_BRANCH"

    run_agent generator "generator として Task #${task} を実装してください。
WAVE_BASE: ${WAVE_BASE}（ブランチ名ではなくこのハッシュそのものに対して検証すること）
作業開始前に \`git merge-base --is-ancestor ${WAVE_BASE} HEAD\` でベースを検証すること。偽なら実装を始めず、実出力を添えて報告し停止すること。
\`git fetch\` / \`git checkout\` / \`git pull\` は実行しないこと（同期は済んでいる。作業ブランチ ${LANE_BRANCH} は WAVE_BASE から分岐している）。
作業ディレクトリから移動しないこと。
issueの要件を確認すること。Task issueの記載だけで着手できない場合に限り、親Epic issue #${EPIC_NUMBER} 本文の仕様書・計画書を確認すること。
テストファーストで実装し、全テストが通ることを確認してから、変更を ${LANE_BRANCH} にコミットすること。"

    # レーンを wave ブランチへ取り込む（WAVE_BASE から作り直し、cherry-pick 載せ替えはしない）
    git -C "$EPIC_WT" checkout -q "${EPIC_BRANCH}"
    git -C "$EPIC_WT" branch -f "$WAVE_BRANCH" "$WAVE_BASE"
    MERGE_OUT="$(cd "$EPIC_WT" && bash "${PLUGIN_ROOT_DIR}/scripts/merge-lane.sh" \
      --wave-branch "$WAVE_BRANCH" --expected-base "$WAVE_BASE" \
      --lane-branch "$LANE_BRANCH" --task "$task")"
    MERGE_EXIT=$?
    echo "$MERGE_OUT"

    if [ "$MERGE_EXIT" -eq 0 ]; then
      if ( cd "$EPIC_WT" && git checkout -q "$WAVE_BRANCH" ) && mechanical_gate; then
        ( cd "$EPIC_WT" \
          && git checkout -q "${EPIC_BRANCH}" \
          && git merge --ff-only "$WAVE_BRANCH" \
          && git push origin "${EPIC_BRANCH}" )
        passed=1
        break
      fi
      echo "-- 統合ゲート不合格。差し戻します。"
    elif [ "$MERGE_EXIT" -eq 10 ]; then
      echo "-- ベース逸脱を検出しました（merge-lane.sh exit 10）。取り込まず差し戻します。"
      gh issue comment "$task" --body "自律実行: ベース逸脱を検出しました（merge-lane.sh exit 10）。$(printf '%s' "$MERGE_OUT")" || true
    elif [ "$MERGE_EXIT" -eq 11 ]; then
      echo "-- マージ競合を検出しました（merge-lane.sh exit 11）。取り込まず差し戻します。"
      gh issue comment "$task" --body "自律実行: マージ競合を検出しました（merge-lane.sh exit 11）。$(printf '%s' "$MERGE_OUT")" || true
    else
      echo "-- merge-lane.sh が想定外の exit ${MERGE_EXIT} で終了しました。" >&2
    fi

    attempt=$((attempt + 1))
  done

  if [ "$passed" -eq 1 ]; then
    gh issue close "$task" || true
  else
    gh issue comment "$task" --body "自律実行: 機械的ゲートに ${MAX_ATTEMPTS} 回失敗したためスキップしました。手動での確認が必要です。" || true
    SKIPPED_CSV="${SKIPPED_CSV:+${SKIPPED_CSV},}${task}"
    skipped=$((skipped + 1))
  fi

  processed=$((processed + 1))
done

if [ "$processed" -ge "$MAX_TASKS" ]; then
  echo "警告: タスク処理上限 ${MAX_TASKS} 件に達したため打ち切りました（未処理タスクが残っています）。" >&2
fi

# ── Epic一括レビュー ─────────────────────────────────────────────────
echo ""
echo "═══ Epic一括レビュー ═══"
VERDICT_FILE="$(mktemp)"
run_agent evaluator "evaluator として Epic #${EPIC_NUMBER} の全変更をレビューしてください。
モード: epic-review
差分範囲: main...${EPIC_BRANCH}
親Epic issueの仕様書と照合し、実装漏れも指摘すること。
判定と指摘をスキーマどおりのJSONで返すこと。" \
  --output-schema "$SCHEMA" -o "$VERDICT_FILE"

if [ "$DRY_RUN" != "1" ] && [ -s "$VERDICT_FILE" ]; then
  echo "--- 判定 ---"
  cat "$VERDICT_FILE"
  echo ""
  echo "high/medium の指摘は review ラベル付き issue にし、generator に対応させてください。"
  echo "対応後の delta-review まで含めてレビューは最大2巡で打ち切ります。"
  echo "判定JSON: ${VERDICT_FILE}"
else
  echo "判定JSONを取得できませんでした（dry-run か、evaluator が出力しなかった）: ${VERDICT_FILE}"
fi

echo ""
echo "次の手順: 指摘対応 → delta-review → PR作成。"
echo "PR作成まで終えたら完了通知を出してください:"
echo "  bash \"${PLUGIN_ROOT_DIR}/scripts/notify-slack.sh\" run-complete \"全${processed}タスク完了（スキップ${skipped}件）"
echo "PR: <PRのURL>\""
