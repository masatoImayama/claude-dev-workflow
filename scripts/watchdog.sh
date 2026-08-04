#!/bin/bash
# dev-workflow: run のハング・スリープを検知して通知する常駐監視プロセス（骨格）
#
# 背景（Epic #42）: Claude Code のサブエージェントはバッチ全員が終わるまで結果が
# 返らないため、run 自身がタイマーでポーリングして自分を監視する設計は成立しない。
# そのため監視は必ずプロセス外に置く必要があり、このスクリプトは `nohup ... &` で
# 自己デタッチする常駐プロセスとして動く（`setsid` は Git Bash に存在しないため使わない）。
#
# 使い方:
#   watchdog.sh --start [--epic N] [--label "Epic #N"]
#     常駐監視を開始する。自己デタッチして即座に返る（多重起動はしない）。
#   watchdog.sh --stop
#     常駐監視を停止する。
#   watchdog.sh --status
#     running / stopped と PID・稼働時間を出力する（running なら exit 0、stopped なら exit 1）。
#   watchdog.sh --tick-once
#     常駐せず、監視ループを1周だけ回して exit 0 で返る（テスト・デバッグ用）。
#   watchdog.sh --wave --epic N --wave-no W --tasks 44,45,46 [--budget-sec N]
#     ウェーブ単位の予算状態（run-state）を書く。run がウェーブ開始時に呼ぶ（#48）。
#     --budget-sec を省略すると、--tasks の各 issue 本文の `- 想定時間:` の最大値 × 2 + 900秒。
#     どれも取れない・gh が使えない場合は既定5400秒（90分）。
#
# 状態ファイル（マーカールート直下の .claude/。解決は scripts/lib/marker-root.sh を使う）:
#   .dev-workflow-watchdog.pid    監視デーモンの "<pid> <開始epoch秒>"（1行）
#   .dev-workflow-watchdog.log    検知イベントの追記ログ（人間可読TSV: <時刻>\t<イベント>\t<詳細>）
#   .dev-workflow-watchdog-state  ストール判定・スリープギャップ補正・予算通知済みフラグの
#                                  内部状態（key=value、1行1項目）
#   .dev-workflow-heartbeat       heartbeat.sh（#44）が書く生存信号（<epoch>\t<pre|post>\t<ツール名>）
#   .dev-workflow-run-state       --wave が書くウェーブ予算の状態（key=value）:
#                                  epic= wave= tasks= wave_started= budget_sec=
#
# 環境変数:
#   DEV_WORKFLOW_WATCHDOG_TICK_SEC      tick間隔（秒）。既定60
#   DEV_WORKFLOW_WATCHDOG_MAX_SEC       監視デーモンの最大寿命（秒）。既定86400（24時間）
#   DEV_WORKFLOW_WATCHDOG_IDLE_SEC      無活動しきい値（秒）。既定900（15分）。超えるとstall通知
#   DEV_WORKFLOW_WATCHDOG_ESCALATE_SEC  再通知間隔（秒）。既定1800（30分）。最大3回まで
#   DEV_WORKFLOW_WATCHDOG_NOW           現在時刻をepoch秒で注入する（テスト用。実運用では使わない）
#   DEV_WORKFLOW_MARKER_ROOT            マーカー置き場の解決に使う（scripts/lib/marker-root.sh）
#
# 自己終了条件（run がどの経路で終了しても watchdog が残らないための3条件。受け入れ条件8）:
#   1. run マーカー（.claude/.dev-workflow-run）が消えたとき（run が完了 or 停止通知済み）
#   2. 最大寿命（DEV_WORKFLOW_WATCHDOG_MAX_SEC）を超えたとき
#   3. --stop を受けたとき（監視デーモン自身に SIGTERM を送る。後述の注記を参照）
#
# 重要な決定事項（Epic #42）: watchdog は自動でエージェントを打ち切らない。検知して
# 通知するだけである。このスクリプトは Claude Code / Codex の CLI プロセスや
# サブエージェントの PID を一切扱わず、それらに対する kill 経路も持たない。
# --stop が送る kill は、このスクリプト自身が --start で起動した監視デーモン
# （$PID_FILE に記録された自分自身のプロセス）にのみ向けられる。人間が明示的に
# --stop を叩いたときだけ実行され、監視ループの内部（tick・検知処理）から
# 自動的に呼ばれる経路は存在しない（受け入れ条件6）。
#
# ストール判定・エスカレーション・スリープギャップ補正は #47、ウェーブ予算の監視は #48 で
# 実装済み（本ファイル）。スリープ抑止は #49、人間が明示的に叩く打ち切り（--abort）は #50 の
# スコープ。それらはまだ no-op のフック関数（_watchdog_sleep_inhibit_tick）のままである。

set -u

WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SELF="${WATCHDOG_DIR}/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=./lib/marker-root.sh
. "${WATCHDOG_DIR}/lib/marker-root.sh"

CWD="$(pwd)"
MARKER_ROOT="$(dev_workflow_marker_root "$CWD")"
[ -n "$MARKER_ROOT" ] || MARKER_ROOT="$CWD"

STATE_DIR="${MARKER_ROOT}/.claude"
PID_FILE="${STATE_DIR}/.dev-workflow-watchdog.pid"
LOG_FILE="${STATE_DIR}/.dev-workflow-watchdog.log"
RUN_MARKER="${STATE_DIR}/.dev-workflow-run"
STALL_STATE_FILE="${STATE_DIR}/.dev-workflow-watchdog-state"
HEARTBEAT_FILE="${STATE_DIR}/.dev-workflow-heartbeat"
RUN_STATE_FILE="${STATE_DIR}/.dev-workflow-run-state"

# ---------------------------------------------------------------------------
# 引数解析
# ---------------------------------------------------------------------------

ACTION=""
EPIC=""
LABEL=""
WAVE_NO=""
TASKS=""
BUDGET_SEC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --start)       ACTION="start"; shift ;;
    --stop)        ACTION="stop"; shift ;;
    --status)      ACTION="status"; shift ;;
    --tick-once)   ACTION="tick-once"; shift ;;
    --wave)        ACTION="wave"; shift ;;
    # --daemon-loop は内部専用。--start が自己デタッチして再実行するときにだけ使う。
    --daemon-loop) ACTION="daemon-loop"; shift ;;
    --epic)        EPIC="${2:-}"; shift 2 ;;
    --label)       LABEL="${2:-}"; shift 2 ;;
    --wave-no)     WAVE_NO="${2:-}"; shift 2 ;;
    --tasks)       TASKS="${2:-}"; shift 2 ;;
    --budget-sec)  BUDGET_SEC="${2:-}"; shift 2 ;;
    *)
      echo "watchdog.sh: 不明な引数: $1" >&2
      echo "usage: watchdog.sh --start|--stop|--status|--tick-once|--wave [--epic N] [--label LABEL]" >&2
      exit 64
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 共通ヘルパ
# ---------------------------------------------------------------------------

# _watchdog_now  現在時刻をepoch秒で返す。DEV_WORKFLOW_WATCHDOG_NOW があればそれを使う
# （テストで実時間を待たずに時間経過を検証できるようにするため）。
_watchdog_now() {
  if [ -n "${DEV_WORKFLOW_WATCHDOG_NOW:-}" ]; then
    printf '%s' "$DEV_WORKFLOW_WATCHDOG_NOW"
  else
    printf '%(%s)T' -1
  fi
}

# _watchdog_log <event> [detail]
# 検知イベントを人間可読TSVで1行追記する（<時刻>\t<イベント>\t<詳細>）。
# 時刻の列も _watchdog_now を使って組み立てるため、DEV_WORKFLOW_WATCHDOG_NOW を
# 与えるとログの時刻もその値になる。
_watchdog_log() {
  local event="$1" detail="${2:-}" now ts
  now="$(_watchdog_now)"
  mkdir -p "$STATE_DIR"
  printf -v ts '%(%Y-%m-%d %H:%M:%S)T' "$now"
  printf '%s\t%s\t%s\n' "$ts" "$event" "$detail" >> "$LOG_FILE"
}

# _watchdog_pid_alive <pid>  そのPIDのプロセスが生存していれば0を返す
#
# `ps -p` ではなく `kill -0`（シグナル0を送るだけで実際には何も起こさない、
# プロセス存在確認のための標準的なイディオム。実際にプロセスを終了させるわけではない
# ため、受け入れ条件6の「kill は --stop のみ」という制約とは別枠で扱う）を使う。
# busybox の ps（サンドボックスコンテナが Alpine のため既定でこれになる）は
# `-p` オプションを持たず、`ps -p <pid>` は常に失敗して誤って「死んでいる」と
# 判定してしまう（実測で発覚）。`kill -0` は Git Bash / Linux（busybox 含む）/
# macOS のいずれでも同じ意味で動く。
#
# `kill -0` はゾンビ（終了済みだが親に回収されていないプロセス）にも成功してしまう
# （POSIXの仕様どおり。回収されるまでPIDがプロセステーブルに残るため）。init を
# 持たない最小コンテナ（このサンドボックス）では孤児プロセスが永久にゾンビのまま
# 残ることが実測で判明した。そのため /proc が読める環境（Linux）では State 行で
# ゾンビを追加判定する。/proc が無い環境（Windows Git Bash）にはゾンビという概念自体が
# 無いため、kill -0 の結果だけで判定すれば十分。
_watchdog_pid_alive() {
  local pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1

  if [ -r "/proc/${pid}/status" ]; then
    local line
    while IFS= read -r line; do
      case "$line" in
        State:*)
          case "$line" in
            *'(zombie)'*) return 1 ;;
          esac
          break
          ;;
      esac
    done < "/proc/${pid}/status"
  fi

  return 0
}

