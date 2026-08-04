#!/bin/bash
# dev-workflow plugin: Slack通知
# hookのJSON payloadを標準入力から受け取り、Slack Incoming Webhookに送信する
#
# 使い方: notify-slack.sh <event> [引数]
#   notification              — hook用。承認待ち／入力待ちを通知
#   stop                      — hook用。ターン終了時。自律実行中なら「中断」として通知
#   run-start   <ラベル>      — skill用。自律実行の開始を記録（通知はしない）
#   run-complete <サマリー>   — skill用。自律実行の完全な完了を通知
#   stall            <詳細>   — watchdog用。無活動しきい値を超えた（メンション付き）
#   stall-recovered  <詳細>   — watchdog用。ストール後に活動が戻った
#   sleep-gap        <詳細>   — watchdog用。tickの実経過が異常に飛んだ（スリープ痕跡）
#   budget           <詳細>   — watchdog用。ウェーブが予算を超えた（メンション付き）
#   sleep-inhibit-warn <詳細> — watchdog用。スリープ抑止に失敗、または対応する手段が無い
#                               （run中でもPCがスリープしうる状態。初回のみ通知される）
#
# watchdogイベントの<詳細>は呼び出し側（watchdog.sh）が組み立てた文字列をそのまま本文に載せる。
# ストール警告では「ツール実行中に停止（state=pre）」「モデルの応答待ちで停止（state=post）」を
# 呼び出し側が文言に含めることで、原因の切り分けができる本文にする（Epic #42 受け入れ条件2）。
# sleep-gapはstallとは別イベントなので、スリープ復帰をストールとして誤報することはない
# （Epic #42 受け入れ条件3）。
#
# 自律実行中は .claude/.dev-workflow-run をマーカーとして置き、
# run-complete に到達せずStopした場合を「中断」として区別する。
#
# Webhook URLの解決順（プロジェクト単位の設定を優先）:
#   1. プロジェクトの .claude/slack-webhook ファイル（1行目のURL）
#   2. 環境変数 SLACK_WEBHOOK_URL
#   どちらも無ければ通知OFFとして何もせずexit 0
#
# 環境変数:
#   DEV_WORKFLOW_NOTIFY_STOP     — "1" のときのみStop完了通知を送る（既定: 送らない）
#   DEV_WORKFLOW_NOTIFY_IDLE     — "1" のときのみ「入力待ち」通知を送る（既定: 送らない）
#   DEV_WORKFLOW_NOTIFY_COOLDOWN — 同じ通知を抑止する秒数（既定: 600、0で無効）
#   DEV_WORKFLOW_NOTIFY_DEBUG    — "1" で受け取ったNotificationのpayloadを
#                                  .claude/.dev-workflow-notify.log に記録する
#   DEV_WORKFLOW_NOTIFY_SINK     — 設定されていればcurlを呼ばず、組み立てた本文(JSON)を
#                                  このパスへ書き出す（テスト用。Slackへは送信しない）

set -u

NOTIFY_SLACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/marker-root.sh
. "${NOTIFY_SLACK_DIR}/lib/marker-root.sh"

EVENT="${1:-unknown}"
ARG="${2:-}"

# hook以外（skillからの直接実行）は標準入力を待たない
case "$EVENT" in
  notification|stop) PAYLOAD="$(cat)" ;;
  *)                 PAYLOAD="" ;;
esac

