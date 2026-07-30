#!/bin/bash
# dev-workflow: Codex CLI による無人自律ループ
#
# ループをシェル側に置き、1回の `codex exec` = 1役 として起動する。
# これにより役割ごとに文脈が分離される（Codex のサブエージェントには専用 worktree が
# ないため、セッションを分けることが最も強い分離手段になる）。
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
#
# 注意: このスクリプトは `--dangerously-bypass-approvals-and-sandbox` を使う。
#       Codex 側の承認プロンプトを飛ばすため、**信頼できるリポジトリでのみ**使うこと。
#       Codex にはターン数の上限設定がないため、暴走の抑止は
#       このスクリプトの反復回数上限と、各役割のプロンプト規約で担保している。

set -uo pipefail

EPIC_NUMBER="${1:-}"
PROJECT_ROOT="${2:-.}"

if [ -z "$EPIC_NUMBER" ]; then
  echo "使い方: bash adapters/codex/run-loop.sh <Epic issue番号> [プロジェクトパス]" >&2
  exit 1
fi
EPIC_NUMBER="${EPIC_NUMBER#\#}"

PLUGIN_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="${PLUGIN_ROOT_DIR}/adapters/codex/schemas/evaluator-verdict.json"
MAX_ATTEMPTS="${DEV_WORKFLOW_MAX_ATTEMPTS:-3}"
MAX_TASKS="${DEV_WORKFLOW_MAX_TASKS:-50}"
DRY_RUN="${DEV_WORKFLOW_DRY_RUN:-0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 が見つかりません" >&2; exit 1; }; }
need gh
need git
[ "$DRY_RUN" = "1" ] || need codex

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

# ── 機械的ゲート ─────────────────────────────────────────────────────
mechanical_gate() {
  ( cd "$EPIC_WT" && DEV_WORKFLOW_HOOK_VENDOR=exit-code \
      bash "${PLUGIN_ROOT_DIR}/scripts/check-readability.sh" --git </dev/null )
}

# ── 開始を記録 ───────────────────────────────────────────────────────
bash "${PLUGIN_ROOT_DIR}/scripts/notify-slack.sh" run-start "Epic #${EPIC_NUMBER}" || true

# ── タスクループ ─────────────────────────────────────────────────────
processed=0
skipped=0

while [ "$processed" -lt "$MAX_TASKS" ]; do
  task="$(gh issue list --label task --state open --json number -q '.[0].number' 2>/dev/null)"
  [ -z "$task" ] || [ "$task" = "null" ] && break

  echo ""
  echo "═══ Task #${task}  (処理済 ${processed} / スキップ ${skipped}) ═══"

  git -C "$EPIC_WT" fetch origin
  git -C "$EPIC_WT" pull origin "${EPIC_BRANCH}" || true

  attempt=1
  passed=0
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    echo "-- generator 試行 ${attempt}/${MAX_ATTEMPTS}"
    run_agent generator "generator として Task #${task} を実装してください。
Epicブランチ: ${EPIC_BRANCH}（作業開始前に必ず最新を同期すること）
作業ディレクトリから移動しないこと。
issueの要件と、親Epic issue #${EPIC_NUMBER} 本文の仕様書・計画書を確認すること。
テストファーストで実装し、全テストが通ることを確認してから、変更をコミットすること。"

    if mechanical_gate; then
      passed=1
      break
    fi
    echo "-- 機械的ゲート不合格。差し戻します。"
    attempt=$((attempt + 1))
  done

  if [ "$passed" -eq 1 ]; then
    git -C "$EPIC_WT" push origin "${EPIC_BRANCH}" || true
    gh issue close "$task" || true
  else
    gh issue comment "$task" --body "自律実行: 機械的ゲートに ${MAX_ATTEMPTS} 回失敗したためスキップしました。手動での確認が必要です。" || true
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