# _watchdog_read_pid_file  PIDファイルの1行（"<pid> <開始epoch秒>"）を標準出力へ返す。
# 無い・空なら何も出力せず非0で返る。
_watchdog_read_pid_file() {
  [ -f "$PID_FILE" ] || return 1
  local line=""
  IFS= read -r line < "$PID_FILE" || true
  line="${line%$'\r'}"
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

# ---------------------------------------------------------------------------
# 監視ループのフック点
# ---------------------------------------------------------------------------
#
# ストール判定・エスカレーション通知・スリープギャップ補正（#47）はこのセクションで
# 実装する。ウェーブ予算超過の監視（#48）とスリープ抑止（#49）はまだ no-op のまま。

# ---- ストール判定・スリープギャップ補正の内部状態の読み書き ----
#
# $STALL_STATE_FILE（key=value を1行ずつ書いたファイル）で、tick をまたいで
# 「無活動しきい値の超過状況」「これまでの通知回数」「スリープギャップの差し引き累計」
# 「前回tickの時刻」を保持する。動的なパスを source（`.`）すると shellcheck SC1090 が
# 飛ぶ上、想定外の内容を誤ってコードとして実行してしまう事故を避けられるため、
# source はせず自前でパースする。

# _watchdog_state_load  $STALL_STATE_FILE を読み、WD_STATE_* 変数へ反映する。
# ファイルが無い・壊れている・値が数値でない場合はすべて既定値（0）にする。
_watchdog_state_load() {
  WD_STATE_HEARTBEAT_EPOCH=0
  WD_STATE_STALL_COUNT=0
  WD_STATE_STALL_NOTIFIED_AT=0
  WD_STATE_SLEEP_GAP_SEC=0
  WD_STATE_LAST_TICK=0
  WD_STATE_BUDGET_NOTIFIED=0

  if [ -f "$STALL_STATE_FILE" ]; then
    local key val
    while IFS='=' read -r key val; do
      case "$key" in
        WD_STATE_HEARTBEAT_EPOCH)   WD_STATE_HEARTBEAT_EPOCH="$val" ;;
        WD_STATE_STALL_COUNT)       WD_STATE_STALL_COUNT="$val" ;;
        WD_STATE_STALL_NOTIFIED_AT) WD_STATE_STALL_NOTIFIED_AT="$val" ;;
        WD_STATE_SLEEP_GAP_SEC)     WD_STATE_SLEEP_GAP_SEC="$val" ;;
        WD_STATE_LAST_TICK)         WD_STATE_LAST_TICK="$val" ;;
        WD_STATE_BUDGET_NOTIFIED)   WD_STATE_BUDGET_NOTIFIED="$val" ;;
      esac
    done < "$STALL_STATE_FILE"
  fi

  case "$WD_STATE_HEARTBEAT_EPOCH"   in ''|*[!0-9]*) WD_STATE_HEARTBEAT_EPOCH=0 ;; esac
  case "$WD_STATE_STALL_COUNT"       in ''|*[!0-9]*) WD_STATE_STALL_COUNT=0 ;; esac
  case "$WD_STATE_STALL_NOTIFIED_AT" in ''|*[!0-9]*) WD_STATE_STALL_NOTIFIED_AT=0 ;; esac
  case "$WD_STATE_SLEEP_GAP_SEC"     in ''|*[!0-9]*) WD_STATE_SLEEP_GAP_SEC=0 ;; esac
  case "$WD_STATE_LAST_TICK"         in ''|*[!0-9]*) WD_STATE_LAST_TICK=0 ;; esac
  case "$WD_STATE_BUDGET_NOTIFIED"   in ''|*[!0-9]*) WD_STATE_BUDGET_NOTIFIED=0 ;; esac
}

# _watchdog_state_save  現在のWD_STATE_*変数を$STALL_STATE_FILEへ原子的に書き出す
# （一時ファイル + mv。heartbeat.sh・notify-slack.sh と同じ書き込みパターン）。
_watchdog_state_save() {
  mkdir -p "$STATE_DIR"
  local tmp="${STALL_STATE_FILE}.tmp.$$.${RANDOM}"
  {
    printf 'WD_STATE_HEARTBEAT_EPOCH=%s\n' "$WD_STATE_HEARTBEAT_EPOCH"
    printf 'WD_STATE_STALL_COUNT=%s\n' "$WD_STATE_STALL_COUNT"
    printf 'WD_STATE_STALL_NOTIFIED_AT=%s\n' "$WD_STATE_STALL_NOTIFIED_AT"
    printf 'WD_STATE_SLEEP_GAP_SEC=%s\n' "$WD_STATE_SLEEP_GAP_SEC"
    printf 'WD_STATE_LAST_TICK=%s\n' "$WD_STATE_LAST_TICK"
    printf 'WD_STATE_BUDGET_NOTIFIED=%s\n' "$WD_STATE_BUDGET_NOTIFIED"
  } > "$tmp"
  mv -f "$tmp" "$STALL_STATE_FILE"
}

