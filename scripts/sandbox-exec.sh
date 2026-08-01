#!/bin/bash
# dev-workflow: サンドボックス内でコマンドを実行する（ベンダー中立）
#
# `docker run --rm` を毎回使うとコンテナ層が破棄され、ビルドキャッシュが次回に残らない。
# Go プロジェクトでの実測では、コード無変更でも毎回フルビルドとなり1コマンド約40秒かかっていた。
# このスクリプトは
#   1. キャッシュディレクトリを named volume として永続化する
#   2. コンテナを Epic 単位で常駐させ `docker exec` で叩く（起動オーバーヘッドを消す）
# の2点で、同条件を約17秒に短縮する。
#
# 使い方:
#   bash scripts/sandbox-exec.sh 'go build ./... && go test ./...'   # 実行（複数コマンドは1回にまとめる）
#   bash scripts/sandbox-exec.sh --epic epic259 'make test'          # Epic単位でコンテナを分ける
#   bash scripts/sandbox-exec.sh --warm 'go build ./...'             # キャッシュを温める（失敗しても成功扱い）
#   bash scripts/sandbox-exec.sh --down                              # 常駐コンテナを削除（キャッシュは残す）
#   bash scripts/sandbox-exec.sh --reset-cache                       # キャッシュ volume も削除
#
# 終了コードは実行したコマンドのものをそのまま返す（機械的ゲートの判定に使える）。
#
# 参照する環境変数:
#   DEV_WORKFLOW_CACHE_PATHS      volume 化するコンテナ内パス（スペース区切り）。既定は下記 DEFAULT_CACHE_PATHS
#   DEV_WORKFLOW_COMPOSE_SERVICE  compose モードで exec するサービス名（既定: app）
#   その他は resolve-sandbox.sh を参照

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 言語ごとのキャッシュ置き場。存在しないパスを指定しても docker が作るだけなので無害。
# イメージが root 以外のユーザーで動く場合は DEV_WORKFLOW_CACHE_PATHS で上書きする。
DEFAULT_CACHE_PATHS="/root/.cache/go-build /go/pkg/mod /root/.npm /root/.cache/yarn /root/.cargo/registry /root/.cache/pip"
CACHE_PATHS="${DEV_WORKFLOW_CACHE_PATHS:-$DEFAULT_CACHE_PATHS}"
COMPOSE_SERVICE="${DEV_WORKFLOW_COMPOSE_SERVICE:-app}"

EPIC=""
WARM=0
ACTION="exec"

while [ $# -gt 0 ]; do
  case "$1" in
    --epic)        EPIC="${2:-}"; shift 2 ;;
    --warm)        WARM=1; shift ;;
    --down)        ACTION="down"; shift ;;
    --reset-cache) ACTION="reset-cache"; shift ;;
    --)            shift; break ;;
    -*)            echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)             break ;;
  esac
done

CMD="${1:-}"

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'; }

# Git Bash（MSYS）は docker 引数中の `/workspace` を `C:/Program Files/Git/workspace` に
# 勝手に変換してしまう。MSYS_NO_PATHCONV=1 で変換を止めた上で、マウント元だけは
# `pwd -W` で Windows 形式の絶対パスを明示する。Linux/macOS では pwd -W が無いので pwd を使う。
export MSYS_NO_PATHCONV=1
HOST_PWD="$(pwd -W 2>/dev/null || pwd)"

# キャッシュはリポジトリ単位で共有する。worktree の basename（agent-xxxx 等）を使うと
# generator の isolation worktree ごとに別キャッシュになり、キャッシュが効かなくなる。
GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$GIT_COMMON" ]; then
  PROJECT="$(basename "$(dirname "$GIT_COMMON")")"
else
  PROJECT="$(basename "$(pwd)")"
fi

# コンテナはバインドマウント先が異なるため worktree 単位で分ける。
SLUG="$(sanitize "$(basename "$(pwd)")")"
[ -n "$EPIC" ] && SLUG="${SLUG}-$(sanitize "$EPIC")"

CONTAINER="dw-sandbox-${SLUG}"

cache_volume_name() {
  printf 'dw-cache-%s-%s' \
    "$(sanitize "$PROJECT")" \
    "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | sed 's/^-*//; s/-*$//')"
}

cache_mount_args() {
  local path
  for path in $CACHE_PATHS; do
    printf ' -v %s:%s' "$(cache_volume_name "$path")" "$path"
  done
}

eval "$(bash "${SCRIPT_DIR}/resolve-sandbox.sh")"

case "$ACTION" in
  down)
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "常駐コンテナを削除しました: ${CONTAINER}（キャッシュ volume は残しています）"
    exit 0
    ;;
  reset-cache)
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    for path in $CACHE_PATHS; do
      docker volume rm "$(cache_volume_name "$path")" >/dev/null 2>&1 || true
    done
    echo "常駐コンテナとキャッシュ volume を削除しました: ${CONTAINER}"
    exit 0
    ;;
esac

if [ -z "$CMD" ]; then
  echo "ERROR: 実行するコマンドが指定されていません" >&2
  echo "使い方: bash scripts/sandbox-exec.sh [--epic <N>] [--warm] '<command>'" >&2
  exit 2
fi

run_and_report() {
  # --warm はキャッシュ構築が目的なので、失敗してもループを止めない
  if [ "$WARM" -eq 1 ]; then
    "$@" >/dev/null 2>&1 || true
    return 0
  fi
  "$@"
}

case "$DEV_WORKFLOW_SANDBOX_MODE" in
  compose)
    run_and_report docker compose -f "$DEV_WORKFLOW_SANDBOX_COMPOSE" \
      exec -T "$COMPOSE_SERVICE" sh -c "$CMD"
    exit $?
    ;;

  none)
    # サンドボックス未設定。ホスト側で実行する（テストが環境を汚す可能性がある）
    run_and_report sh -c "$CMD"
    exit $?
    ;;

  dockerfile)
    # 常駐コンテナが無ければ起動する。sleep infinity で待機させ、以降は exec で叩く。
    if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
      # shellcheck disable=SC2046  # マウント引数は意図的に単語分割する
      docker run -d --name "$CONTAINER" \
        -v "${HOST_PWD}:/workspace" $(cache_mount_args) \
        -w /workspace "$DEV_WORKFLOW_SANDBOX_IMAGE" sleep infinity >/dev/null || {
          echo "ERROR: サンドボックスコンテナを起動できません: ${CONTAINER}" >&2
          exit 1
        }
    elif [ "$(docker container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
      docker start "$CONTAINER" >/dev/null || {
        echo "ERROR: サンドボックスコンテナを再開できません: ${CONTAINER}" >&2
        exit 1
      }
    fi

    run_and_report docker exec -w /workspace "$CONTAINER" sh -c "$CMD"
    exit $?
    ;;

  *)
    echo "ERROR: サンドボックスのモードを解決できません: ${DEV_WORKFLOW_SANDBOX_MODE:-未設定}" >&2
    exit 1
    ;;
esac
