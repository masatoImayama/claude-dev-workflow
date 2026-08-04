#!/bin/bash
# dev-workflow: フックから生存信号（heartbeat）を記録する
#
# run のメインループはサブエージェントの完了までブロックされるため、
# run 自身が自分を監視することはできない（`skills/run/SKILL.md` が明記しているとおり、
# サブエージェントはバッチ全員が終わるまで結果を返さない）。一方 PreToolUse / PostToolUse
# フックは**サブエージェント内のツール呼び出しでも発火する**ため、これを生存信号として使う。
#
# フックは全ツール呼び出しごとに走るため、オーバーヘッドを限りなく0に近づける必要がある。
# このスクリプトは外部プロセスを1つも起動しない。唯一の例外は、状態ファイルを壊さず
# 原子的に置き換えるための `mv` である。
#
# 使い方:
#   bash scripts/heartbeat.sh pre     # PreToolUse フックから
#   bash scripts/heartbeat.sh post    # PostToolUse フックから
#
# 記録内容:
#   <マーカールート>/.claude/.dev-workflow-heartbeat に1行だけ書く（追記ではなく置き換え）
#     <epoch秒>\t<pre|post>\t<ツール名>
#
#   マーカールート（メインリポのルート）の解決は scripts/lib/marker-root.sh（#43）に委譲する。
#
#   state の意味（Epic #42 仕様書「4.1 無活動（ストール）」）:
#     pre  … ツール実行中に停止している（例: サンドボックスのテストが返らない）
#     post … モデルの応答待ちで停止している（API スロットリングの疑い。今回の実測事例）
#   watchdog（#45〜#47）はこの区別と最終更新時刻から、「どちらで止まっているか」
#   （受け入れ条件2）と、無活動・スリープ復帰（受け入れ条件3）を判定する。
#
# 非機能要件（Epic #42 仕様書「7. 非機能要件」）:
#   - どんな異常があっても必ず exit 0 で終わる（生存信号の記録が run を止めてはならない。
#     マーカールートが解決できない・.claude が無い・stdin が空・JSON が壊れている、
#     いずれも黙って通す）
#   - 外部プロセスを1つも起動しない（date / jq / sed / grep は使わない。mv のみ例外）
#   - stdin が tty のときは読まない（手で叩いたときにブロックしないため）
#
# 並行書き込みへの対応:
#   一時ファイル（PID と $RANDOM で一意化）へ書いてから mv で置き換える。
#   複数レーンから同時に呼ばれても、常にどれか1プロセス分の「正しい1行」になり、
#   行の混在・破損は起きない（mv は同一ボリューム内で原子的なリネーム）。

set -u

MODE="${1:-}"
case "$MODE" in
  pre|post) ;;
  *) exit 0 ;;
esac

# 自分の場所からライブラリを解決する（dirname は使わない。純粋なパラメータ展開）
HEARTBEAT_SELF="${BASH_SOURCE[0]:-$0}"
HEARTBEAT_DIR="${HEARTBEAT_SELF%/*}"
[ "$HEARTBEAT_DIR" = "$HEARTBEAT_SELF" ] && HEARTBEAT_DIR="."

# shellcheck source=./lib/marker-root.sh
. "${HEARTBEAT_DIR}/lib/marker-root.sh" 2>/dev/null || exit 0

MARKER_ROOT="$(dev_workflow_marker_root 2>/dev/null)" || exit 0
[ -n "$MARKER_ROOT" ] || exit 0

CLAUDE_DIR="${MARKER_ROOT}/.claude"
[ -d "$CLAUDE_DIR" ] || exit 0

TARGET="${CLAUDE_DIR}/.dev-workflow-heartbeat"

# ── フック入力の読み取り ─────────────────────────────────────────────
# stdin が tty なら読まない（手で叩いたときにブロックしないため）。
# フック入力は整形された複数行JSONで来ることがあるため、NUL区切りで一括に読み切る
# （通常のJSONにNULバイトは含まれないため、これでstdin全体を1つの文字列として読める）。
# -t はデータが来ない異常系（パイプが閉じない等）でも必ず終わらせるための保険。
INPUT=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' -t 1 INPUT 2>/dev/null || true
fi

# ── ツール名の抽出（jq / sed は使わない。bashのパターンマッチだけで取り出す） ──
# 取り出せなければ "-" とする（壊れたJSON・想定外の入力でも exit 0 で記録は続ける）。
TOOL="-"
case "$INPUT" in
  *'"tool_name"'*)
    _hb_rest="${INPUT#*\"tool_name\"}"
    _hb_rest="${_hb_rest#*:}"
    # 先頭の空白・改行・タブを読み飛ばす（"${x%%[![:space:]]*}" で先頭の空白ランを
    # 切り出し、それをプレフィックスとして取り除く定番のbashイディオム）
    _hb_rest="${_hb_rest#"${_hb_rest%%[![:space:]]*}"}"
    case "$_hb_rest" in
      \"*)
        _hb_rest="${_hb_rest#\"}"
        _hb_name="${_hb_rest%%\"*}"
        [ -n "$_hb_name" ] && TOOL="$_hb_name"
        ;;
    esac
    ;;
esac

# TSVの1行として壊れないよう、タブ・改行・復帰を取り除く
TOOL="${TOOL//$'\t'/}"
TOOL="${TOOL//$'\n'/}"
TOOL="${TOOL//$'\r'/}"
[ -n "$TOOL" ] || TOOL="-"

# ── 時刻取得（dateプロセスを起動しない。bash組み込みの strftime） ────
NOW=""
printf -v NOW '%(%s)T' -1

# ── 原子的な書き込み（一時ファイル + mv） ────────────────────────────
TMP_FILE="${TARGET}.tmp.$$.${RANDOM}"
{ printf '%s\t%s\t%s\n' "$NOW" "$MODE" "$TOOL" > "$TMP_FILE"; } 2>/dev/null || exit 0
mv -f "$TMP_FILE" "$TARGET" 2>/dev/null || true

exit 0