# _watchdog_fmt_duration <seconds>  "<N>h<M>m" 形式に整形する（非数値は0扱い）
_watchdog_fmt_duration() {
  local sec="$1" h m
  case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
  h=$(( sec / 3600 ))
  m=$(( (sec % 3600) / 60 ))
  printf '%dh%dm' "$h" "$m"
}

# _watchdog_stall_reason <state>  heartbeatのstateから通知本文に載せる理由を返す
# （受け入れ条件2: state=pre/postで文言を区別する）
_watchdog_stall_reason() {
  case "$1" in
    pre)  printf 'ツール実行中に停止（例: サンドボックスのテストが返らない）' ;;
    post) printf 'モデルの応答待ちで停止（API のスロットリングの疑い）' ;;
    *)    printf '不明な状態で停止（state=%s）' "$1" ;;
  esac
}

# _watchdog_context_suffix  通知本文に添えるEpic番号・ラベル（--start/--tick-onceで受け取ったもの）
_watchdog_context_suffix() {
  local out=""
  [ -n "$EPIC" ]  && out="${out} / Epic #${EPIC}"
  [ -n "$LABEL" ] && out="${out} / ${LABEL}"
  printf '%s' "$out"
}

# _watchdog_check_sleep_gap <now>
#
# tick間隔（DEV_WORKFLOW_WATCHDOG_TICK_SEC、既定60秒）に対して実経過が3倍を超えたら
# 「スリープしていた」と判定する（Epic #42 仕様書「4.3 スリープ検知」）。超過分
# （実経過からtick_sec 1回分を引いた残り）をスリープギャップ累計へ加算し、
# ストール判定（_watchdog_check_stall）がその累計を無活動時間から差し引くことで、
# 復帰直後に長時間ストールとして誤報しないようにする。前回tickの記録が無い
# （このマーカールートで初めてのtick）場合は、比較対象が無いため判定しない。
_watchdog_check_sleep_gap() {
  local now="$1" tick_sec="${DEV_WORKFLOW_WATCHDOG_TICK_SEC:-60}"

  _watchdog_state_load

  if [ "$WD_STATE_LAST_TICK" -eq 0 ]; then
    WD_STATE_LAST_TICK="$now"
    _watchdog_state_save
    return 0
  fi

  local elapsed=$(( now - WD_STATE_LAST_TICK ))
  WD_STATE_LAST_TICK="$now"

  if [ "$elapsed" -gt $(( tick_sec * 3 )) ]; then
    local gap=$(( elapsed - tick_sec ))
    [ "$gap" -lt 0 ] && gap=0
    WD_STATE_SLEEP_GAP_SEC=$(( WD_STATE_SLEEP_GAP_SEC + gap ))
    local detail
    detail="tick間隔${tick_sec}秒に対し実経過${elapsed}秒（スリープ復帰と判定・${gap}秒を無活動時間から差し引き。差し引き累計${WD_STATE_SLEEP_GAP_SEC}秒）$(_watchdog_context_suffix)"
    bash "${WATCHDOG_DIR}/notify-slack.sh" sleep-gap "$detail" >/dev/null 2>&1 || true
    _watchdog_log "sleep-gap" "elapsed=${elapsed}s tick_sec=${tick_sec}s gap=${gap}s total_gap=${WD_STATE_SLEEP_GAP_SEC}s"
  fi

  _watchdog_state_save
}

# _watchdog_notify_stall <now> <idle> <hb_state> <hb_tool> <notify_no>
# stall通知を1回送り、ログへ記録する（notify_noは1〜3回目の通し番号）
_watchdog_notify_stall() {
  local now="$1" idle="$2" hb_state="$3" hb_tool="$4" notify_no="$5"
  local detail
  detail="[${notify_no}/3] 無活動$(_watchdog_fmt_duration "$idle")継続。$(_watchdog_stall_reason "$hb_state")（最終ツール: ${hb_tool}）$(_watchdog_context_suffix)"
  bash "${WATCHDOG_DIR}/notify-slack.sh" stall "$detail" >/dev/null 2>&1 || true
  _watchdog_log "stall" "count=${notify_no} idle=${idle}s state=${hb_state} tool=${hb_tool} now=${now}"
}

