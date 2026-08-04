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
# 打ち切り（--abort）判定（#50。Epic #42 仕様書「5. 打ち切りの仕様」。
# cwd拡張・Codexのブロック契約の限界の明記はレビュー#59, #61）:
#   .dev-workflow-abort は人間が `watchdog.sh --abort` を明示的に叩いたときだけ作られる
#   （このスクリプトは作らない。watchdog.sh のtick・検知フックも作らない）。
#   pre（PreToolUse）呼び出しで、そのフラグが存在し、かつフック入力JSONの cwd が
#   次のいずれかを含む場合にのみ、このツール呼び出しを拒否する。
#     - `.claude/worktrees/agent-` … Claudeのサブエージェントisolation worktree
#     - `.codex/worktrees/`        … Codexのgenerator/evaluatorが動くEpic共有worktree。
#       Codexにはタスクごとのisolation worktreeという概念自体が無く（adapters/codex/run-loop.sh
#       のEPIC_WT）、generator/evaluatorは常にこの共有worktreeで動くため、Claudeの
#       isolation worktreeパターンと同じ役割をこちらが担う
#   run のメインループは、無人ループ（`adapters/codex/run-loop.sh` / Claudeの`skills/run/SKILL.md`）
#   経由なら絶対に拒否されない。Claudeはcwdが上記パターンに一致しない（epic worktree・
#   リポジトリルート）ため。Codexは`run-loop.sh`自体がbashスクリプトでありcodexセッション
#   （フックの発火源）ではなく、`.codex/worktrees/`パターンが対象にするのは同スクリプトが
#   `codex exec -C "$EPIC_WT"` で別セッションとして起動するgenerator/evaluatorだけであるため、
#   メインループのフックはそもそも呼ばれない（レビュー#63）。
#   一方、Codexのスキル`dev-workflow-run`（skills-codex/dev-workflow-run/SKILL.md）を
#   セッション内で直接回す経路では、メインループ自身が `cd "$EPIC_WT"` した**同一セッション内**
#   でgenerator/evaluatorサブエージェントを呼ぶ（Codexのカスタムエージェントにcwd相当が無く、
#   セッションのcwdをそのまま継承するため。docs/dev-workflow-multi-vendor-guide.md §3.3.3）。
#   この経路ではメインループとサブエージェントのツール呼び出しが区別できるcwdの差を持たず、
#   `--abort`がメインループのツール呼び出しにも及びうる（あるいは逆に全く効かない。cwdの
#   報告がセッション起動時点の値なのか、呼び出し時点の実ディレクトリなのかに依存する）。
#   したがってこの経路では`--abort`を「サブエージェントだけを止める手段」として当てにせず、
#   確実に止めたい場合はセッションそのものを中断すること
#   （skills-codex/dev-workflow-run/SKILL.md「ハングしたときに人間がすること」参照）。
#   post（PostToolUse）では拒否しない（後から止めても意味が無いため）。
#   通知方法はCLIごとに契約が異なる（scripts/check-readability.sh と同じ出し分け）:
#     - Claude Code … exit 2 + stderr にメッセージ。**ハードブロック**（ツール呼び出しは
#       確実に拒否される）
#     - Codex CLI  … exit 0 + stdout に {"continue": false, ...} のJSON。ただし
#       docs/dev-workflow-multi-vendor-guide.md §3.5.2 のとおり CodexのPreToolUseは
#       `systemMessage` のみに対応し `continue` は読まない（無視される）ため、
#       **ハードブロックにはならない。** ツール呼び出し自体はそのまま実行され、
#       モデルが systemMessage の指示（打ち切り理由・中止と報告の依頼）を読んで
#       自発的に停止することを期待する**ソフトな打ち切り依頼**にとどまる
#       （skills-codex/dev-workflow-run/SKILL.md「ハングしたときに人間がすること」に明記）。
#       確実に止めたい場合は run-loop.sh のセッション（`codex exec` プロセス）を
#       人間が中断する必要がある
#   限界（両CLI共通）: API 応答待ちで固まっている間はツール呼び出しが発生しないため
#   abort は効かない。効くのはエージェントが次のツールを呼んだ瞬間である。
#
# 非機能要件（Epic #42 仕様書「7. 非機能要件」）:
#   - どんな異常があっても必ず exit 0 で終わる（生存信号の記録が run を止めてはならない。
#     マーカールートが解決できない・.claude が無い・stdin が空・JSON が壊れている、
#     いずれも黙って通す）。**例外は上記の打ち切り判定だけであり、これは異常系ではなく
#     人間が明示的に指示した拒否である**（Claude契約ではexit 2で終わる）。
#   - 外部プロセスを1つも起動しない（date / jq / sed / grep は使わない。mv のみ例外）。
#     打ち切り判定・ベンダー判定・JSON組み立てもすべてbash組み込みだけで行う。
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

# 引数なし呼び出しは意図的（$PWD を起点にする）。dev_workflow_marker_root の $1 は
# heartbeat.sh 自身の起動引数（pre/post）とは無関係なので shellcheck SC2119 は抑止する。
# shellcheck disable=SC2119
MARKER_ROOT="$(dev_workflow_marker_root 2>/dev/null)" || exit 0
[ -n "$MARKER_ROOT" ] || exit 0

CLAUDE_DIR="${MARKER_ROOT}/.claude"
[ -d "$CLAUDE_DIR" ] || exit 0

TARGET="${CLAUDE_DIR}/.dev-workflow-heartbeat"
ABORT_FLAG="${CLAUDE_DIR}/.dev-workflow-abort"

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

