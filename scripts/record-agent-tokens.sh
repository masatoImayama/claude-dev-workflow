#!/bin/bash
# dev-workflow: サブエージェント（generator/evaluator/planner）のトークン消費を記録・集計する
#
# 背景（Epic #66 決定5）: 3つの任意依存ツール（ponytail / context7 / code-review-graph）の
# 導入前後で、サブエージェントのトークン消費が実際に減っているかを実測するための仕組み。
# 「効かなければ外す」を実測で判断できるようにする（docs/optional-mcp-tools.md の
# 「外す判断基準」節を参照）。既存の実行時間計測（`date +%s` の差分。skills/run/SKILL.md）と
# 同じ作法で作る。
#
# **追加の依存物（jq 等）は一切使わない。素の bash で完結する。**
#
# 記録先: <マーカールート>/.claude/agent-tokens.tsv（git 管理外。.gitignore で除外済み）。
# マーカールートの解決は scripts/lib/marker-root.sh を再利用する。run はEpic専用worktree、
# generator/evaluatorはisolation worktreeとcwdがまちまちだが、常に同じメインリポ直下の
# .claude/ に書き込む必要があるため（watchdog.sh・heartbeat.sh と同じ理由）。
#
# 記録形式: TSV（タブ区切り）1行1レコード、6列。
#   timestamp（epoch秒。date +%s）  epic  role  mode  tokens  note
#
# 使い方:
#   record-agent-tokens.sh record --epic <N> --role <generator|evaluator|planner> \
#     --mode <文字列> --tokens <数値> [--note <文字列>]
#     1レコード追記する。
#
#   record-agent-tokens.sh --summary --epic <N>
#     指定Epicのレコードを role・mode ごとに件数・合計・平均で集計し、人間可読に出力する。
#
# **呼び出し側（skills/run/SKILL.md・skills-codex/dev-workflow-run/SKILL.md）への注記:**
# 記録に失敗しても自律ループを止めないこと。トークン数が取得できない場合はこのスクリプトを
# 呼ばずに記録をスキップしてよい。呼び出した場合でも、このスクリプトが非0で終了しても
# （不正な入力・書き込み失敗）run 自体は継続すること。
#
# 環境変数:
#   DEV_WORKFLOW_AGENT_TOKENS_FILE  記録先ファイルを上書きする（テスト用）
#   DEV_WORKFLOW_MARKER_ROOT        マーカー置き場の解決に使う（scripts/lib/marker-root.sh）
#
# 終了コード: 0=成功 2=引数エラー（不正な入力・必須オプション欠落・記録先未解決） 1=書き込み失敗

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/marker-root.sh
. "${SCRIPT_DIR}/lib/marker-root.sh"

usage() {
  cat <<'USAGE'
使い方:
  record-agent-tokens.sh record --epic <N> --role <generator|evaluator|planner> --mode <文字列> --tokens <数値> [--note <文字列>]
  record-agent-tokens.sh --summary --epic <N>
USAGE
}

# 記録先ファイルの絶対パスを標準出力に返す。マーカールートが解決できない場合は非0で返す。
_agent_tokens_file() {
  if [ -n "${DEV_WORKFLOW_AGENT_TOKENS_FILE:-}" ]; then
    printf '%s' "$DEV_WORKFLOW_AGENT_TOKENS_FILE"
    return 0
  fi

  # 引数なし呼び出しは意図的（$PWD を起点にする）。dev_workflow_marker_root の $1 はこの
  # スクリプトの起動引数（record/--summary等）とは無関係なので shellcheck SC2119 は抑止する。
  local root
  # shellcheck disable=SC2119
  root="$(dev_workflow_marker_root)" || return 1
  printf '%s/.claude/agent-tokens.tsv' "$root"
}

# 非負整数かどうかを判定する（小数・負数・空文字・数字以外の文字はすべて不正）
_is_nonneg_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# オプションに値が続いているかを検証する。末尾に値なしでオプション名だけが
# 置かれた場合、呼び出し元の $# は1のまま（残りはオプション名自身のみ）になる。
# これを検出せずに `shift 2` すると、bash の `shift 2` は $# が2未満だと
# 何もせず非0を返すため、while ループが同じ分岐を無限に回り続けてハングする。
# 使い方: _require_opt_value "<コマンド名（エラー接頭辞）>" "<オプション名>" "<残り引数の個数=$#>"
_require_opt_value() {
  local prefix="$1" opt="$2" remaining="$3"
  if [ "$remaining" -lt 2 ]; then
    echo "ERROR: ${prefix}: ${opt} に値がありません" >&2
    usage >&2
    return 2
  fi
  return 0
}

