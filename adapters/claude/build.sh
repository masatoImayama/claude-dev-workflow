#!/bin/bash
# dev-workflow: Claude Code 向けエージェント定義のビルド
#
# core/ のベンダー中立な正本と adapters/claude/overlays/ の Claude 固有オーバーレイを
# 結合して agents/*.md を生成する。
#
# 使い方:
#   bash adapters/claude/build.sh          # 生成する
#   bash adapters/claude/build.sh --check  # 生成物が最新かを検証する（CI・フック用）
#
# --check は差分があれば exit 1 を返す。ファイルは書き換えない。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY_DIR="${REPO_ROOT}/adapters/claude/overlays"
OUT_DIR="${REPO_ROOT}/agents"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
fi

# オーバーレイ中の `<!-- include: <パス> -->` 行を、そのファイルの内容で置き換える。
# パスはリポジトリルートからの相対パス。include の入れ子は行わない（1段のみ）。
expand_includes() {
  local overlay_file="$1"
  local line include_path

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '<!-- include: '*' -->')
        include_path="${line#<!-- include: }"
        include_path="${include_path% -->}"
        if [ ! -f "${REPO_ROOT}/${include_path}" ]; then
          echo "ERROR: include 対象が見つかりません: ${include_path}" >&2
          echo "  参照元: ${overlay_file}" >&2
          return 1
        fi
        cat "${REPO_ROOT}/${include_path}"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done < "$overlay_file"
}

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
  out="${OUT_DIR}/${name}"

  built="$(expand_includes "$overlay")"

  if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ ! -f "$out" ]; then
      echo "STALE: ${name} が生成されていません"
      stale=1
    elif ! printf '%s\n' "$built" | diff -q - "$out" > /dev/null 2>&1; then
      echo "STALE: agents/${name} が core/ の内容と一致しません"
      stale=1
    fi
  else
    printf '%s\n' "$built" > "$out"
    echo "generated: agents/${name}"
    generated=$((generated + 1))
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
