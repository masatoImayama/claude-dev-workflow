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
#   bash scripts/sandbox-exec.sh --down                              # 現在の repo+epic のコンテナを削除（キャッシュは残す）
#                                                                     # compose モード時は現在の project を `compose down` する
#   bash scripts/sandbox-exec.sh --down --all                        # 現在のリポジトリに属する管理コンテナを全て削除
#                                                                     # compose モード時は同一リポジトリの project も全て down する
#   bash scripts/sandbox-exec.sh --ls                                # 管理コンテナを一覧表示（他リポジトリ分も含む。compose project の状態も表示）
#   bash scripts/sandbox-exec.sh --reset-cache                       # キャッシュ volume を削除
#                                                                     # 【作用範囲はepicではなくリポジトリ全体】
#                                                                     # 同一リポジトリの管理コンテナが1つでも running
#                                                                     # なら中断し、--force の指定を促す
#   bash scripts/sandbox-exec.sh --reset-cache --force                # running でも強制的に削除する
#   bash scripts/sandbox-exec.sh --rebuild 'make test'                # イメージを強制再ビルドしてから実行する
#   bash scripts/sandbox-exec.sh --print-plan                        # docker に触れず解決結果を表示（ドライラン）
#
# 終了コードは実行したコマンドのものをそのまま返す（機械的ゲートの判定に使える）。
#
# イメージの自動ビルドと再作成（仕様書 4.7 / 4.3 の 1）:
#   dockerfile モードでは、イメージが存在しない、または --rebuild 指定時に
#   `docker build -f <Dockerfile> -t <イメージ> <ビルドコンテキスト>` を自動実行する。
#   タグは resolve-sandbox.sh が Dockerfile の内容の hash から決めるため、内容が変われば
#   自動的に別タグになる。ただし hash は Dockerfile 自体の内容しか見ないため、
#   COPY 対象（go.mod / package.json 等）だけを変更した場合は検知できない。
#   その逃げ道が --rebuild であり、内容に変更が無くても強制的に再ビルド・コンテナ作り直しを行う。
#   DEV_WORKFLOW_DOCKER_IMAGE で既存イメージを明示指定した場合はビルド責務を持たない。
#   イメージが無ければビルドせず、取得方法を示すエラーで停止する。
#   既存の常駐コンテナのイメージIDが解決タグの現在のイメージIDと異なる場合も、
#   バージョンスキュー解消のため削除して作り直す（理由を stderr に出す）。
#
# 参照する環境変数:
#   DEV_WORKFLOW_CACHE_PATHS      volume 化するコンテナ内パス（スペース区切り）。既定は下記 DEFAULT_CACHE_PATHS
#   DEV_WORKFLOW_COMPOSE_SERVICE  compose モードで exec するサービス名（既定: app）
#   DEV_WORKFLOW_COMPOSE_WORKDIR  compose モードでのコンテナ内マウント先の基点（既定: /workspace）
#   その他は resolve-sandbox.sh を参照
#
# compose モードについて（仕様書 4.8）:
#   `docker compose -p <PROJECT> --project-directory <HOST_ROOT> -f <COMPOSE_FILE> ...` で呼ぶ。
#   --project-directory をリポジトリルートに固定することで、compose ファイル内の相対マウント
#   （`.`）がどの worktree から叩いても同じツリーを指すようにする（別ツリー実行の防止）。
#   PROJECT は worktree 名に依存しないため、agent worktree から叩いても epic worktree と
#   同じ project になる（リポジトリ外worktreeのフォールバック時は他と分離される。issue #27）。
#   対象サービスが running でなければ `up -d` を試み、それでも起動しなければサービス名と
#   DEV_WORKFLOW_COMPOSE_SERVICE を含むエラーで停止する。既存サービスが running でも
#   マウント元が期待値と異なれば削除して作り直す（issue #27）。
#   compose ファイルに container_name や固定ホストポートがあれば stderr に警告する
#   （-p では解決できない衝突であり、停止はしない）。
#   `--down` / `--down --all` / `--ls` は compose モードのときも対象にする（issue #28）:
#   `--down` は現在の project を `docker compose down` で落とし、`--down --all` は
#   同一リポジトリに属する project をすべて列挙表示のうえ落とす。「同一リポジトリに属する」の
#   判定は project 名の接頭辞一致ではなく、`com.docker.compose.project.working_dir` label
#   （= `--project-directory` に渡した値）を正規化して HOST_ROOT と一致する（配下を含む）かで行う
#   （issue #33。接頭辞一致だけでは他リポジトリの project を巻き込む）。
#   リポジトリ外 worktree のフォールバック実行では working_dir が HOST_ROOT 外になるため、
#   そこで起動した project は `--down --all` の対象に含まれない。
#   `--ls` にも compose project の状態（running/stopped）を表示する。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/mount-path.sh
. "${SCRIPT_DIR}/lib/mount-path.sh"
# shellcheck source=lib/container-membership.sh
. "${SCRIPT_DIR}/lib/container-membership.sh"
# shellcheck source=lib/compose-conflicts.sh
. "${SCRIPT_DIR}/lib/compose-conflicts.sh"

