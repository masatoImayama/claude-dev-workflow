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
#
# 状態ファイル（マーカールート直下の .claude/。解決は scripts/lib/marker-root.sh を使う）:
#   .dev-workflow-watchdog.pid  監視デーモンの "<pid> <開始epoch秒>"（1行）
#   .dev-workflow-watchdog.log  検知イベントの追記ログ（人間可読TSV: <時刻>\t<イベント>\t<詳細>）
#
# 環境変数:
#   DEV_WORKFLOW_WATCHDOG_TICK_SEC  tick間隔（秒）。既定60
#   DEV_WORKFLOW_WATCHDOG_MAX_SEC   監視デーモンの最大寿命（秒）。既定86400（24時間）
#   DEV_WORKFLOW_WATCHDOG_NOW       現在時刻をepoch秒で注入する（テスト用。実運用では使わない）
#   DEV_WORKFLOW_MARKER_ROOT        マーカー置き場の解決に使う（scripts/lib/marker-root.sh）
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
# ストール判定・エスカレーション・通知は #47、ウェーブ予算は #48、スリープ抑止は #49、
# 人間が明示的に叩く打ち切り（--abort）は #50 のスコープ。このファイルはそれらが
# 乗せやすいよう、監視ループに no-op のフック関数（_watchdog_check_stall 等）を
# 用意するところまでを担う。

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

# ---------------------------------------------------------------------------
# 引数解析
# ---------------------------------------------------------------------------

ACTION=""
EPIC=""
LABEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --start)       ACTION="start"; shift ;;
    --stop)        ACTION="stop"; shift ;;
    --status)      ACTION="status"; shift ;;
    --tick-once)   ACTION="tick-once"; shift ;;
    # --daemon-loop は内部専用。--start が自己デタッチして再実行するときにだけ使う。
    --daemon-loop) ACTION="daemon-loop"; shift ;;
    --epic)        EPIC="${2:-}"; shift 2 ;;
    --label)       LABEL="${2:-}"; shift 2 ;;
    *)
      echo "watchdog.sh: 不明な引数: $1" >&2
      echo "usage: watchdog.sh --start|--stop|--status|--tick-once [--epic N] [--label LABEL]" >&2
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
_watchdog_pid_alive() {
  local pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ps -p "$pid" > /dev/null 2>&1
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
# 監視ループのフック点（検知ロジックは後続タスクが実装する。ここでは no-op）
# ---------------------------------------------------------------------------

# フック: 無活動（ストール）判定とエスカレーション通知（#47）。現時点では何もしない。
_watchdog_check_stall() { :; }

# フック: ウェーブ予算超過の監視（#48）。現時点では何もしない。
_watchdog_check_wave_budget() { :; }

# フック: スリープ抑止のtick呼び出し（#49）。現時点では何もしない。
_watchdog_sleep_inhibit_tick() { :; }

# _watchdog_tick <now>  監視ループ1周分の処理。tickイベントを記録し、上記フックを呼ぶ。
_watchdog_tick() {
  local now="$1"
  _watchdog_log "tick" "now=${now}"
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
  daemon-loop) watchdog_daemon_loop ;;
  "")
    echo "usage: watchdog.sh --start|--stop|--status|--tick-once [--epic N] [--label LABEL]" >&2
    exit 64
    ;;
esac