# JSONから文字列フィールドを取り出す（jqがあれば使い、無ければsedで代替）
json_field() {
  local key="$1"
  if command -v jq &> /dev/null; then
    printf '%s' "$PAYLOAD" | jq -r --arg k "$key" '.[$k] // ""'
  else
    # jqが無い環境向けの簡易抽出。取り出した値のJSONエスケープも戻す
    printf '%s' "$PAYLOAD" \
      | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\(\([^\"\\]\|\\\\.\)*\)\".*/\1/p" \
      | head -1 \
      | sed 's/\\n/ /g; s/\\"/"/g; s/\\\\/\\/g'
  fi
}

# Slackに送る文字列をJSON文字列としてエスケープする
json_escape() {
  if command -v jq &> /dev/null; then
    printf '%s' "$1" | jq -Rs .
  else
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')"
  fi
}

# transcript(jsonl)から最後のアシスタント発言を抜き出す。jqが無い環境では空を返す
last_assistant_message() {
  local transcript
  transcript="$(json_field transcript_path)"
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 0
  command -v jq &> /dev/null || return 0
  tail -50 "$transcript" \
    | jq -r 'select(.type == "assistant")
             | .message.content[]? | select(.type == "text") | .text' 2>/dev/null \
    | tail -20 \
    | cut -c1-800
}

CWD="$(json_field cwd)"
[ -z "$CWD" ] && CWD="$(pwd)"

# 自律実行中であることを示すマーカー。
# skillはworktree（.claude/worktrees/<epicN>）内から実行されるが、hookのcwdはメインリポの
# ルートなので、両者が同じファイルを見るようメインリポのルートに固定する
# （解決処理は scripts/lib/marker-root.sh に共通化してある）
MARKER_ROOT="$(dev_workflow_marker_root "$CWD")"
[ -n "$MARKER_ROOT" ] || MARKER_ROOT="$CWD"
RUN_MARKER="$MARKER_ROOT/.claude/.dev-workflow-run"

# 通知が多すぎるときに、実際どのpayloadで発火しているかを追えるようにする
if [ "$EVENT" = "notification" ] && [ "${DEV_WORKFLOW_NOTIFY_DEBUG:-}" = "1" ]; then
  mkdir -p "$MARKER_ROOT/.claude"
  printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PAYLOAD" \
    >> "$MARKER_ROOT/.claude/.dev-workflow-notify.log"
fi

# run-startは通知を伴わないので、Webhook解決より前に処理する
if [ "$EVENT" = "run-start" ]; then
  mkdir -p "$MARKER_ROOT/.claude"
  printf '%s\n' "${ARG:-自律実行}" > "$RUN_MARKER"
  exit 0
fi

# マーカーの有無で「完全な完了」と「途中停止」を判別する。
# 通知OFFのプロジェクトでもマーカーは残さないよう、Webhook解決より前に消す
RUN_LABEL=""
[ -f "$RUN_MARKER" ] && RUN_LABEL="$(head -1 "$RUN_MARKER" | tr -d '\r')"
[ "$EVENT" = "run-complete" ] && rm -f "$RUN_MARKER"

# プロジェクト個別の設定を優先し、無ければ環境変数にフォールバックする。
# 設定ファイルはgitignore対象でworktreeには存在しないため、メインリポのルートを見る
WEBHOOK_FILE="$MARKER_ROOT/.claude/slack-webhook"
[ -f "$WEBHOOK_FILE" ] || WEBHOOK_FILE="$CWD/.claude/slack-webhook"
WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
PROJECT_NAME="${DEV_WORKFLOW_PROJECT_NAME:-}"
if [ -f "$WEBHOOK_FILE" ]; then
  # コメント行・空行を無視して最初のURLを採用（末尾のCRも除去）
  FROM_FILE="$(grep -v '^[[:space:]]*#' "$WEBHOOK_FILE" | grep -m1 '^[[:space:]]*https://' | tr -d '\r' | xargs)"
  [ -n "$FROM_FILE" ] && WEBHOOK_URL="$FROM_FILE"
  # 任意: `name=表示名` 行で通知に出すプロジェクト名を上書きできる
  NAME_LINE="$(grep -m1 '^[[:space:]]*name[[:space:]]*=' "$WEBHOOK_FILE" | tr -d '\r' | sed 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*//')"
  [ -n "$NAME_LINE" ] && [ -z "$PROJECT_NAME" ] && PROJECT_NAME="$NAME_LINE"
  # 任意: `mention=` 行でメンション先を変更できる（既定は channel）
  MENTION_LINE="$(grep -m1 '^[[:space:]]*mention[[:space:]]*=' "$WEBHOOK_FILE" | tr -d '\r' | sed 's/^[[:space:]]*mention[[:space:]]*=[[:space:]]*//')"
  [ -n "$MENTION_LINE" ] && [ -z "${DEV_WORKFLOW_SLACK_MENTION:-}" ] && MENTION_SETTING="$MENTION_LINE"
fi

# 既定で @channel を付ける。channel / here / none / 生のメンション文字列（<@U123>等）を受け付ける
MENTION_SETTING="${DEV_WORKFLOW_SLACK_MENTION:-${MENTION_SETTING:-channel}}"
case "$MENTION_SETTING" in
  channel) MENTION="<!channel> " ;;
  here)    MENTION="<!here> " ;;
  none|"") MENTION="" ;;
  *)       MENTION="$MENTION_SETTING " ;;