# 言語ごとのキャッシュ置き場。存在しないパスを指定しても docker が作るだけなので無害。
# イメージが root 以外のユーザーで動く場合は DEV_WORKFLOW_CACHE_PATHS で上書きする。
DEFAULT_CACHE_PATHS="/root/.cache/go-build /go/pkg/mod /root/.npm /root/.cache/yarn /root/.cargo/registry /root/.cache/pip"
CACHE_PATHS="${DEV_WORKFLOW_CACHE_PATHS:-$DEFAULT_CACHE_PATHS}"
COMPOSE_SERVICE="${DEV_WORKFLOW_COMPOSE_SERVICE:-app}"

EPIC=""
WARM=0
ALL=0
FORCE=0
REBUILD=0
ACTION="exec"

while [ $# -gt 0 ]; do
  case "$1" in
    --epic)
      # 値が無いまま渡された場合、shift 2 は失敗して $# が減らず無限ループになる
      # （実測: 残り引数が1個の状態で --epic を渡すと停止しない）。
      # 引数個数を検査し、無ければ明快なエラーで停止する。
      if [ $# -lt 2 ]; then
        echo "ERROR: --epic には値が必要です" >&2
        exit 2
      fi
      EPIC="$2"; shift 2 ;;
    --warm)        WARM=1; shift ;;
    --down)        ACTION="down"; shift ;;
    --all)         ALL=1; shift ;;
    --ls)          ACTION="ls"; shift ;;
    --reset-cache) ACTION="reset-cache"; shift ;;
    --force)       FORCE=1; shift ;;
    --rebuild)     REBUILD=1; shift ;;
    --print-plan)  ACTION="print-plan"; shift ;;
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
CUR="$(pwd -W 2>/dev/null || pwd)"

# パス解決（仕様書 4.1）。
# バインドマウント先はリポジトリルート（worktree ではない）に固定する。これにより
# generator の isolation worktree（agent-<id>）や epic worktree が何個増えても
# コンテナは増えない。コンテナ内の作業ディレクトリはリポジトリルートからの相対パスで切り替える。
GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"

FALLBACK=0
REL=""

