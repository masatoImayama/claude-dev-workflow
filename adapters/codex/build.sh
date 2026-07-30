#!/bin/bash
# dev-workflow: Codex CLI 向けエージェント定義のビルド
#
# core/ のベンダー中立な正本と adapters/codex/overlays/ の Codex 固有オーバーレイを
# 結合して codex-agents/*.toml を生成する。
#
# 生成物はプロジェクトの .codex/agents/ にコピーして使う（サブエージェント定義は
# プラグインで配布できないため）。設置は install-agents.sh が行う。
#
# 使い方:
#   bash adapters/codex/build.sh          # 生成する
#   bash adapters/codex/build.sh --check  # 生成物が最新かを検証する（差分があれば exit 1）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY_DIR="${REPO_ROOT}/adapters/codex/overlays"
OUT_DIR="${REPO_ROOT}/codex-agents"

source "${REPO_ROOT}/adapters/lib/expand-includes.sh"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
fi

if [ ! -d "$OVERLAY_DIR" ]; then
  echo "ERROR: オーバーレイディレクトリが見つかりません: ${OVERLAY_DIR}" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

stale=0
generated=0

for overlay in "${OVERLAY_DIR}"/*.toml; do
  [ -f "$overlay" ] || continue
  name="$(basename "$overlay")"

  built="$(expand_includes "$REPO_ROOT" "$overlay")"

  # TOML のリテラル複数行文字列（'''）を終端させてしまう内容が core/ に混ざると
  # 壊れた TOML を配ってしまうため、生成時に検出して止める。
  if printf '%s' "$built" | grep -q "^'''" ; then
    # 最初と最後（developer_instructions の開始・終了）以外に ''' があるか数える
    count="$(printf '%s\n' "$built" | grep -c "'''" || true)"
    if [ "$count" -ne 2 ]; then
      echo "ERROR: ${name} の生成結果に ''' が ${count} 個あります（2個であるべき）。" >&2
      echo "  core/ 側の内容に ''' が含まれていると TOML が壊れます。" >&2
      exit 1
    fi
  fi

  if emit_or_check "$built" "${OUT_DIR}/${name}" "codex-agents/${name}" "$CHECK_ONLY"; then
    [ "$CHECK_ONLY" -eq 0 ] && generated=$((generated + 1))
  else
    stale=1
  fi
done

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$stale" -eq 1 ]; then
    echo "" >&2
    echo "codex-agents/ の生成物が古くなっています。以下を実行して再生成し、コミットに含めてください:" >&2
    echo "  bash adapters/codex/build.sh" >&2
    exit 1
  fi
  echo "OK: codex-agents/ は core/ と一致しています"
  exit 0
fi

echo "完了: ${generated} 件のエージェント定義を生成しました"
