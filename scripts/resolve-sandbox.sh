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
#   DEV_WORKFLOW_SANDBOX_DOCKERFILE 使用する Dockerfile（compose時・DEV_WORKFLOW_DOCKER_IMAGE指定時は空）
#   DEV_WORKFLOW_SANDBOX_CONTEXT    docker build のビルドコンテキスト（= Dockerfile のあるディレクトリ。
#                                   compose時・DEV_WORKFLOW_DOCKER_IMAGE指定時は空）
#
# 参照する環境変数（いずれも任意。未設定なら既定の探索に従う）:
#   DEV_WORKFLOW_DOCKER_IMAGE          既存イメージを使う（ビルドしない。タグに hash は付けない）
#   DEV_WORKFLOW_DOCKER_COMPOSE_FILE   使用する compose ファイルのパス
#   DEV_WORKFLOW_DOCKERFILE            使用する Dockerfile のパス（既定: Dockerfile.dev）
#
# イメージタグの hash について（仕様書 4.7）:
#   Dockerfile.dev からビルドする場合、タグは dev-sandbox:<repo>-<hash8> とする。
#   hash8 は `git hash-object <Dockerfile>` の先頭8文字（git は必須依存なので追加依存が無い）。
#   Dockerfile の内容だけを見るため、COPY 対象（go.mod 等）の変更は検知できない。
#   その場合は sandbox-exec.sh の --rebuild で明示的に再ビルドする。

set -u

PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

DOCKERFILE="${DEV_WORKFLOW_DOCKERFILE:-Dockerfile.dev}"
COMPOSE_FILE="${DEV_WORKFLOW_DOCKER_COMPOSE_FILE:-docker-compose.dev.yml}"

MODE="none"
IMAGE=""
USE_COMPOSE=""
USE_DOCKERFILE=""
BUILD_CONTEXT=""

# 明示指定されたイメージが最優先（ビルドを省略できる。hash は付けない）
if [ -n "${DEV_WORKFLOW_DOCKER_IMAGE:-}" ]; then
  MODE="dockerfile"
  IMAGE="$DEV_WORKFLOW_DOCKER_IMAGE"
elif [ -f "$DOCKERFILE" ]; then
  MODE="dockerfile"
  USE_DOCKERFILE="$DOCKERFILE"
  # リポジトリ名でタグ付けする。worktree の basename（agent-xxxx 等）を使うと
  # worktree ごとに別タグとなり、既にビルド済みのイメージを取り逃す。
  # sandbox-exec.sh の PROJECT（basename(REPO_ROOT)）と同じ解決方法にすること。
  GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$GIT_COMMON" ]; then
    REPO="$(basename "$(dirname "$GIT_COMMON")")"
  else
    REPO="$(basename "$(pwd)")"
  fi

  # hash8: Dockerfile の内容から決まるタグ接尾辞。内容が同じなら worktree が
  # 違ってもタグが変わらない。内容が変われば自動的に別タグ（≒別イメージ）になる。
  HASH8="$(git hash-object "$DOCKERFILE" 2>/dev/null | cut -c1-8)"
  if [ -n "$HASH8" ]; then
    IMAGE="dev-sandbox:${REPO}-${HASH8}"
  else
    # git hash-object が使えない異常系のみのフォールバック（通常は到達しない）。
    IMAGE="dev-sandbox:${REPO}"
  fi

  # ビルドコンテキストは Dockerfile のあるディレクトリ。
  BUILD_CONTEXT="$(cd "$(dirname "$DOCKERFILE")" && { pwd -W 2>/dev/null || pwd; })"
elif [ -f "$COMPOSE_FILE" ]; then
  MODE="compose"
  USE_COMPOSE="$COMPOSE_FILE"
fi

if [ "$PRINT" -eq 1 ]; then
  case "$MODE" in
    dockerfile)
      if [ -n "$USE_DOCKERFILE" ]; then
        echo "サンドボックス: ${USE_DOCKERFILE} をビルドして ${IMAGE} として使用（ビルドコンテキスト: ${BUILD_CONTEXT}）"
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
printf 'DEV_WORKFLOW_SANDBOX_CONTEXT=%s\n'    "$BUILD_CONTEXT"
