#!/bin/bash
# dev-workflow: compose ファイルの衝突要因検出（Docker 非依存の純粋関数）
#
# compose モードは `-p <PROJECT>` でプロジェクト名を分離するが、プロジェクト側の
# compose ファイルが `container_name:` や固定ホストポート（`- "NNNN:NNNN"`）を
# 書いていると、`-p` では解決できない衝突を起こす（Epic #3 仕様書 4.8）。
#
# ここではファイル内容の走査だけで判定できる部分を、docker を一切起動しない
# 純粋関数として切り出し、tests/run-tests.sh から直接検証できるようにする。
#
# このファイルは sandbox-exec.sh から source される。単体では何もしない。

set -u

compose_conflict_warnings() {
  # compose_conflict_warnings <compose_file>
  # 標準出力に、検出した警告メッセージを1行1件で出す（無ければ何も出力しない）。
  # 停止はしない（呼び出し側が stderr に warning として流す）。
  local file="$1"

  [ -f "$file" ] || return 0

  if grep -Eq '^[[:space:]]*container_name[[:space:]]*:' "$file"; then
    printf '%s\n' "compose ファイル (${file}) に container_name が設定されています。-p では解決できない衝突であり、epic の並行実行ができません。"
  fi

  # 固定ホストポート（`- "NNNN:NNNN"` 形式。IPプレフィックス付きも対象）。
  # コンテナ側ポートのみの `- "3000"` や範囲指定のみの `- "3000-3010"`（コロン無し）は対象外。
  if grep -Eq '^[[:space:]]*-[[:space:]]*"?([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:)?[0-9]+:[0-9]+"?[[:space:]]*(#.*)?$' "$file"; then
    printf '%s\n' "compose ファイル (${file}) に固定ホストポートが設定されています。-p では解決できない衝突であり、epic の並行実行ができません。"
  fi
}
