#!/bin/bash
# dev-workflow: サンドボックス設定の解決（ベンダー中立）
#
# Claude Code の plugin userConfig は他CLIに相当物がないため、設定は環境変数を
# 正本として解決する。Claude Code 側のアダプタが userConfig の値を環境変数に
# 流し込む前提で、スクリプトとスキルはこのスクリプトの出力だけを見る。
#
# 使い方:
#   eval "$(bash scripts/resolve-sandbox.sh)"          # 変数として取り込む
#   bash scripts/resolve-sandbox.sh --print            # 人間向けに表示する
#
# 出力する変数:
#   DEV_WORKFLOW_SANDBOX_MODE       dockerfile | compose | none
#   DEV_WORKFLOW_SANDBOX_IMAGE      docker run に渡すイメージ名（compose時は空）
#   DEV_WORKFLOW_SANDBOX_COMPOSE    使用する compose ファイル（dockerfile時は空）
#   DEV_WORKFLOW_SANDBOX_DOCKERFILE 使用する Dockerfile（compose時は空）
#
# 参照する環境変数（いずれも任意。未設定なら既定の探索に従う）:
#   DEV_WORKFLOW_DOCKER_IMAGE          既存イメージを使う（ビルドしない）
#   DEV_WORKFLOW_DOCKER_COMPOSE_FILE   使用する compose ファイルのパス
#   DEV_WORKFLOW_DOCKERFILE            使用する Dockerfile のパス（既定: Dockerfile.dev）

set -u

PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

DOCKERFILE="${DEV_WORKFLOW_DOCKERFILE:-Dockerfile.dev}"
COMPOSE_FILE="${DEV_WORKFLOW_DOCKER_COMPOSE_FILE:-docker-compose.dev.yml}"

MODE="none"
IMAGE=""
USE_COMPOSE=""
USE_DOCKERFILE=""

# 明示指定されたイメージが最優先（ビルドを省略できる）
if [ -n "${DEV_WORKFLOW_DOCKER_IMAGE:-}" ]; then
  MODE="dockerfile"
  IMAGE="$DEV_WORKFLOW_DOCKER_IMAGE"
elif [ -f "$DOCKERFILE" ]; then
  MODE="dockerfile"
  USE_DOCKERFILE="$DOCKERFILE"
  # プロジェクトディレクトリ名でタグ付けする（並行実行しても衝突しない）
  IMAGE="dev-sandbox:$(basename "$(pwd)")"
elif [ -f "$COMPOSE_FILE" ]; then
  MODE="compose"
  USE_COMPOSE="$COMPOSE_FILE"
fi

if [ "$PRINT" -eq 1 ]; then
  case "$MODE" in
    dockerfile)
      if [ -n "$USE_DOCKERFILE" ]; then
        echo "サンドボックス: ${USE_DOCKERFILE} をビルドして ${IMAGE} として使用"
      else
        echo "サンドボックス: 既存イメージ ${IMAGE} を使用（DEV_WORKFLOW_DOCKER_IMAGE 指定）"
      fi
      ;;
    compose) echo "サンドボックス: ${USE_COMPOSE} を使用" ;;
    none)    echo "サンドボックス: 未設定（${DOCKERFILE} も ${COMPOSE_FILE} も見つかりません）" ;;
  esac
  exit 0
fi

printf 'DEV_WORKFLOW_SANDBOX_MODE=%s\n'       "$MODE"
printf 'DEV_WORKFLOW_SANDBOX_IMAGE=%s\n'      "$IMAGE"
printf 'DEV_WORKFLOW_SANDBOX_COMPOSE=%s\n'    "$USE_COMPOSE"
printf 'DEV_WORKFLOW_SANDBOX_DOCKERFILE=%s\n' "$USE_DOCKERFILE"
