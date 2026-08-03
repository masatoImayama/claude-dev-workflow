#!/bin/bash
# dev-workflow plugin: 可読性ガード
#
# 「ソースを読めば何をしているのか分かる」を守るための決定論的チェック。
# AIによる自律開発で「人間の可読性を犠牲にした効率化」（コンテンツの
# base64+gzip化、ミニファイ/難読化されたソースのコミット等）が混入するのを
# 物理的に阻止する。
#
# 違反の通知方法はCLIごとに契約が異なるため、実行中のCLIを判定して出し分ける:
#   - Claude Code … exit 2 + stderr にメッセージ
#   - Codex CLI  … exit 0 + stdout に {"continue": false, ...} のJSON
#   - pre-commit … exit 1 + stderr にメッセージ（DEV_WORKFLOW_HOOK_VENDOR=exit-code で明示）
#
# どちらも
#   - PostToolUse(Write|Edit) フック → ツール結果をブロックし、理由をエージェントに差し戻す（自己修正ループ）
#   - Stop フック → セッション終了をブロックし、修正を促す
#
# 使い方:
#   check-readability.sh                # stdin の hook JSON から file_path を抽出して検査
#   check-readability.sh --git          # git の変更ファイル全体を検査（Stop フック用）
#   check-readability.sh --staged       # ステージ済みの変更のみ検査（pre-commit フック用）
#   check-readability.sh FILE [FILE...]  # 指定ファイルを検査（手動/CI用）
#
# 無効化・調整（環境変数）:
#   READABILITY_GUARD=off               # ガード全体を無効化
#   READABILITY_MAX_BASE64=2000         # 連続するbase64文字列の許容上限（文字数）
#   READABILITY_MAX_LINE=5000           # ソース1行の許容上限（文字数。ミニファイ検出）
#   READABILITY_STDIN_TIMEOUT=5         # 引数なし・非tty時にstdinを待つ上限秒数。
#                                       # 超過すると警告を出してexit 0（素通り）
#   DEV_WORKFLOW_HOOK_VENDOR=claude|codex|exit-code
#                                       # ベンダー自動判定を上書きする（デバッグ・CI用）
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

# ── フック入力の読み取り ─────────────────────────────────────────────
# フック実行時（引数なし）は stdin に JSON が渡る。端末から手で叩いた場合は stdin
# が tty になるため読まない（読むとブロックしてしまう）。
# `--git` / `--staged` / ファイル引数が1つでもある場合は検査対象が明確なので、
# stdin は一切読まない（パイプ越し・CI・エージェントランナーからの呼び出しで
# EOFが来ずハングする経路を作らないため）。
HOOK_INPUT=""

# 引数なし・非tty のときだけ、上限付きで stdin を「全部」読む。
# フック入力は整形された（複数行の）JSONで来ることがあり、1行しか読まないと
# 1行目に file_path が無い場合に検査対象を取りこぼして黙って素通りしてしまう
# （可読性ガードが最優先で守るべきルールを、入力形式の差で無効化してはならない）。
#
# 以前は `timeout "$secs" cat` に読み取りを丸ごと委譲していたが、`timeout` は
# GNU coreutils / BusyBox のコマンドで macOS の既定環境には存在しない
# （`gtimeout` のみ）。command not found（status 127）を「入力が来なかった」と
# 誤判定し、macOS では可読性ガードが常時無効化されてしまっていた。
# 外部コマンドに依存せず、bash 組み込みの `read -t` だけで複数行を読み切る。
#
# 注意: `while read -t ...; do ...; done` の直後の `$?` はループの終了ステータスに
# なり、POSIX仕様上「ループ本体が一度も実行されなければ0」になる。つまり読み取り
# 自体がタイムアウトで失敗しても、その失敗ステータスはループの外に伝播しない。
# そのため read の戻り値はループ内で都度チェックし、専用フラグに記録する。
#   - status > 128: シグナルによる強制終了＝タイムアウト（bashは128+シグナル番号を返す）
#   - status != 0 かつ <= 128: EOF。ただし改行で終端されていない最終行が
#     `line` に残ったままループを抜けることがあるため、ループ後に明示的に追加する
#     （末尾に改行の無い入力でも最終行を取りこぼさない）。
read_stdin_with_timeout() {
  local timeout_secs="${READABILITY_STDIN_TIMEOUT:-5}"
  local line="" content="" rc timed_out=0
  while :; do
    IFS= read -r -t "$timeout_secs" line
    rc=$?
    if [ "$rc" -gt 128 ]; then
      timed_out=1
      break
    elif [ "$rc" -ne 0 ]; then
      break
    fi
    content+="${line}"$'\n'
  done
  if [ "$timed_out" -eq 1 ]; then
    return 1
  fi
  [ -n "$line" ] && content+="$line"
  printf '%s' "$content"
  return 0
}

