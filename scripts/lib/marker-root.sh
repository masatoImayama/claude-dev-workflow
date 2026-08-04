#!/bin/bash
# dev-workflow: マーカー置き場（メインリポのルート）解決の共通ライブラリ
#
# run は Epic 専用 worktree（.claude/worktrees/<epicN>）で、generator は
# isolation worktree（.claude/worktrees/agent-*）で動くため、cwd はまちまちである。
# 監視プロセス・フック・通知スクリプトが同じ場所の状態ファイルを見るには、
# どこから呼ばれても「メインリポのルート」に解決できる必要がある。
#
# heartbeat.sh は全ツール呼び出しごとに発火するため、この解決処理は
# 外部プロセスを1つも起動せずに行う必要がある。worktree の .git は
# `gitdir: <メインリポ>/.git/worktrees/<名前>` という1行のテキストファイルなので、
# bash の read だけで解析できる。
#
# 使い方: このファイルを source すると dev_workflow_marker_root() が使えるようになる。
#
#   dev_workflow_marker_root [起点ディレクトリ（省略時は $PWD）]
#
#   標準出力にメインリポのルートの絶対パスを返す。
#   git 管理下でなければ何も出力せず非0で終了する。
#
# 解決順:
#   1. 環境変数 DEV_WORKFLOW_MARKER_ROOT が設定されていればそれを使う（正規化せずそのまま）
#   2. 環境変数 CLAUDE_PROJECT_DIR が設定されていて、その直下に .git があればそれを使う
#   3. 起点から上位へ最大10段さかのぼって .git を探す
#      - .git がディレクトリなら、そこがメインリポのルート
#      - .git がファイルなら1行目 `gitdir: <path>` を読み、
#        `/.git/worktrees/<名前>` の部分を取り除いた残りがメインリポのルート
#
# 制約: この関数の中では git / sed / dirname / basename / コマンド置換のいずれも
# 使わない。bash の組み込み（パラメータ展開・test・read・$OSTYPE）だけで実装する。
# パスの区切りは `/` 前提（Git Bash・macOS・Linux いずれも `/` で来る）。
#
# このファイルは scripts/notify-slack.sh / scripts/heartbeat.sh から source される。
# 単体では何もしない。

set -u

# _dev_workflow_marker_root_normalize <path>
#
# Windows（Git Bash＝MSYS／Cygwin）では、同じ実体のディレクトリでも呼び出し元によって
# 表現が異なる（実機で確認済み）:
#   - bash の $PWD 由来                          … /c/Users/...（MSYS形式）
#   - git が worktree の gitdir ファイルに書く絶対パス … C:/Users/...（ドライブレター形式）
# 素の文字列比較では一致しないため、heartbeat.sh と notify-slack.sh が別々の
# マーカーファイルを見てしまう（旧実装は git rev-parse が内部でこの正規化をしていたため
# 表面化していなかった）。呼び出し元に関わらず同じ文字列になるよう、
# Windows 環境（$OSTYPE が msys*/cygwin*）でだけ `<DRIVE>:/...` 形式へ揃える。
# ドライブレター以外の大小文字は変えない（プロジェクト名表示等の挙動を変えないため）。
# $OSTYPE は bash の組み込み変数なので外部プロセスは起動しない。
_dev_workflow_marker_root_normalize() {
  local path="$1" drive rest

  case "${OSTYPE:-}" in
    msys*|cygwin*) ;;
    *)
      printf '%s' "$path"
      return 0
      ;;
  esac

  case "$path" in
    /[A-Za-z]/*)
      drive="${path:1:1}"
      rest="${path:2}"
      printf '%s:%s' "${drive^^}" "$rest"
      ;;
    /[A-Za-z])
      drive="${path:1:1}"
      printf '%s:' "${drive^^}"
      ;;
    [A-Za-z]:/*|[A-Za-z]:)
      drive="${path:0:1}"
      rest="${path:2}"
      printf '%s:%s' "${drive^^}" "$rest"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

dev_workflow_marker_root() {
  # dev_workflow_marker_root [起点ディレクトリ]
  local start="${1:-$PWD}"

  if [ -n "${DEV_WORKFLOW_MARKER_ROOT:-}" ]; then
    printf '%s' "$DEV_WORKFLOW_MARKER_ROOT"
    return 0
  fi

  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -e "${CLAUDE_PROJECT_DIR}/.git" ]; then
    _dev_workflow_marker_root_normalize "$CLAUDE_PROJECT_DIR"
    return 0
  fi

  local dir="$start" depth=0 parent line gitdir_path

  while [ "$depth" -lt 10 ]; do
    if [ -d "$dir/.git" ]; then
      _dev_workflow_marker_root_normalize "$dir"
      return 0
    fi

    if [ -f "$dir/.git" ]; then
      line=""
      IFS= read -r line < "$dir/.git" || true
      line="${line%$'\r'}"
      case "$line" in
        "gitdir: "*"/.git/worktrees/"*)
          gitdir_path="${line#"gitdir: "}"
          gitdir_path="${gitdir_path%/worktrees/*}"
          gitdir_path="${gitdir_path%/.git}"
          if [ -n "$gitdir_path" ]; then
            _dev_workflow_marker_root_normalize "$gitdir_path"
            return 0
          fi
          ;;
      esac
      return 1
    fi

    [ "$dir" = "/" ] && break

    parent="${dir%/*}"
    [ -z "$parent" ] && parent="/"
    [ "$parent" = "$dir" ] && break

    dir="$parent"
    depth=$((depth + 1))
  done

  return 1
}