if [ -n "$GIT_COMMON" ]; then
  REPO_ROOT="$(dirname "$GIT_COMMON")"
  HOST_ROOT="$(cd "$REPO_ROOT" && { pwd -W 2>/dev/null || pwd; })"
  case "$CUR" in
    "$HOST_ROOT")
      REL=""
      ;;
    "$HOST_ROOT"/*)
      REL="${CUR#"$HOST_ROOT"/}"
      ;;
    *)
      # 現在のディレクトリがリポジトリルート配下にない（リポジトリ外に作られた
      # 兄弟 worktree 等）。従来どおり現在のディレクトリをマウントし、
      # epic 共有コンテナと混ざらないようコンテナ名を分離する。
      FALLBACK=1
      ;;
  esac
else
  # git リポジトリでない場合は従来どおり現在のディレクトリを使う。
  REPO_ROOT="$CUR"
  HOST_ROOT="$CUR"
fi

if [ "$FALLBACK" -eq 1 ]; then
  MOUNT_SOURCE="$CUR"
  echo "WARNING: 現在のディレクトリ (${CUR}) はリポジトリルート (${HOST_ROOT}) の外にあります。フォールバックとして現在のディレクトリをマウントし、コンテナは epic 共有コンテナとは分離します。" >&2
else
  MOUNT_SOURCE="$HOST_ROOT"
fi

WORKDIR="/workspace"
[ -n "$REL" ] && WORKDIR="/workspace/${REL}"

# compose モードのコンテナ内 workdir（仕様書 4.8）。
# DEV_WORKFLOW_COMPOSE_WORKDIR（既定 /workspace）+ REL。compose ファイル側が
# `.:/workspace` をマウントする前提とし、異なる場合は環境変数で上書きする。
COMPOSE_WORKDIR_BASE="${DEV_WORKFLOW_COMPOSE_WORKDIR:-/workspace}"
COMPOSE_WORKDIR="$COMPOSE_WORKDIR_BASE"
[ -n "$REL" ] && COMPOSE_WORKDIR="${COMPOSE_WORKDIR_BASE}/${REL}"

# キャッシュはリポジトリ単位で共有する。worktree の basename（agent-xxxx 等）を使うと
# generator の isolation worktree ごとに別キャッシュになり、キャッシュが効かなくなる。
# フォールバック時も PROJECT はリポジトリルート基準のまま変えない（キャッシュは常にリポジトリ単位）。
PROJECT="$(basename "$REPO_ROOT")"

# コンテナ名（仕様書 4.2）。repo は REPO_ROOT の basename（worktree の basename は使わない）。
# --epic 未指定時は環境変数 DEV_WORKFLOW_EPIC を参照する
# （generator が --epic を渡し忘れても同じコンテナに載るようにするため）。
[ -z "$EPIC" ] && EPIC="${DEV_WORKFLOW_EPIC:-}"

SLUG="$(sanitize "$PROJECT")"
[ -n "$EPIC" ] && SLUG="${SLUG}-$(sanitize "$EPIC")"

# フォールバック時（リポジトリ外worktree）は当該ディレクトリ名を接尾辞に含め、
# CONTAINER と COMPOSE_PROJECT の両方を epic 共有のものと分離する（issue #27）。
# 以前はこの接尾辞を CONTAINER にだけ反映し、COMPOSE_PROJECT は反映していなかった。
# compose は project 名だけで既存サービスを探すため、フォールバック時に project 名が
# 分離されていないと、別ツリー向けの running サービスへ警告なしに exec してしまっていた。
[ "$FALLBACK" -eq 1 ] && SLUG="${SLUG}-$(sanitize "$(basename "$CUR")")"

CONTAINER="dw-sandbox-${SLUG}"

# compose モードのプロジェクト名（仕様書 4.8）: dw-<sanitize(repo)>[-<sanitize(epic)>][-<フォールバック接尾辞>]。
# CONTAINER と同じ SLUG から作るため、通常時は worktree 名に依存せず agent worktree から
# 叩いても epic worktree と同じ project になり、フォールバック時は CONTAINER と同様に分離される。
COMPOSE_PROJECT="dw-${SLUG}"

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

# --print-plan: docker に一切触れず、解決結果を key=value 形式で出力するドライラン。
# 「コンテナ名・イメージタグ・マウント元」を外から観測できる形にし、テストで固定するために用意する。
print_plan() {
  printf 'mode=%s\n' "${DEV_WORKFLOW_SANDBOX_MODE:-}"
  printf 'repo=%s\n'  "$PROJECT"
  printf 'epic=%s\n'  "$EPIC"
  printf 'repo_root=%s\n' "$HOST_ROOT"
  printf 'rel_path=%s\n'  "$REL"
  printf 'fallback=%s\n'  "$FALLBACK"

  case "${DEV_WORKFLOW_SANDBOX_MODE:-}" in
    dockerfile)
      printf 'mount_source=%s\n' "$MOUNT_SOURCE"
      printf 'mount_target=%s\n' "/workspace"
      printf 'workdir=%s\n'      "$WORKDIR"
      ;;
    compose)
      printf 'mount_source=\n'
      printf 'mount_target=\n'
      printf 'workdir=%s\n' "$COMPOSE_WORKDIR"
      ;;
    *)
      printf 'mount_source=\n'
      printf 'mount_target=\n'
      printf 'workdir=\n'
      ;;
  esac

  printf 'container=%s\n' "$CONTAINER"
  printf 'image=%s\n'     "${DEV_WORKFLOW_SANDBOX_IMAGE:-}"
  printf 'dockerfile=%s\n'     "${DEV_WORKFLOW_SANDBOX_DOCKERFILE:-}"
  printf 'build_context=%s\n' "${DEV_WORKFLOW_SANDBOX_CONTEXT:-}"
  printf 'compose_file=%s\n'    "${DEV_WORKFLOW_SANDBOX_COMPOSE:-}"
  printf 'compose_project=%s\n' "$COMPOSE_PROJECT"
  printf 'compose_service=%s\n' "$COMPOSE_SERVICE"

  local path
  for path in $CACHE_PATHS; do
    printf 'cache_volume=%s:%s\n' "$(cache_volume_name "$path")" "$path"
  done
}

# 管理コンテナの列挙・後片付け（仕様書 4.2 / 4.5）。
# 「管理コンテナ」の候補は次の2系統の和集合とする（重複は名前で除去する）:
#   1. label（dev-workflow.managed=1）を持つコンテナ
#   2. label を持たない旧命名の残骸（名前が dw-sandbox- で始まるコンテナ）
# 1 は他リポジトリ・他 epic のものも含む。2 は所属判定（container_belongs_to_repo）で
# マウント元を見て絞り込む必要があるため、ここでは名前だけを集める。
container_field() {
  # container_field <container名> <goテンプレート>
  docker container inspect -f "$2" "$1" 2>/dev/null || true
}

list_managed_candidate_names() {
  {
    docker ps -a --filter "label=dev-workflow.managed=1" --format '{{.Names}}' 2>/dev/null
    docker ps -a --filter "name=dw-sandbox-" --format '{{.Names}}' 2>/dev/null
  } | sort -u
}

MOUNT_SOURCE_TEMPLATE='{{ range .Mounts }}{{ if eq .Destination "/workspace" }}{{ .Source }}{{ end }}{{ end }}'
LABEL_ROOT_TEMPLATE='{{ index .Config.Labels "dev-workflow.root" }}'

list_managed() {
  local name label_repo label_epic image status created found=0

  printf '%-40s %-20s %-15s %-30s %-12s %s\n' "NAME" "REPO" "EPIC" "IMAGE" "STATUS" "CREATED"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=1
    label_repo="$(container_field "$name" '{{ index .Config.Labels "dev-workflow.repo" }}')"
    label_epic="$(container_field "$name" '{{ index .Config.Labels "dev-workflow.epic" }}')"
    image="$(container_field "$name" '{{ .Config.Image }}')"
    status="$(container_field "$name" '{{ .State.Status }}')"
    created="$(container_field "$name" '{{ .Created }}')"
    printf '%-40s %-20s %-15s %-30s %-12s %s\n' \
      "$name" "${label_repo:--}" "${label_epic:--}" "${image:--}" "${status:--}" "${created:--}"
  done < <(list_managed_candidate_names)

  [ "$found" -eq 1 ] || echo "管理コンテナはありません"
}

down_all() {
  local name label_repo label_root mount_source
  local -a targets=()

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    label_repo="$(container_field "$name" '{{ index .Config.Labels "dev-workflow.repo" }}')"
    label_root="$(container_field "$name" "$LABEL_ROOT_TEMPLATE")"
    mount_source="$(container_field "$name" "$MOUNT_SOURCE_TEMPLATE")"
    if container_belongs_to_repo "$label_repo" "$label_root" "$mount_source" "$HOST_ROOT" "$PROJECT"; then
      targets+=("$name")
    fi
  done < <(list_managed_candidate_names)

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "削除対象の管理コンテナはありません（repo=${PROJECT}）"
    return 0
  fi

  echo "削除対象のコンテナ（repo=${PROJECT}）:"
  for name in "${targets[@]}"; do
    echo "  - ${name}"
  done

  for name in "${targets[@]}"; do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done

  echo "削除しました: ${#targets[@]}件"
}

# --reset-cache のガード（仕様書 4.6）。
# キャッシュ volume はリポジトリ単位で共有する（epic 単位にはしない）ため、
# running 判定は現在の epic だけでなく、同一リポジトリに属する管理コンテナ全体
# （他 epic のものも含む）を対象にする。所属判定は down_all と同じ
# container_belongs_to_repo を再利用し、重複実装しない。
list_running_containers_in_repo() {
  local name label_repo label_root mount_source running

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    label_repo="$(container_field "$name" '{{ index .Config.Labels "dev-workflow.repo" }}')"
    label_root="$(container_field "$name" "$LABEL_ROOT_TEMPLATE")"
    mount_source="$(container_field "$name" "$MOUNT_SOURCE_TEMPLATE")"
    container_belongs_to_repo "$label_repo" "$label_root" "$mount_source" "$HOST_ROOT" "$PROJECT" || continue
    running="$(container_field "$name" '{{.State.Running}}')"
    [ "$running" = "true" ] && printf '%s\n' "$name"
  done < <(list_managed_candidate_names)
}

# イメージ解決とビルド（仕様書 4.7）。
# - DEV_WORKFLOW_SANDBOX_DOCKERFILE が非空（= Dockerfile.dev からビルドする運用）の場合は、
#   イメージが存在しないか --rebuild 指定時に docker build を実行し、ビルド責務をここに集約する。
# - DEV_WORKFLOW_SANDBOX_DOCKERFILE が空（= DEV_WORKFLOW_DOCKER_IMAGE で既存イメージを明示指定）
#   の場合はビルドしない。イメージが無ければ、取得方法を示すエラーで停止する
#   （利用者が用意した既存イメージの責務を勝手に肩代わりしないため）。
image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

image_id_of() {
  docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

ensure_sandbox_image() {
  if [ -n "$DEV_WORKFLOW_SANDBOX_DOCKERFILE" ]; then
    if [ "$REBUILD" -eq 1 ] || ! image_exists "$DEV_WORKFLOW_SANDBOX_IMAGE"; then
      echo "サンドボックスイメージをビルドします: ${DEV_WORKFLOW_SANDBOX_IMAGE} (${DEV_WORKFLOW_SANDBOX_DOCKERFILE})" >&2
      docker build -f "$DEV_WORKFLOW_SANDBOX_DOCKERFILE" -t "$DEV_WORKFLOW_SANDBOX_IMAGE" "$DEV_WORKFLOW_SANDBOX_CONTEXT" || {
        echo "ERROR: イメージのビルドに失敗しました: ${DEV_WORKFLOW_SANDBOX_IMAGE}" >&2
        exit 1
      }
    fi
  else
    if [ "$REBUILD" -eq 1 ]; then
      echo "WARNING: DEV_WORKFLOW_DOCKER_IMAGE 指定時はビルド責務を持たないため --rebuild を無視します" >&2
    fi
    if ! image_exists "$DEV_WORKFLOW_SANDBOX_IMAGE"; then
      echo "ERROR: DEV_WORKFLOW_DOCKER_IMAGE=${DEV_WORKFLOW_SANDBOX_IMAGE} で指定されたイメージが見つかりません。" >&2
      echo "       事前に 'docker pull' や 'docker build' 等でイメージを用意するか、DEV_WORKFLOW_DOCKER_IMAGE の指定を外して Dockerfile.dev からの自動ビルドを使ってください。" >&2
      exit 1
    fi
  fi
}

# compose モードの後片付け（issue #28）。
# 本 Epic で compose モードは対象サービスが running でなければ up -d を自動実行するように
# なった一方、--down / --down --all / --ls は docker label / dw-sandbox- 名の常駐コンテナしか
# 見ておらず、compose が起動したコンテナを落とす主体がいなかった。この関数群は
# compose_cmd（-p / --project-directory 付きの docker compose 呼び出し）を、ACTION の
# 分岐（down/ls）と通常の exec 経路の両方から共有するために eval より前で定義する。
compose_cmd() {
  docker compose -p "$COMPOSE_PROJECT" --project-directory "$MOUNT_SOURCE" \
    -f "$DEV_WORKFLOW_SANDBOX_COMPOSE" "$@"
}

# 同一リポジトリに属する compose project 名を列挙する。
# compose が作るコンテナは com.docker.compose.project ラベルを持つため、それを一次情報にする。
#
# `docker ps` のフォーマットコンテキストでは `.Labels` は map ではなく `k=v,k=v` 形式の
# 文字列であり、`{{ index .Labels "..." }}` は「slice/array を string で index できない」で
# 必ず失敗する（`.Labels` が map になるのは `docker inspect` 系のみ）。`docker ps` では
# `{{.Label "..."}}` を使う必要がある（issue #32）。
# 失敗を `2>/dev/null` で握り潰すと、この手のテンプレート誤用が常に「対象0件」として
# 沈黙してしまう（実害: --down --all が何も落とさないのに成功したかのように見える）ため、
# 終了コードが非0なら stderr に警告を出す。
#
# 「同一リポジトリに属する」の判定は project 名の接頭辞一致ではなく、compose が付与する
# com.docker.compose.project.working_dir ラベル（= --project-directory に渡した値）を
# normalize_mount_source() で正規化し、HOST_ROOT と一致する（配下を含む）かで行う
# （issue #33）。接頭辞一致だけだと次のような混入が起こる:
#   - リポジトリ名が他リポジトリ名の接頭辞になっている場合
#   - 同じ basename を別ディレクトリにクローンしている場合
# dockerfile 経路は #29 で dev-workflow.root label による厳密判定を入れているので、
# compose 経路もここで同水準の判定にそろえる。
list_compose_projects_in_repo() {
  local raw rc norm_host proj wd norm_wd
  raw="$(docker ps -a --filter "label=com.docker.compose.project" \
    --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: docker ps による compose project の列挙に失敗しました（終了コード${rc}）: ${raw}" >&2
    return 0
  fi

  norm_host="$(normalize_mount_source "$HOST_ROOT")"

  printf '%s\n' "$raw" | sort -u | while IFS='|' read -r proj wd; do
    [ -n "$proj" ] || continue
    norm_wd="$(normalize_mount_source "$wd")"
    case "$norm_wd" in
      "$norm_host"|"$norm_host"/*) printf '%s\n' "$proj" ;;
    esac
  done
}

# --ls に compose project の状態を表示する（issue #28）。他の管理コンテナ一覧
# （list_managed）とは別出力にし、compose を使っていないプロジェクトでは何も出さない。
list_managed_compose() {
  local proj
  local -a projects=()

  while IFS= read -r proj; do
    [ -n "$proj" ] && projects+=("$proj")
  done < <(list_compose_projects_in_repo)

  [ "${#projects[@]}" -gt 0 ] || return 0

  echo ""
  echo "compose project（repo=${PROJECT}）:"
  printf '%-40s %s\n' "PROJECT" "STATUS"
  for proj in "${projects[@]}"; do
    if docker ps --filter "label=com.docker.compose.project=${proj}" --format '{{.ID}}' 2>/dev/null | grep -q .; then
      printf '%-40s %s\n' "$proj" "running"
    else
      printf '%-40s %s\n' "$proj" "stopped"
    fi
  done
}

# --down --all の compose 版。同一リポジトリに属する project をすべて列挙表示したうえで
# 1つずつ down する（issue #28）。dockerfile モードの残骸（dw-sandbox-*）は down_all が
# 別途処理するため、ここでは compose project だけを対象にする。
down_all_compose() {
  local proj
  local -a targets=()

  while IFS= read -r proj; do
    [ -n "$proj" ] && targets+=("$proj")
  done < <(list_compose_projects_in_repo)

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "削除対象の compose project はありません（repo=${PROJECT}）"
    return 0
  fi

  echo "削除対象の compose project（repo=${PROJECT}）:"
  for proj in "${targets[@]}"; do
    echo "  - ${proj}"
  done

  for proj in "${targets[@]}"; do
    docker compose -p "$proj" --project-directory "$MOUNT_SOURCE" \
      -f "$DEV_WORKFLOW_SANDBOX_COMPOSE" down >/dev/null 2>&1 || true
  done

  echo "compose project を削除しました: ${#targets[@]}件"
}

eval "$(bash "${SCRIPT_DIR}/resolve-sandbox.sh")"

case "$ACTION" in
  down)
    if [ "$ALL" -eq 1 ]; then
      down_all
      # dockerfile モードの残骸（dw-sandbox-*）とは別系統なので、compose モードで
      # 解決された場合は compose project も併せて掃除する（issue #28）。
      [ "$DEV_WORKFLOW_SANDBOX_MODE" = "compose" ] && down_all_compose
      exit 0
    fi

    if [ "$DEV_WORKFLOW_SANDBOX_MODE" = "compose" ]; then
      # compose が作るコンテナは dw-sandbox-<slug> という名前を持たないため、
      # docker rm ではなく docker compose down で project ごと落とす（issue #28）。
      echo "削除対象の compose project: ${COMPOSE_PROJECT}"
      compose_cmd down >/dev/null 2>&1 || true
      echo "compose project を削除しました: ${COMPOSE_PROJECT}（キャッシュ volume は残しています）"
      exit 0
    fi

    echo "削除対象のコンテナ: ${CONTAINER}"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "常駐コンテナを削除しました: ${CONTAINER}（キャッシュ volume は残しています）"
    exit 0
    ;;
  ls)
    list_managed
    # compose モードで解決された場合のみ compose project の状態も表示する（issue #28）。
    [ "$DEV_WORKFLOW_SANDBOX_MODE" = "compose" ] && list_managed_compose
    exit 0
    ;;
  reset-cache)
    # 1. 削除対象の volume 名をすべて列挙して表示する（成否によらず必ず表示する）。
    echo "削除対象のキャッシュ volume（repo=${PROJECT}。作用範囲はepicではなくリポジトリ全体です）:"
    for path in $CACHE_PATHS; do
      echo "  - $(cache_volume_name "$path")"
    done

    # 2. 同一リポジトリの管理コンテナが1つでも running なら中断し、--force を促す。
    #    --force 指定時のみ running でも実行する。
    if [ "$FORCE" -ne 1 ]; then
      RUNNING_NAMES="$(list_running_containers_in_repo)"
      if [ -n "$RUNNING_NAMES" ]; then
        echo "ERROR: 同一リポジトリの管理コンテナが running のため中断しました。--reset-cache の作用範囲はepicではなくリポジトリ全体のため、他 epic の実行中コンテナのキャッシュも壊れます:" >&2
        printf '%s\n' "$RUNNING_NAMES" | while IFS= read -r name; do
          echo "  - ${name}" >&2
        done
        echo "続行するには --force を指定してください: bash scripts/sandbox-exec.sh --reset-cache --force" >&2
        exit 1
      fi
    fi

    # 5. 削除するのは volume と当該（現在の repo+epic の）コンテナのみで、他 epic のコンテナは削除しない。
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    for path in $CACHE_PATHS; do
      docker volume rm "$(cache_volume_name "$path")" >/dev/null 2>&1 || true
    done
    echo "常駐コンテナとキャッシュ volume を削除しました: ${CONTAINER}"
    exit 0
    ;;
  print-plan)
    print_plan
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
    # プロジェクト名とマウント基準の固定（仕様書 4.8）。
    # --project-directory は MOUNT_SOURCE（通常 HOST_ROOT。リポジトリ外 worktree の
    # フォールバック時のみ CUR）を指定する。これにより compose ファイル内の相対マウント
    # （`.`）がどの worktree から叩いても同じツリーを指す（別ツリー実行の防止）。
    # compose_cmd 自体は eval より前で定義済み（--down / --ls とも共有するため）。

    # 衝突要因の検出（container_name / 固定ホストポート）。Docker 非依存の関数で判定し、
    # 見つかっても警告のみで停止しない（-p では解決できない衝突であり、
    # epic の並行実行ができない旨を伝える）。
    while IFS= read -r warning_line; do
      [ -n "$warning_line" ] && echo "WARNING: ${warning_line}" >&2
    done < <(compose_conflict_warnings "$DEV_WORKFLOW_SANDBOX_COMPOSE")

    compose_service_container_id() {
      compose_cmd ps -q "$COMPOSE_SERVICE" 2>/dev/null || true
    }

    compose_service_running() {
      local cid
      cid="$(compose_service_container_id)"
      [ -n "$cid" ] || return 1
      [ "$(docker container inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)" = "true" ]
    }

    # 既存サービスの再利用前にマウント元を検証する（issue #27）。
    # フォールバック時の compose_project 分離（本コミットで修正済み）が主たる対策だが、
    # 手動で project 名を揃えて叩かれた場合等に備え、running なサービスが見つかっても
    # マウント元が期待値（MOUNT_SOURCE）と異なれば、dockerfile モードと同様に削除して
    # 作り直す。正規化済み比較は normalize_mount_source を再利用する（issue #25）。
    COMPOSE_MOUNT_TEMPLATE='{{ range .Mounts }}{{ if eq .Destination "'"$COMPOSE_WORKDIR_BASE"'" }}{{ .Source }}{{ end }}{{ end }}'

    if compose_service_running; then
      EXISTING_COMPOSE_CID="$(compose_service_container_id)"
      EXISTING_COMPOSE_MOUNT="$(docker container inspect -f "$COMPOSE_MOUNT_TEMPLATE" "$EXISTING_COMPOSE_CID" 2>/dev/null || true)"
      if [ -n "$EXISTING_COMPOSE_MOUNT" ] && [ "$(normalize_mount_source "$EXISTING_COMPOSE_MOUNT")" != "$(normalize_mount_source "$MOUNT_SOURCE")" ]; then
        echo "WARNING: compose サービス '${COMPOSE_SERVICE}'（project=${COMPOSE_PROJECT}）の既存コンテナのマウント元 (${EXISTING_COMPOSE_MOUNT}) が期待値 (${MOUNT_SOURCE}) と異なるため削除して作り直します（別ツリー実行の防止）" >&2
        docker rm -f "$EXISTING_COMPOSE_CID" >/dev/null 2>&1 || true
      fi
    fi

    # サービスの起動確認と自動 up（仕様書 4.8 の 3）。
    if ! compose_service_running; then
      echo "compose サービス '${COMPOSE_SERVICE}' が running ではないため起動します: docker compose up -d ${COMPOSE_SERVICE}" >&2
      compose_cmd up -d "$COMPOSE_SERVICE" >/dev/null 2>&1 || true
    fi

    if ! compose_service_running; then
      echo "ERROR: compose サービス '${COMPOSE_SERVICE}' を起動できませんでした。" >&2
      echo "       compose ファイル (${DEV_WORKFLOW_SANDBOX_COMPOSE}) にサービス '${COMPOSE_SERVICE}' が定義され、常駐する設定になっているか確認してください。" >&2
      echo "       既定のサービス名は 'app' です。異なる名前を使う場合は環境変数 DEV_WORKFLOW_COMPOSE_SERVICE で指定してください。" >&2
      exit 1
    fi

    # exec 前に workdir の存在を確認する（仕様書 4.8 の workdir 解決）。
    if ! compose_cmd exec -T "$COMPOSE_SERVICE" test -d "$COMPOSE_WORKDIR" >/dev/null 2>&1; then
      echo "ERROR: コンテナ内に作業ディレクトリ (${COMPOSE_WORKDIR}) が見つかりません。" >&2
      echo "       compose ファイルのマウント先と DEV_WORKFLOW_COMPOSE_WORKDIR（既定 /workspace）が食い違っている可能性があります。" >&2
      echo "       compose ファイル側でリポジトリルートを ${COMPOSE_WORKDIR_BASE} にマウントするか、DEV_WORKFLOW_COMPOSE_WORKDIR を実際のマウント先に合わせてください。" >&2
      exit 1
    fi

    run_and_report compose_cmd exec -T -w "$COMPOSE_WORKDIR" "$COMPOSE_SERVICE" sh -c "$CMD"
    exit $?
    ;;

  none)
    # サンドボックス未設定。ホスト側で実行する（テストが環境を汚す可能性がある）
    run_and_report sh -c "$CMD"
    exit $?
    ;;

  dockerfile)
    # イメージが無ければ自動ビルドする（--rebuild 指定時は強制的に再ビルドする）。
    ensure_sandbox_image

    # 既存コンテナは次のいずれかに該当すれば削除して作り直す（仕様書 4.3）:
    #   1. イメージIDが解決タグの現在のイメージIDと異なる（バージョンスキュー解消）
    #   2. マウント元が期待値（MOUNT_SOURCE）と異なる（別ツリー実行の防止）
    #   3. --rebuild が明示指定されている（内容が変わっていなくても作り直す）
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
      RECREATE=0

      # マウント元の比較は正規化済み（normalize_mount_source）で行う。Windows +
      # Docker Desktop では .Source が `/run/desktop/mnt/host/c/...` という
      # Linux 側の変換済みパスで返るため、素の文字列比較では常に不一致になる（issue #25）。
      EXISTING_MOUNT="$(container_field "$CONTAINER" "$MOUNT_SOURCE_TEMPLATE")"
      if [ -n "$EXISTING_MOUNT" ] && [ "$(normalize_mount_source "$EXISTING_MOUNT")" != "$(normalize_mount_source "$MOUNT_SOURCE")" ]; then
        echo "WARNING: 既存コンテナ ${CONTAINER} のマウント元 (${EXISTING_MOUNT}) が期待値 (${MOUNT_SOURCE}) と異なるため削除して作り直します（別ツリー実行の防止）" >&2
        RECREATE=1
      fi

      CURRENT_IMAGE_ID="$(image_id_of "$DEV_WORKFLOW_SANDBOX_IMAGE")"
      EXISTING_IMAGE_ID="$(container_field "$CONTAINER" '{{.Image}}')"
      if [ -n "$CURRENT_IMAGE_ID" ] && [ -n "$EXISTING_IMAGE_ID" ] && [ "$EXISTING_IMAGE_ID" != "$CURRENT_IMAGE_ID" ]; then
        echo "WARNING: 既存コンテナ ${CONTAINER} のイメージ (${EXISTING_IMAGE_ID}) が現在のイメージ ${DEV_WORKFLOW_SANDBOX_IMAGE} (${CURRENT_IMAGE_ID}) と異なるため削除して作り直します（バージョンスキューの解消）" >&2
        RECREATE=1
      fi

      if [ "$REBUILD" -eq 1 ]; then
        echo "WARNING: --rebuild が指定されたため既存コンテナ ${CONTAINER} を削除して作り直します" >&2
        RECREATE=1
      fi

      if [ "$RECREATE" -eq 1 ]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
      fi
    fi

    # 常駐コンテナが無ければ起動する。sleep infinity で待機させ、以降は exec で叩く。
    if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
      # shellcheck disable=SC2046  # マウント引数は意図的に単語分割する
      docker run -d --name "$CONTAINER" \
        --label "dev-workflow.managed=1" \
        --label "dev-workflow.repo=${PROJECT}" \
        --label "dev-workflow.epic=${EPIC}" \
        --label "dev-workflow.root=${HOST_ROOT}" \
        -v "${MOUNT_SOURCE}:/workspace" $(cache_mount_args) \
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

    run_and_report docker exec -w "$WORKDIR" "$CONTAINER" sh -c "$CMD"
    exit $?
    ;;

  *)
    echo "ERROR: サンドボックスのモードを解決できません: ${DEV_WORKFLOW_SANDBOX_MODE:-未設定}" >&2
    exit 1
    ;;
esac