# _watchdog_notify_recovered <idle_before>
# stall-recovered通知を1回送り、ログへ記録する
_watchdog_notify_recovered() {
  local idle_before="$1"
  local detail
  detail="無活動$(_watchdog_fmt_duration "$idle_before")から復帰$(_watchdog_context_suffix)"
  bash "${WATCHDOG_DIR}/notify-slack.sh" stall-recovered "$detail" >/dev/null 2>&1 || true
  _watchdog_log "stall-recovered" "idle_before=${idle_before}s"
}

# フック: 無活動（ストール）判定とエスカレーション通知（#47）。
#
# heartbeatファイルが無ければ何もしない（run開始直後の誤報を防ぐ。完了条件）。
# heartbeatのepochが前回チェック時と変わっていれば「活動が戻った」とみなし、
# それまでにstall通知を送っていれば stall-recovered を1回だけ通知してカウンタと
# スリープギャップ累計をリセットする（次にストールするときは初回から数え直す）。
# epochが変わっていなければ、無活動時間（now - epoch - スリープギャップ累計）を
# しきい値・エスカレーション間隔と比較し、最大3回まで通知する（Slackを埋めない）。
_watchdog_check_stall() {
  local now="$1"

  [ -f "$HEARTBEAT_FILE" ] || return 0

  local hb_epoch="" hb_state="" hb_tool=""
  IFS=$'\t' read -r hb_epoch hb_state hb_tool < "$HEARTBEAT_FILE" || return 0
  hb_tool="${hb_tool%$'\r'}"
  case "$hb_epoch" in
    ''|*[!0-9]*) return 0 ;;
  esac

  _watchdog_state_load

  if [ "$hb_epoch" != "$WD_STATE_HEARTBEAT_EPOCH" ]; then
    if [ "$WD_STATE_STALL_COUNT" -gt 0 ]; then
      local idle_before=$(( now - WD_STATE_HEARTBEAT_EPOCH - WD_STATE_SLEEP_GAP_SEC ))
      [ "$idle_before" -lt 0 ] && idle_before=0
      _watchdog_notify_recovered "$idle_before"
    fi
    WD_STATE_HEARTBEAT_EPOCH="$hb_epoch"
    WD_STATE_STALL_COUNT=0
    WD_STATE_STALL_NOTIFIED_AT=0
    WD_STATE_SLEEP_GAP_SEC=0
    _watchdog_state_save
    return 0
  fi

  local idle_sec="${DEV_WORKFLOW_WATCHDOG_IDLE_SEC:-900}"
  local escalate_sec="${DEV_WORKFLOW_WATCHDOG_ESCALATE_SEC:-1800}"
  local max_notify=3
  local idle=$(( now - hb_epoch - WD_STATE_SLEEP_GAP_SEC ))
  [ "$idle" -lt 0 ] && idle=0

  if [ "$WD_STATE_STALL_COUNT" -eq 0 ]; then
    if [ "$idle" -ge "$idle_sec" ]; then
      _watchdog_notify_stall "$now" "$idle" "$hb_state" "$hb_tool" 1
      WD_STATE_STALL_COUNT=1
      WD_STATE_STALL_NOTIFIED_AT="$now"
      _watchdog_state_save
    fi
  elif [ "$WD_STATE_STALL_COUNT" -lt "$max_notify" ]; then
    if [ $(( now - WD_STATE_STALL_NOTIFIED_AT )) -ge "$escalate_sec" ]; then
      WD_STATE_STALL_COUNT=$(( WD_STATE_STALL_COUNT + 1 ))
      _watchdog_notify_stall "$now" "$idle" "$hb_state" "$hb_tool" "$WD_STATE_STALL_COUNT"
      WD_STATE_STALL_NOTIFIED_AT="$now"
      _watchdog_state_save
    fi
  fi
}

# ---- ウェーブ予算（#48） ----
#
# run-state（$RUN_STATE_FILE。--wave が書く key=value）が無ければ予算監視は行わない
# （run-state は run が --wave を結線するまで実運用では存在しない。他の監視には影響しない）。
# 動的なパスを source すると _watchdog_state_load と同じ理由で事故りうるため、
# ここでも source はせず自前でパースする。

# _watchdog_parse_estimate_sec <value>
# `- 想定時間:` の値（コロンの後ろ、前後の空白は呼び出し側でtrim済み）を秒に変換する。
# 書式は "30m"（分）/ "2h"（時間）/ "90"（単位なし=分）。解釈できない値は非0で返し、
# 呼び出し側はその宣言を無視する（仕様どおり）。
_watchdog_parse_estimate_sec() {
  local value="$1" num sec
  case "$value" in
    *m)
      num="${value%m}"
      case "$num" in ''|*[!0-9]*) return 1 ;; esac
      sec=$(( num * 60 ))
      ;;
    *h)
      num="${value%h}"
      case "$num" in ''|*[!0-9]*) return 1 ;; esac
      sec=$(( num * 3600 ))
      ;;
    *)
      case "$value" in ''|*[!0-9]*) return 1 ;; esac
      sec=$(( value * 60 ))
      ;;
  esac
  printf '%s' "$sec"
  return 0
}