esac

# 未設定なら通知OFF
[ -n "$WEBHOOK_URL" ] || exit 0

# 表示名の既定はメインリポのディレクトリ名（worktree内でもプロジェクト名がぶれないように）。
# どの環境から来た通知かブランチとパスも添える
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$MARKER_ROOT")"
BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
CONTEXT="$CWD"
[ -n "$BRANCH" ] && CONTEXT="branch: $BRANCH ・ $CWD"

DETAIL=""
case "$EVENT" in
  notification)
    MESSAGE="$(json_field message)"
    # Notification hookは人の操作を必要としない場面（サブエージェントの切り替え、
    # LLMの応答待ちなど）でも発火し、文言からは区別できなかった。
    # そのため「入力待ち」通知は既定でOFFとし、承認待ちだけを送る。
    # DEV_WORKFLOW_NOTIFY_IDLE=1 のときに限り入力待ちも送る。
    case "$MESSAGE" in
      *permission*|*Permission*|*許可*)
        HEADLINE=":lock: 承認待ち" ;;
      *"waiting for your input"*|*"waiting for input"*|*idle*|*Idle*|*入力待ち*)
        [ "${DEV_WORKFLOW_NOTIFY_IDLE:-}" = "1" ] || exit 0
        HEADLINE=":hourglass: 入力待ち" ;;
      *)
        exit 0 ;;
    esac
    DETAIL="$MESSAGE"
    ;;
  run-complete)
    # 自律実行が最後まで到達した唯一の地点。常に通知する
    HEADLINE=":white_check_mark: 完了${RUN_LABEL:+ — $RUN_LABEL}"
    DETAIL="$ARG"
    ;;
  stop)
    if [ -n "$RUN_LABEL" ]; then
      # マーカーが残ったままのStop = run-completeに到達せず止まった
      HEADLINE=":octagonal_sign: 自律実行が停止 — $RUN_LABEL"
      DETAIL="完了前に停止しました。エラー・承認待ち・コンテキスト切れの可能性があります。
