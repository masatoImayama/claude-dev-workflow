#!/bin/bash
# dev-workflow: オーバーレイの include 展開（アダプタ共通）
#
# `<!-- include: <リポジトリルートからの相対パス> -->` だけの行を、そのファイルの
# 内容で置き換える。include の入れ子は行わない（1段のみ）。
#
# このファイルは source して使う:
#   source "adapters/lib/expand-includes.sh"
#   expand_includes "$REPO_ROOT" "$overlay_file"

# $1: リポジトリルート  $2: オーバーレイファイル
expand_includes() {
  local repo_root="$1"
  local overlay_file="$2"
  local line include_path

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '<!-- include: '*' -->')
        include_path="${line#<!-- include: }"
        include_path="${include_path% -->}"
        if [ ! -f "${repo_root}/${include_path}" ]; then
          echo "ERROR: include 対象が見つかりません: ${include_path}" >&2
          echo "  参照元: ${overlay_file}" >&2
          return 1
        fi
        cat "${repo_root}/${include_path}"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done < "$overlay_file"
}

# 生成物を書き出すか、--check なら既存物との一致だけを検証する。
# $1: 生成内容  $2: 出力先パス  $3: 表示名  $4: 1ならcheckのみ
# 戻り値: check時に不一致なら 1
emit_or_check() {
  local built="$1" out="$2" label="$3" check_only="$4"

  if [ "$check_only" -eq 1 ]; then
    if [ ! -f "$out" ]; then
      echo "STALE: ${label} が生成されていません"
      return 1
    fi
    if ! printf '%s\n' "$built" | diff -q - "$out" > /dev/null 2>&1; then
      echo "STALE: ${label} が core/ の内容と一致しません"
      return 1
    fi
    return 0
  fi

  printf '%s\n' "$built" > "$out"
  echo "generated: ${label}"
}