# _watchdog_estimate_sec_from_body <issue本文>
# 本文中の最初の "- 想定時間:" 行を取り出し、秒へ変換する。行が無い・値が
# 解釈できない場合は非0で返す（宣言なし・不正値のどちらも「取れなかった」として扱う）。
_watchdog_estimate_sec_from_body() {
  local body="$1" line value
  line="$(printf '%s\n' "$body" | grep -m1 '^- 想定時間:')" || return 1
  value="${line#*:}"
  value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  _watchdog_parse_estimate_sec "$value"
}

# _watchdog_wave_budget_sec <tasks_csv>
# --tasks の各issue番号を `gh issue view --json body -q .body` で読み、`- 想定時間:` の
# 最大値 × 2 + 900秒を返す。1件も取れない・ghが使えない場合は既定5400秒（Epic #42仕様書
# 「4.2 ウェーブ予算超過」）。
_watchdog_wave_budget_sec() {
  local tasks_csv="$1" default_sec=5400
  local max_sec=0 found=0
  local t body sec
  local IFS=','
  for t in $tasks_csv; do
    t="$(printf '%s' "$t" | tr -d '[:space:]')"
    [ -n "$t" ] || continue
    body="$(gh issue view "$t" --json body -q .body 2>/dev/null)" || continue
    [ -n "$body" ] || continue
    sec="$(_watchdog_estimate_sec_from_body "$body")" || continue
    case "$sec" in ''|*[!0-9]*) continue ;; esac
    found=1
    [ "$sec" -gt "$max_sec" ] && max_sec="$sec"
  done
  if [ "$found" -eq 1 ]; then
    printf '%s' $(( max_sec * 2 + 900 ))
  else
    printf '%s' "$default_sec"
  fi
}

# _watchdog_run_state_load  $RUN_STATE_FILE を読み、WB_* 変数へ反映する。
# ファイルが無ければ非0で返す（呼び出し側は予算監視をスキップする）。
_watchdog_run_state_load() {
  [ -f "$RUN_STATE_FILE" ] || return 1
  WB_EPIC="" WB_WAVE="" WB_TASKS="" WB_WAVE_STARTED="" WB_BUDGET_SEC=""
  local key val
  while IFS='=' read -r key val; do
    case "$key" in
      epic)         WB_EPIC="$val" ;;
      wave)         WB_WAVE="$val" ;;
      tasks)        WB_TASKS="$val" ;;
      wave_started) WB_WAVE_STARTED="$val" ;;
      budget_sec)   WB_BUDGET_SEC="$val" ;;
    esac
  done < "$RUN_STATE_FILE"
  return 0
}

# _watchdog_notify_budget <wave> <elapsed> <budget> <epic> <tasks>
# budget通知を1回送り、ログへ記録する
_watchdog_notify_budget() {
  local wave="$1" elapsed="$2" budget="$3" epic="$4" tasks="$5" detail
  detail="ウェーブ${wave} / 経過$(( elapsed / 60 ))分 / 予算$(( budget / 60 ))分$(_watchdog_context_suffix)"
  bash "${WATCHDOG_DIR}/notify-slack.sh" budget "$detail" >/dev/null 2>&1 || true
  _watchdog_log "budget" "epic=${epic} wave=${wave} tasks=${tasks} elapsed=${elapsed}s budget_sec=${budget}s"
}

# フック: ウェーブ予算超過の監視（#48）。
#
# run-stateが無ければ何もしない（他の監視は続く）。wave_started/budget_secが数値として
# 読めない場合も同様にスキップする。経過が予算を超えていて、かつまだこのウェーブで
# 通知していなければ1回だけ通知する（活動していても通知する。ストールとは別の事象）。
# 通知済みフラグは --wave（watchdog_wave）が新しいウェーブを書くたびにリセットされる。
_watchdog_check_wave_budget() {
  local now="$1"

  _watchdog_run_state_load || return 0

  case "$WB_WAVE_STARTED" in ''|*[!0-9]*) return 0 ;; esac
  case "$WB_BUDGET_SEC"   in ''|*[!0-9]*) return 0 ;; esac

  local elapsed=$(( now - WB_WAVE_STARTED ))
  [ "$elapsed" -ge "$WB_BUDGET_SEC" ] || return 0

  _watchdog_state_load
  [ "$WD_STATE_BUDGET_NOTIFIED" -eq 1 ] && return 0

  _watchdog_notify_budget "$WB_WAVE" "$elapsed" "$WB_BUDGET_SEC" "$WB_EPIC" "$WB_TASKS"
  WD_STATE_BUDGET_NOTIFIED=1
  _watchdog_state_save
}

