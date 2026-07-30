#!/bin/bash
# dev-workflow: Claude Code 向けエージェント定義のビルド
#
# core/ のベンダー中立な正本と adapters/claude/overlays/ の Claude 固有オーバーレイを
# 結合して agents/*.md を生成する。
#
# 使い方:
#   bash adapters/claude/build.sh          # 生成する
#   bash adapters/claude/build.sh --check  # 生成物が最新かを検証する（CI・開発時用）
#
# --check は差分があれば exit 1 を返す。ファイルは書き換えない。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY_DIR="${REPO_ROOT}/adapters/claude/overlays"
OUT_DIR="${REPO_ROOT}/agents"

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

for overlay in "${OVERLAY_DIR}"/*.md; do
  [ -f "$overlay" ] || continue
  name="$(basename "$overlay")"

  built="$(expand_includes "$REPO_ROOT" "$overlay")"

  if emit_or_check "$built" "${OUT_DIR}/${name}" "agents/${name}" "$CHECK_ONLY"; then
    [ "$CHECK_ONLY" -eq 0 ] && generated=$((generated + 1))
  else
    stale=1
  fi
done

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$stale" -eq 1 ]; then
    echo "" >&2
    echo "agents/ の生成物が古くなっています。以下を実行して再生成し、コミットに含めてください:" >&2
    echo "  bash adapters/claude/build.sh" >&2
    exit 1
  fi
  echo "OK: agents/ は core/ と一致しています"
  exit 0
fi

echo "完了: ${generated} 件のエージェント定義を生成しました"
