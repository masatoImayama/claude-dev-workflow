#!/bin/bash
# dev-workflow: Codex サブエージェント定義をプロジェクトに設置する
#
# Codex のプラグインマニフェストはサブエージェント（agents）を配布できないため、
# プラグイン同梱の codex-agents/*.toml をプロジェクトの .codex/agents/ にコピーする。
#
# 使い方:
#   bash adapters/codex/install-agents.sh [プロジェクトパス]
#   bash adapters/codex/install-agents.sh --check [プロジェクトパス]   # 差分の有無だけ確認
#
# モデルの個別指定（任意）:
#   DEV_WORKFLOW_CODEX_PLANNER_MODEL    planner に使うモデル
#   DEV_WORKFLOW_CODEX_GENERATOR_MODEL  generator に使うモデル
#   DEV_WORKFLOW_CODEX_EVALUATOR_MODEL  evaluator に使うモデル
#
# 未指定の場合、モデルは親セッションまたは config.toml の
# [agents] default_subagent_model から継承される。
# 利用可能なモデルは `codex exec --help` の -m や、お使いのプランの提供モデルを参照。
#
# 注意: --check は「同じ環境変数を与えたときの生成結果」と比較する。モデル指定をして
#       設置した場合は、--check も同じ環境変数を与えて実行すること。
#       常用するならシェルの初期化ファイル等で export しておくとよい。

set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift
fi

PROJECT_ROOT="${1:-.}"
PLUGIN_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="${PLUGIN_ROOT_DIR}/codex-agents"
DEST_DIR="${PROJECT_ROOT}/.codex/agents"

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: 生成物が見つかりません: ${SRC_DIR}" >&2
  echo "  先に 'bash adapters/codex/build.sh' を実行してください。" >&2
  exit 1
fi

if [ ! -d "$PROJECT_ROOT" ]; then
  echo "ERROR: プロジェクトディレクトリが見つかりません: ${PROJECT_ROOT}" >&2
  exit 1
fi

# 役割名に対応するモデル指定の環境変数を返す（未設定なら空）
model_override_for() {
  case "$1" in
    planner)   printf '%s' "${DEV_WORKFLOW_CODEX_PLANNER_MODEL:-}" ;;
    generator) printf '%s' "${DEV_WORKFLOW_CODEX_GENERATOR_MODEL:-}" ;;
    evaluator) printf '%s' "${DEV_WORKFLOW_CODEX_EVALUATOR_MODEL:-}" ;;
    *)         printf '' ;;
  esac
}

# コメントアウトされた `# model = "..."` 行を有効な指定に置き換える。
# 指定が無ければそのまま（＝継承）出力する。
apply_model() {
  local role="$1" model
  model="$(model_override_for "$role")"
  if [ -z "$model" ]; then
    cat
    return
  fi
  sed -E "s|^# model = \".*\".*$|model = \"${model}\"|"
}

[ "$CHECK_ONLY" -eq 0 ] && mkdir -p "$DEST_DIR"

changed=0
for src in "${SRC_DIR}"/*.toml; do
  [ -f "$src" ] || continue
  name="$(basename "$src")"
  role="${name%.toml}"
  dest="${DEST_DIR}/${name}"

  built="$(apply_model "$role" < "$src")"

  if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ ! -f "$dest" ]; then
      echo "未設置: .codex/agents/${name}"
      changed=1
    elif ! printf '%s\n' "$built" | diff -q - "$dest" > /dev/null 2>&1; then
      echo "古い: .codex/agents/${name}"
      changed=1
    fi
    continue
  fi

  printf '%s\n' "$built" > "$dest"
  model="$(model_override_for "$role")"
  if [ -n "$model" ]; then
    echo "設置: .codex/agents/${name}  (model = ${model})"
  else
    echo "設置: .codex/agents/${name}"
  fi
done

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$changed" -eq 1 ]; then
    echo "" >&2
    echo ".codex/agents/ が最新ではありません。以下を実行してください:" >&2
    echo "  bash adapters/codex/install-agents.sh ${PROJECT_ROOT}" >&2
    exit 1
  fi
  echo "OK: .codex/agents/ は最新です"
  exit 0
fi

cat <<'NOTE'

次の手順:
  1. .codex/agents/ をコミットする（障害時に生成処理を実行できない可能性があるため）
  2. Codex を起動し、planner / generator / evaluator が認識されることを確認する
  3. プラグイン同梱フックの信頼付与を求められたら承認する（可読性ガードが有効になる）
NOTE
