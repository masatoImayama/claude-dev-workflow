#!/bin/bash
# dev-workflow plugin: 可読性ガード
#
# 「ソースを読めば何をしているのか分かる」を守るための決定論的チェック。
# AIによる自律開発で「人間の可読性を犠牲にした効率化」（コンテンツの
# base64+gzip化、ミニファイ/難読化されたソースのコミット等）が混入するのを
# 物理的に阻止する。
#
# 検出した場合は exit 2 + stderr を返す:
#   - PostToolUse(Write|Edit) フック → そのツール結果をブロックし、理由をエージェントに差し戻す（自己修正ループ）
#   - Stop フック → セッション終了をブロックし、修正を促す
#
# 使い方:
#   check-readability.sh                # stdin の hook JSON から file_path を抽出して検査
#   check-readability.sh --git          # git の変更ファイル全体を検査（Stop フック用）
#   check-readability.sh FILE [FILE...]  # 指定ファイルを検査（手動/CI用）
#
# 無効化・調整（環境変数）:
#   READABILITY_GUARD=off               # ガード全体を無効化
#   READABILITY_MAX_BASE64=2000         # 連続するbase64文字列の許容上限（文字数）
#   READABILITY_MAX_LINE=5000           # ソース1行の許容上限（文字数。ミニファイ検出）
#
# エスケープハッチ:
#   正当な理由で巨大なエンコード済みデータが必要な場合、そのファイル内に
#   コメントとして `readability-guard:allow <理由>` を残すと当該ファイルを除外する。
#   （人間可読な正当化をソースに残させることで、抑止の理念と整合させる）

set -u

# ガード無効化
if [ "${READABILITY_GUARD:-on}" = "off" ]; then
  exit 0
fi

MAX_BASE64="${READABILITY_MAX_BASE64:-2000}"
MAX_LINE="${READABILITY_MAX_LINE:-5000}"

# ── 許可リスト（このパターンに一致するパスは検査をスキップ）────────────
# 生成物・ロックファイル・テストフィクスチャ・ベンダリングされた依存など、
# 「人間可読でないことが正当」かつ「ソースの正本ではない」ものを除外する。
is_allowlisted() {
  case "$1" in
    *.lock|*-lock.json|*-lock.yaml|*.lockb) return 0 ;;
    */__snapshots__/*|*.snap) return 0 ;;
    */fixtures/*|*/__fixtures__/*|*/testdata/*|*/test-data/*) return 0 ;;
    */node_modules/*|*/vendor/*|*/third_party/*|*/third-party/*) return 0 ;;
    *.min.js|*.min.css|*.min.mjs) return 0 ;;
    *.svg|*.ico|*.woff|*.woff2|*.ttf|*.eot) return 0 ;;
    *.generated.*|*.gen.go|*.pb.go|*_pb2.py|*.g.dart|*.freezed.dart) return 0 ;;
    *.map) return 0 ;;
  esac
  return 1
}

# ── 1ファイルを検査。違反メッセージを stdout に出力、違反があれば return 1 ──
check_one() {
  local file="$1"

  # 実在する通常ファイルのみ
  [ -f "$file" ] || return 0
  # バイナリはスキップ（-I はバイナリにマッチしない）
  grep -Iq . "$file" 2>/dev/null || return 0
  # gitで無視されているもの（=ビルド出力等、ソース正本でない）はスキップ
  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    git check-ignore -q "$file" 2>/dev/null && return 0
  fi
  # 許可リスト
  is_allowlisted "$file" && return 0
  # エスケープハッチ（人間が理由付きで許可）
  if grep -q "readability-guard:allow" "$file" 2>/dev/null; then
    return 0
  fi

  local violations=""

  # Rule A: 巨大なbase64ブロブ（空白を挟まない連続したbase64文字列）
  #   base64+gzipされたコンテンツやデータURIの埋め込みを検出する。
  local b64
  b64=$(grep -oE '[A-Za-z0-9+/]{'"$MAX_BASE64"',}={0,2}' "$file" 2>/dev/null | head -1)
  if [ -n "$b64" ]; then
    violations="${violations}  - 巨大なbase64ブロブ（${#b64}文字以上の連続文字列）を検出。コンテンツやデータをエンコードしてソースに埋め込むと、ソースを読んでも中身が分からなくなる。\n"
  fi

  # Rule B: ミニファイ/難読化（極端に長い1行）
  local maxlen
  maxlen=$(awk '{ if (length > m) m = length } END { print m+0 }' "$file" 2>/dev/null)
  if [ "${maxlen:-0}" -ge "$MAX_LINE" ]; then
    violations="${violations}  - 極端に長い行（${maxlen}文字）を検出。ミニファイ/難読化されたコードをソースとしてコミットしている可能性がある。\n"
  fi

  if [ -n "$violations" ]; then
    printf '【可読性ガード】 %s\n%b' "$file" "$violations"
    return 1
  fi
  return 0
}

# ── 検査対象ファイルの決定 ───────────────────────────────────────────
files=()

if [ "${1:-}" = "--git" ]; then
  # git の変更ファイル（追跡済みの変更 + 未追跡）
  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(git diff --name-only HEAD 2>/dev/null)
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(git ls-files --others --exclude-standard 2>/dev/null)
  fi
elif [ "$#" -gt 0 ]; then
  # 引数で指定されたファイル
  files=("$@")
else
  # stdin の hook JSON から file_path を抽出（PostToolUse 用）
  input="$(cat 2>/dev/null || true)"
  raw=$(printf '%s' "$input" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  if [ -n "$raw" ]; then
    # JSONエスケープ解除（\\ → \）と Windows パスの正規化（\ → /）
    raw=$(printf '%s' "$raw" | sed -e 's/\\\\/\\/g' -e 's/\\/\//g')
    files+=("$raw")
  fi
fi

[ "${#files[@]}" -eq 0 ] && exit 0

# ── 検査実行 ─────────────────────────────────────────────────────────
report=""
violated=0
for f in "${files[@]}"; do
  out=$(check_one "$f")
  if [ $? -ne 0 ]; then
    report="${report}${out}\n"
    violated=1
  fi
done

if [ "$violated" -eq 1 ]; then
  {
    echo "可読性ガードが違反を検出しました。「ソースを読めば何をしているのか分かる」状態を壊す変更はブロックされます。"
    echo ""
    printf '%b' "$report"
    echo "対応方針:"
    echo "  1. エンコード/圧縮/ミニファイした成果物を「ソースの正本」としてコミットしない。"
    echo "  2. 元の人間可読なソースを必ずバージョン管理に残し、エンコード/ビルドは実行時・ビルド時に行う。"
    echo "  3. どうしても必要な場合のみ、ファイル内に 'readability-guard:allow <理由>' を明記して理由を残す。"
  } >&2
  exit 2
fi

exit 0