# ── 実行中のCLIを判定 ────────────────────────────────────────────────
# Claude Code と Codex CLI はフックのブロック契約が異なるため、出力を出し分ける。
#   1. DEV_WORKFLOW_HOOK_VENDOR が明示されていればそれに従う
#   2. Codex はプラグインフックに PLUGIN_ROOT を設定する（Claude Code は
#      CLAUDE_PLUGIN_ROOT のみを設定し、PLUGIN_ROOT は設定しない）
#   3. 保険として、入力JSONに Codex 固有拡張の turn_id があれば Codex と判定する
detect_hook_vendor() {
  if [ -n "${DEV_WORKFLOW_HOOK_VENDOR:-}" ]; then
    printf '%s' "$DEV_WORKFLOW_HOOK_VENDOR"
    return
  fi
  if [ -n "${PLUGIN_ROOT:-}" ]; then
    printf 'codex'
    return
  fi
  case "$HOOK_INPUT" in
    *'"turn_id"'*) printf 'codex'; return ;;
  esac
  printf 'claude'
}

# 文字列をJSON文字列リテラルに変換する（jq非依存）
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

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
elif [ "${1:-}" = "--staged" ]; then
  # ステージ済みの変更のみ（pre-commit フック用）
  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done \
      < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
  fi
elif [ "$#" -gt 0 ]; then
  # 引数で指定されたファイル
  files=("$@")
else
  # 引数なし: フック入力のJSONから file_path を抽出（PostToolUse 用）。
  # stdin が tty でなければ、上限付きで読む（既定5秒、READABILITY_STDIN_TIMEOUT で調整可）。
  # タイムアウトした場合は「フック入力が来ないなら検査対象も無い」として素通りする。
  if [ ! -t 0 ]; then
    if ! HOOK_INPUT="$(read_stdin_with_timeout)"; then
      echo "【可読性ガード】 stdin からの入力が ${READABILITY_STDIN_TIMEOUT:-5}秒 以内に得られなかったため検査をスキップします" >&2
      exit 0
    fi
  fi
  raw=$(printf '%s' "$HOOK_INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
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
  if ! out=$(check_one "$f"); then
    report="${report}${out}\n"
    violated=1
  fi
done

[ "$violated" -eq 0 ] && exit 0

# ── 違反メッセージの組み立て ─────────────────────────────────────────
message=$(
  echo "可読性ガードが違反を検出しました。「ソースを読めば何をしているのか分かる」状態を壊す変更はブロックされます。"
  echo ""
  printf '%b' "$report"
  echo "対応方針:"
  echo "  1. エンコード/圧縮/ミニファイした成果物を「ソースの正本」としてコミットしない。"
  echo "  2. 元の人間可読なソースを必ずバージョン管理に残し、エンコード/ビルドは実行時・ビルド時に行う。"
  echo "  3. どうしても必要な場合のみ、ファイル内に 'readability-guard:allow <理由>' を明記して理由を残す。"
)

# ── CLIごとの契約で通知する ──────────────────────────────────────────
case "$(detect_hook_vendor)" in
  codex)
    # Codex は stdout のJSONでブロックする。非0終了は「フックの失敗」として
    # 扱われ、JSONが読まれないため exit 0 で返す。
    printf '{"continue":false,"stopReason":%s,"systemMessage":%s}\n' \
      "$(json_string '可読性ガードが違反を検出しました')" \
      "$(json_string "$message")"
    exit 0
    ;;
  exit-code)
    # pre-commit などの素のgitフック用。慣例どおり exit 1 で失敗させる。
    printf '%s\n' "$message" >&2
    exit 1
    ;;
  *)
    # Claude Code。exit 2 + stderr でツール結果をブロックし、理由を差し戻す。
    printf '%s\n' "$message" >&2
    exit 2
    ;;
esac