# フック: スリープ抑止のtick呼び出し（#49）。現時点では何もしない。
_watchdog_sleep_inhibit_tick() { :; }

# _watchdog_tick <now>  監視ループ1周分の処理。tickイベントを記録し、上記フックを呼ぶ。
_watchdog_tick() {
  local now="$1"
  _watchdog_log "tick" "now=${now}"
  _watchdog_check_sleep_gap "$now"
  _watchdog_check_stall "$now"
  _watchdog_check_wave_budget "$now"
  _watchdog_sleep_inhibit_tick "$now"
}

# ---------------------------------------------------------------------------
# --start
# ---------------------------------------------------------------------------

watchdog_start() {
  mkdir -p "$STATE_DIR"

  local line pid
  line="$(_watchdog_read_pid_file 2>/dev/null || true)"
  if [ -n "$line" ]; then
    pid="${line%% *}"
    if _watchdog_pid_alive "$pid"; then
      # 既に生存しているプロセスを尊重し、多重起動しない
      echo "watchdog: already running (pid=$pid)"
      return 0
    fi
    # 残骸PID（プロセスが居ない）。無視して起動し直す
    _watchdog_log "stale-pid" "pid=${pid} was not running; starting fresh"
  fi

  local start_epoch daemon_args
  start_epoch="$(_watchdog_now)"
  daemon_args=(--daemon-loop)
  [ -n "$EPIC" ]  && daemon_args+=(--epic "$EPIC")
  [ -n "$LABEL" ] && daemon_args+=(--label "$LABEL")

  # nohup はフォークせず exec で置き換わるため、直後の $! がそのままデーモン本体の
  # PIDになる（実測済み。Epic #42 仕様書「5. デタッチした常駐プロセス」）。
  # 呼び出し側はここで即座に返る。
  nohup bash "$WATCHDOG_SELF" "${daemon_args[@]}" > /dev/null 2>&1 &
  local new_pid=$!

  printf '%s %s\n' "$new_pid" "$start_epoch" > "$PID_FILE"
  _watchdog_log "start" "pid=${new_pid}${EPIC:+ epic=${EPIC}}${LABEL:+ label=${LABEL}}"
  echo "watchdog: started (pid=$new_pid)"
  return 0
}

# ---------------------------------------------------------------------------
# --stop
# ---------------------------------------------------------------------------