cmd_record() {
  local epic="" role="" mode="" tokens="" note=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --epic) _require_opt_value "record" "$1" "$#" || return 2; epic="$2"; shift 2 ;;
      --role) _require_opt_value "record" "$1" "$#" || return 2; role="$2"; shift 2 ;;
      --mode) _require_opt_value "record" "$1" "$#" || return 2; mode="$2"; shift 2 ;;
      --tokens) _require_opt_value "record" "$1" "$#" || return 2; tokens="$2"; shift 2 ;;
      --note) _require_opt_value "record" "$1" "$#" || return 2; note="$2"; shift 2 ;;
      *)
        echo "ERROR: record: 不明な引数: $1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  if [ -z "$epic" ] || [ -z "$role" ] || [ -z "$mode" ] || [ -z "$tokens" ]; then
    echo "ERROR: record: --epic / --role / --mode / --tokens は必須です" >&2
    usage >&2
    return 2
  fi

  case "$role" in
    generator|evaluator|planner) ;;
    *)
      echo "ERROR: record: --role は generator/evaluator/planner のいずれかである必要があります（実際: ${role}）" >&2
      return 2
      ;;
  esac

  if ! _is_nonneg_int "$tokens"; then
    echo "ERROR: record: --tokens は数値（非負整数）である必要があります（実際: ${tokens}）" >&2
    return 2
  fi

  # TSVを壊さないよう、フィールドに紛れ込んだタブ・改行は空白に置き換える（防御的サニタイズ）
  epic="${epic//$'\t'/ }"; epic="${epic//$'\n'/ }"
  mode="${mode//$'\t'/ }"; mode="${mode//$'\n'/ }"
  note="${note//$'\t'/ }"; note="${note//$'\n'/ }"

  local file
  file="$(_agent_tokens_file)" || {
    echo "ERROR: record: 記録先ファイルの場所を解決できませんでした（git管理下で実行してください）" >&2
    return 2
  }

  mkdir -p "$(dirname "$file")" 2>/dev/null

  local ts
  ts="$(date +%s)"

  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$epic" "$role" "$mode" "$tokens" "$note" >> "$file"; then
    echo "ERROR: record: 記録先ファイルへの書き込みに失敗しました: ${file}" >&2
    return 1
  fi

  echo "recorded: epic=${epic} role=${role} mode=${mode} tokens=${tokens}"
  return 0
}

cmd_summary() {
  local epic=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --epic) _require_opt_value "--summary" "$1" "$#" || return 2; epic="$2"; shift 2 ;;
      *)
        echo "ERROR: --summary: 不明な引数: $1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  if [ -z "$epic" ]; then
    echo "ERROR: --summary には --epic が必須です" >&2
    usage >&2
    return 2
  fi

  local file
  file="$(_agent_tokens_file)" || {
    echo "ERROR: --summary: 記録先ファイルの場所を解決できませんでした（git管理下で実行してください）" >&2
    return 2
  }

  if [ ! -f "$file" ]; then
    echo "epic=${epic}: 記録が0件です（${file} が未作成）"
    return 0
  fi

  # role+mode をキーに件数・合計を集計する（jq等は使わず連想配列のみで行う）
  local -A count_map
  local -A sum_map
  local keys_order=()

  local ts rec_epic role mode tokens note key
  while IFS=$'\t' read -r ts rec_epic role mode tokens note; do
    [ "$rec_epic" = "$epic" ] || continue
    _is_nonneg_int "$tokens" || continue

    key="${role}"$'\t'"${mode}"
    if [ -z "${count_map[$key]:-}" ]; then
      keys_order+=("$key")
      count_map[$key]=0
      sum_map[$key]=0
    fi
    count_map[$key]=$((count_map[$key] + 1))
    sum_map[$key]=$((sum_map[$key] + tokens))
  done < "$file"

  if [ "${#keys_order[@]}" -eq 0 ]; then
    echo "epic=${epic}: 記録が0件です"
    return 0
  fi

  echo "epic=${epic} のトークン消費集計"
  printf '%-10s %-20s %8s %12s %12s\n' "role" "mode" "件数" "合計" "平均"

  local role_p mode_p cnt sum avg
  for key in "${keys_order[@]}"; do
    role_p="${key%%$'\t'*}"
    mode_p="${key#*$'\t'}"
    cnt="${count_map[$key]}"
    sum="${sum_map[$key]}"
    avg=$((sum / cnt))
    printf '%-10s %-20s %8d %12d %12d\n' "$role_p" "$mode_p" "$cnt" "$sum" "$avg"
  done

  return 0
}

# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  record)
    shift
    cmd_record "$@"
    exit $?
    ;;
  --summary)
    shift
    cmd_summary "$@"
    exit $?
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "ERROR: 不明なサブコマンド: $1" >&2
    usage >&2
    exit 2
    ;;
esac