$(last_assistant_message 2>/dev/null || true)"
      # 停止通知は1回だけ。以降のターンで鳴り続けないようマーカーを消す
      rm -f "$RUN_MARKER"
    else
      # 通常のターン終了。毎ターン鳴るため明示的にONにしたときだけ送る
      if [ "${DEV_WORKFLOW_NOTIFY_STOP:-}" != "1" ]; then
        exit 0
      fi
      HEADLINE=":white_check_mark: 応答完了"
      DETAIL="$(last_assistant_message 2>/dev/null || true)"
    fi
    ;;
  stall)
    # 無活動しきい値超過。呼び出し側（watchdog.sh）が「ツール実行中に停止」
    # 「モデルの応答待ちで停止」のどちらかを詳細文字列に含めて渡す
    HEADLINE=":rotating_light: 応答なし"
    DETAIL="$ARG"
    ;;
  stall-recovered)
    HEADLINE=":arrow_forward: 応答が再開"
    DETAIL="$ARG"
    ;;
  sleep-gap)
    # スリープ復帰の痕跡。stallとは別イベントなので、通知を見ればストールとの誤報と
    # 区別できる
    HEADLINE=":zzz: スリープ痕跡"
    DETAIL="$ARG"
    ;;
  budget)
    HEADLINE=":hourglass_flowing_sand: 想定時間超過"
    DETAIL="$ARG"
    ;;
  sleep-inhibit-warn)
    # スリープ抑止に失敗した、または対応する手段が無い場合の警告。同じ警告を毎tick
    # 送るとSlackを埋めるため、初回のみ呼び出す（watchdog.sh側でWD_STATE_INHIBIT_WARNEDを
    # 見て制御している。ここでは受け取った通知をそのまま送るだけ）
    HEADLINE=":warning: スリープ抑止に失敗"
    DETAIL="$ARG"
    ;;
  *)
    HEADLINE=":information_source: $EVENT"
    ;;
esac

# アイドル通知は待たせている間ずっと繰り返し発火するので、
# 同じ内容が続く間は一定時間鳴らさない
COOLDOWN="${DEV_WORKFLOW_NOTIFY_COOLDOWN:-600}"
if [ "$EVENT" = "notification" ] && [ "$COOLDOWN" -gt 0 ] 2>/dev/null; then
  STATE_FILE="$MARKER_ROOT/.claude/.dev-workflow-notify-last"
  SIG="$(printf '%s' "$HEADLINE|$DETAIL" | cksum | cut -d' ' -f1)"
  NOW="$(date +%s)"
  LAST_SIG=""
  LAST_AT=0
  [ -f "$STATE_FILE" ] && read -r LAST_SIG LAST_AT < "$STATE_FILE"
  if [ "$LAST_SIG" = "$SIG" ] && [ $((NOW - ${LAST_AT:-0})) -lt "$COOLDOWN" ]; then
    exit 0
  fi
  mkdir -p "$MARKER_ROOT/.claude"
  printf '%s %s\n' "$SIG" "$NOW" > "$STATE_FILE"
fi

# 1行目でプロジェクトを特定できるようにする
TEXT="${MENTION}[$PROJECT_NAME] $HEADLINE"
[ -n "$DETAIL" ] && TEXT="$TEXT
$DETAIL"

BODY="{\"text\":$(json_escape "$TEXT"),\"blocks\":[
  {\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":$(json_escape "${MENTION}*[$PROJECT_NAME]* $HEADLINE${DETAIL:+
$DETAIL}")}},
  {\"type\":\"context\",\"elements\":[{\"type\":\"mrkdwn\",\"text\":$(json_escape "$CONTEXT")}]}
]}"

# 実送信は1箇所に閉じ込める。DEV_WORKFLOW_NOTIFY_SINK（ファイルパス）が設定されていれば
# curlを呼ばず、組み立てた本文をそのファイルへ書き出すだけにする。
# これによりテストがSlackへ実送信せずペイロードを検証できる。
send_to_slack() {
  local body="$1"

  if [ -n "${DEV_WORKFLOW_NOTIFY_SINK:-}" ]; then
    printf '%s' "$body" > "$DEV_WORKFLOW_NOTIFY_SINK"
    return 0
  fi

  # 本文は必ずファイル経由で渡す。
  # Git for Windows の curl はネイティブビルドのため、コマンドライン引数として渡した
  # UTF-8 の日本語が cp932 に変換されて壊れる（--data は使わない）。
  local body_file
  body_file="$(mktemp -t slack-notify.XXXXXX)" || return 0
  trap 'rm -f "$body_file"' RETURN
  printf '%s' "$body" > "$body_file"

  curl -sS -m 10 -X POST -H 'Content-Type: application/json; charset=utf-8' \
    --data-binary @"$body_file" "$WEBHOOK_URL" > /dev/null 2>&1
}

send_to_slack "$BODY"

exit 0