watchdog_stop() {
  local line pid
  line="$(_watchdog_read_pid_file 2>/dev/null || true)"
  if [ -z "$line" ]; then
    echo "watchdog: not running (no pid file)"
    return 0
  fi
  pid="${line%% *}"

  if ! _watchdog_pid_alive "$pid"; then
    _watchdog_log "stale-pid" "pid=${pid} was not running at stop"
    rm -f "$PID_FILE"
    echo "watchdog: stopped (stale pid file removed)"
    return 0
  fi

  # ここで送る kill は、--start がこのマシン上に起動した監視デーモン自身（$pid）
  # だけを対象にする。エージェント（Claude Code / Codex の CLI プロセスや
  # サブエージェント）の PID をこのスクリプトは一切保持・参照しないため、
  # kill の対象になり得ない（受け入れ条件6）。人間が --stop を明示的に
  # 実行したときにしか到達しないコードパスである。
  kill "$pid" 2>/dev/null

  local waited=0 max_wait=10
  while _watchdog_pid_alive "$pid" && [ "$waited" -lt "$max_wait" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if _watchdog_pid_alive "$pid"; then
    echo "watchdog: stop timed out (pid=${pid} still alive)" >&2
    return 1
  fi

  rm -f "$PID_FILE"
  echo "watchdog: stopped"
  return 0
}

# ---------------------------------------------------------------------------
# --status
# ---------------------------------------------------------------------------

watchdog_status() {
  local line pid start now elapsed
  line="$(_watchdog_read_pid_file 2>/dev/null || true)"
  if [ -n "$line" ]; then
    pid="${line%% *}"
    start="${line#* }"
    if _watchdog_pid_alive "$pid"; then
      now="$(_watchdog_now)"
      elapsed=$((now - start))
      [ "$elapsed" -ge 0 ] 2>/dev/null || elapsed=0
      printf 'running pid=%s uptime=%ss\n' "$pid" "$elapsed"
      return 0
    fi
  fi
  printf 'stopped\n'
  return 1
}

# ---------------------------------------------------------------------------
# --tick-once（常駐せず1周だけ回す。テスト・デバッグ用）
# ---------------------------------------------------------------------------

watchdog_tick_once() {
  mkdir -p "$STATE_DIR"
  _watchdog_tick "$(_watchdog_now)"
  return 0
}

# ---------------------------------------------------------------------------
# --wave（run-stateの更新。runがウェーブ開始時に呼ぶ。#48）
# ---------------------------------------------------------------------------

watchdog_wave() {
  mkdir -p "$STATE_DIR"

  if [ -z "$EPIC" ] || [ -z "$WAVE_NO" ] || [ -z "$TASKS" ]; then
    echo "watchdog.sh --wave: --epic, --wave-no, --tasks は必須です" >&2
    return 64
  fi

  local now budget
  now="$(_watchdog_now)"
  if [ -n "$BUDGET_SEC" ]; then
    case "$BUDGET_SEC" in
      ''|*[!0-9]*)
        echo "watchdog.sh --wave: --budget-sec は数値で指定してください" >&2
        return 64
        ;;
    esac
    budget="$BUDGET_SEC"
  else
    budget="$(_watchdog_wave_budget_sec "$TASKS")"
  fi

  local tmp="${RUN_STATE_FILE}.tmp.$$.${RANDOM}"
  {
    printf 'epic=%s\n' "$EPIC"
    printf 'wave=%s\n' "$WAVE_NO"
    printf 'tasks=%s\n' "$TASKS"
    printf 'wave_started=%s\n' "$now"
    printf 'budget_sec=%s\n' "$budget"
  } > "$tmp"
  mv -f "$tmp" "$RUN_STATE_FILE"

  # 新しいウェーブを書いたので、前のウェーブで超過通知済みでも次は未通知から始める
  # （受け入れ条件: 次の --wave で状態が更新されたら通知済みフラグをリセットする）
  _watchdog_state_load
  WD_STATE_BUDGET_NOTIFIED=0
  _watchdog_state_save

  _watchdog_log "wave" "epic=${EPIC} wave=${WAVE_NO} tasks=${TASKS} wave_started=${now} budget_sec=${budget}"
  echo "watchdog: wave state updated (epic=${EPIC} wave=${WAVE_NO} budget_sec=${budget}s)"
  return 0
}

# ---------------------------------------------------------------------------
# --daemon-loop（内部専用。--start が自己デタッチして実行する常駐ループ本体）
# ---------------------------------------------------------------------------

# SIGTERM/SIGINT を受けたときの後始末。--stop から送られる kill、または人間が
# 直接プロセスを止めたときに通る。PIDファイルを消してから終了する。
_watchdog_on_term() {
  _watchdog_log "stop" "signal received"
  rm -f "$PID_FILE"
  exit 0
}

watchdog_daemon_loop() {
  trap '_watchdog_on_term' TERM INT

  local tick_sec="${DEV_WORKFLOW_WATCHDOG_TICK_SEC:-60}"
  local max_sec="${DEV_WORKFLOW_WATCHDOG_MAX_SEC:-86400}"
  local start_epoch
  start_epoch="$(_watchdog_now)"

  _watchdog_log "start" "daemon loop begin${EPIC:+ epic=${EPIC}}${LABEL:+ label=${LABEL}} tick_sec=${tick_sec} max_sec=${max_sec}"

  while true; do
    if [ ! -f "$RUN_MARKER" ]; then
      _watchdog_log "exit-reason" "run marker missing (${RUN_MARKER})"
      break
    fi

    local now elapsed
    now="$(_watchdog_now)"
    elapsed=$((now - start_epoch))
    if [ "$elapsed" -ge "$max_sec" ]; then
      _watchdog_log "exit-reason" "max lifetime exceeded (${elapsed}s >= ${max_sec}s)"
      break
    fi

    _watchdog_tick "$now"

    # sleepをバックグラウンドで待つことで、trapで登録したシグナルハンドラが
    # sleep完了を待たず即座に割り込める（bashのwaitはシグナル受信で直ちに返る）。
    # これにより --stop は tick_sec の長さに関わらずすぐに効く。
    sleep "$tick_sec" &
    wait "$!"
  done

  rm -f "$PID_FILE"
  exit 0
}

# ---------------------------------------------------------------------------
# ディスパッチ
# ---------------------------------------------------------------------------

case "$ACTION" in
  start)       watchdog_start ;;
  stop)        watchdog_stop ;;
  status)      watchdog_status ;;
  tick-once)   watchdog_tick_once ;;
  wave)        watchdog_wave ;;
  daemon-loop) watchdog_daemon_loop ;;
  "")
    echo "usage: watchdog.sh --start|--stop|--status|--tick-once|--wave [--epic N] [--label LABEL]" >&2
    exit 64
    ;;
esac