# ── cwd の抽出（打ち切り判定にのみ使う。#50。tool_nameと同じ抽出パターン） ──
# 取り出せなくても記録自体は続ける（打ち切り判定だけが対象外になり、通常どおり動く）。
CWD=""
case "$INPUT" in
  *'"cwd"'*)
    _hb_cwd_rest="${INPUT#*\"cwd\"}"
    _hb_cwd_rest="${_hb_cwd_rest#*:}"
    _hb_cwd_rest="${_hb_cwd_rest#"${_hb_cwd_rest%%[![:space:]]*}"}"
    case "$_hb_cwd_rest" in
      \"*)
        _hb_cwd_rest="${_hb_cwd_rest#\"}"
        CWD="${_hb_cwd_rest%%\"*}"
        ;;
    esac
    ;;
esac

# Windows パスの正規化（レビュー#60）: scripts/check-readability.sh:220-221 と同じ方針で、
# JSONエスケープ解除（\\ → \）と Windows パスの正規化（\ → /）を行う。ただし
# check-readability.sh は sed（外部プロセス）で行っているのに対し、heartbeat.sh は
# 全ツール呼び出しごとに走るため外部プロセスを1つも起動できない（冒頭の非機能要件）。
# そのため sed ではなく bash 組み込みのパラメータ展開（${var//pattern/repl}）だけで
# 同じ正規化を行う。フック入力の cwd が `"C:\\Users\\...\\.claude\\worktrees\\agent-y"`
# のようにJSON上でバックスラッシュが二重エスケープされたまま来ても、
# `C:/Users/.../.claude/worktrees/agent-y` に正規化してから下の abort 判定に渡す。
# POSIX形式（前方スラッシュ）の cwd はこの展開で変化しないため無害。
CWD="${CWD//\\\\/\\}"
CWD="${CWD//\\//}"

# ── 時刻取得（dateプロセスを起動しない。bash組み込みの strftime） ────
NOW=""
printf -v NOW '%(%s)T' -1

# ── 原子的な書き込み（一時ファイル + mv） ────────────────────────────
TMP_FILE="${TARGET}.tmp.$$.${RANDOM}"
{ printf '%s\t%s\t%s\n' "$NOW" "$MODE" "$TOOL" > "$TMP_FILE"; } 2>/dev/null || exit 0
mv -f "$TMP_FILE" "$TARGET" 2>/dev/null || true

# ── 打ち切り（--abort）判定（#50。cwdパターンのCodex対応拡張はレビュー#59, #61。
#    Windowsパス正規化はレビュー#60） ──
# pre（PreToolUse）以外は対象外（postでは拒否しない）。cwdが対象パターン
# （Claude: .claude/worktrees/agent- ／ Codex: .codex/worktrees/）を含まない呼び出し
# （run のメインループ本体）はここで素通りする。CWDは上の正規化により前方スラッシュに
# 揃っているため、cwdがバックスラッシュ表現（Windows）で来ても一致する。
# この case のパターンマッチ自体は外部プロセスを起動しない。
if [ "$MODE" = "pre" ]; then
  case "$CWD" in
    *'.claude/worktrees/agent-'*|*'.codex/worktrees/'*)
      if [ -f "$ABORT_FLAG" ]; then
        # 理由（1行目のみ）を読む。読めなくても拒否自体は行う。
        ABORT_REASON=""
        IFS= read -r ABORT_REASON < "$ABORT_FLAG" 2>/dev/null || true
        ABORT_REASON="${ABORT_REASON%$'\r'}"
        [ -n "$ABORT_REASON" ] || ABORT_REASON="(理由未記録)"

        ABORT_MESSAGE="打ち切りが指示されました。直ちに作業を中止し、現時点の状況（実施済みの変更・未コミットの有無）を報告して終了してください。理由: ${ABORT_REASON}"

        # フック契約の出し分け（scripts/check-readability.sh のベンダー判定と同じ方針）:
        #   1. DEV_WORKFLOW_HOOK_VENDOR が明示されていればそれに従う
        #   2. Codex はプラグインフックに PLUGIN_ROOT を設定する
        #   3. 保険として、入力JSONに Codex 固有拡張の turn_id があれば Codex と判定する
        _HB_VENDOR="${DEV_WORKFLOW_HOOK_VENDOR:-}"
        if [ -z "$_HB_VENDOR" ]; then
          if [ -n "${PLUGIN_ROOT:-}" ]; then
            _HB_VENDOR="codex"
          else
            case "$INPUT" in
              *'"turn_id"'*) _HB_VENDOR="codex" ;;
              *)             _HB_VENDOR="claude" ;;
            esac
          fi
        fi

        if [ "$_HB_VENDOR" = "codex" ]; then
          # JSON文字列リテラル化（jq非依存。check-readability.shのjson_stringと同じ実装）
          _hb_json_string() {
            local s="$1"
            s="${s//\\/\\\\}"
            s="${s//\"/\\\"}"
            s="${s//$'\t'/\\t}"
            s="${s//$'\r'/}"
            s="${s//$'\n'/\\n}"
            printf '"%s"' "$s"
          }
          printf '{"continue":false,"stopReason":%s,"systemMessage":%s}\n' \
            "$(_hb_json_string '打ち切りが指示されました')" \
            "$(_hb_json_string "$ABORT_MESSAGE")"
          exit 0
        fi

        # Claude Code契約: exit 2 + stderr でツール呼び出しをブロックする
        printf '%s\n' "$ABORT_MESSAGE" >&2
        exit 2
      fi
      ;;
  esac
fi

exit 0
