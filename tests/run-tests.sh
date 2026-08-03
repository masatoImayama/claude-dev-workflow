#!/bin/bash
# dev-workflow: このリポジトリ自身を検証するテストランナー（ベンダー中立・Docker 非依存）
#
# bats 等の外部依存を追加せず、素の bash アサーションだけで組み立てる。
# ここに書くテストは Docker を一切呼び出さない。`scripts/sandbox-exec.sh --print-plan`
# のようなドライラン出力・構文チェックのみを対象にする（Docker を使う検証は別途サンドボックス内で行う）。
#
# 使い方:
#   bash tests/run-tests.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
SKIP=0
FAILED_CASES=()

pass() {
  PASS=$((PASS + 1))
  echo "  ok   - $1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES+=("$1")
  echo "  NG   - $1"
  [ -n "${2:-}" ] && echo "         ${2}"
}

skip() {
  SKIP=$((SKIP + 1))
  echo "  skip - $1 (${2:-})"
}

assert_eq() {
  # assert_eq <説明> <期待値> <実際の値>
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "expected=[${expected}] actual=[${actual}]"
  fi
}

assert_exit_code() {
  # assert_exit_code <説明> <期待する終了コード> <実際の終了コード>
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" -eq "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "expected exit=${expected} actual exit=${actual}"
  fi
}

# ---------------------------------------------------------------------------
# 一時 git リポジトリ / worktree を組み立てるヘルパ。
# 後続タスク（epic worktree / agent worktree / リポジトリ外 worktree のケース追加）で再利用する。
# 一時ディレクトリは mktemp -d 配下に限定し、削除コマンドは実行しない
# （OS のテンポラリ領域に任せる。破壊的コマンドを避けるため明示的な rm は行わない）。
# ---------------------------------------------------------------------------

make_temp_repo() {
  # 新規の一時 git リポジトリを作り、初回コミットまで済ませてパスを返す。
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-repo.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email "dev-workflow-test@example.com"
    git config user.name "dev-workflow test"
    printf 'test repo\n' > README.md
    git add README.md
    git commit -q -m "init"
  ) >/dev/null 2>&1
  printf '%s' "$dir"
}

make_worktree() {
  # make_worktree <repo_dir> <worktree_dir> <branch>
  # repo_dir に対して worktree_dir へ新しいブランチの worktree を追加する。
  local repo_dir="$1" worktree_dir="$2" branch="$3"
  (
    cd "$repo_dir" || exit 1
    git worktree add -q -b "$branch" "$worktree_dir"
  ) >/dev/null 2>&1
}

copy_sandbox_scripts() {
  # copy_sandbox_scripts <dest_repo_dir>
  # sandbox-exec.sh / resolve-sandbox.sh / lib / Dockerfile.dev を検証対象の一時リポジトリへ複製する。
  # worktree はコミット済みの内容しか見えないため、複製後にコミットまで済ませる
  # （worktree からもスクリプトを実行できるようにするため）。
  local dest="$1"
  mkdir -p "${dest}/scripts/lib"
  cp "${REPO_ROOT}/scripts/sandbox-exec.sh"    "${dest}/scripts/sandbox-exec.sh"
  cp "${REPO_ROOT}/scripts/resolve-sandbox.sh" "${dest}/scripts/resolve-sandbox.sh"
  cp "${REPO_ROOT}/scripts/lib/container-membership.sh" "${dest}/scripts/lib/container-membership.sh"
  cp "${REPO_ROOT}/scripts/lib/compose-conflicts.sh"    "${dest}/scripts/lib/compose-conflicts.sh"
  cp "${REPO_ROOT}/Dockerfile.dev"             "${dest}/Dockerfile.dev"
  (
    cd "$dest" || exit 1
    git add scripts Dockerfile.dev
    git commit -q -m "add sandbox scripts"
  ) >/dev/null 2>&1
}

copy_sandbox_scripts_no_dockerfile() {
  # copy_sandbox_scripts_no_dockerfile <dest_repo_dir>
  # compose モード検証用。Dockerfile.dev を置かないことで resolve-sandbox.sh が
  # compose モードを解決するようにする（Dockerfile.dev が優先されてしまうため）。
  local dest="$1"
  mkdir -p "${dest}/scripts/lib"
  cp "${REPO_ROOT}/scripts/sandbox-exec.sh"    "${dest}/scripts/sandbox-exec.sh"
  cp "${REPO_ROOT}/scripts/resolve-sandbox.sh" "${dest}/scripts/resolve-sandbox.sh"
  cp "${REPO_ROOT}/scripts/lib/container-membership.sh" "${dest}/scripts/lib/container-membership.sh"
  cp "${REPO_ROOT}/scripts/lib/compose-conflicts.sh"    "${dest}/scripts/lib/compose-conflicts.sh"
  (
    cd "$dest" || exit 1
    git add scripts
    git commit -q -m "add sandbox scripts (no dockerfile)"
  ) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# ケース1: 全 scripts/*.sh に対する bash -n（構文チェック）
# ---------------------------------------------------------------------------

echo "== bash -n（構文チェック） =="

for script in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
  name="$(basename "$script")"
  bashn_out="$(bash -n "$script" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "bash -n: ${name}"
  else
    fail "bash -n: ${name}" "$bashn_out"
  fi
done

# ---------------------------------------------------------------------------
# ケース2: shellcheck（あれば実行。無ければ skip 扱いで通す）
# ---------------------------------------------------------------------------

echo "== shellcheck（利用可能な場合のみ） =="

if command -v shellcheck >/dev/null 2>&1; then
  # -x: sandbox-exec.sh は変数（${SCRIPT_DIR}）経由で scripts/lib/*.sh を source する。
  # shellcheck はデフォルトでは変数経由の source 先を検証しない（SC1091）ため、
  # severity を下げるのではなく -x で実際に解決させて検証の穴を作らないようにする。
  for script in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
    name="$(basename "$script")"
    shellcheck_out="$(cd "$(dirname "$script")" && shellcheck -x "$(basename "$script")" 2>&1)"
    if [ $? -eq 0 ]; then
      pass "shellcheck: ${name}"
    else
      fail "shellcheck: ${name}" "$shellcheck_out"
    fi
  done
else
  skip "shellcheck" "コマンドが見つからないためスキップ"
fi

# ---------------------------------------------------------------------------
# ケース3: --print-plan がドライランであること（docker を一切呼ばない）
# ---------------------------------------------------------------------------

echo "== --print-plan（ドライラン） =="

PRINT_PLAN_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$PRINT_PLAN_REPO"

# 実際に docker を呼んでいないことを検出するため、docker という名前の偽コマンドを
# PATH の先頭に置き、呼ばれたらマーカーファイルを残して失敗させる。
FAKE_BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin.XXXXXX")"
DOCKER_CALLED_MARKER="${FAKE_BIN_DIR}/docker-called-marker"
cat > "${FAKE_BIN_DIR}/docker" <<'FAKE_DOCKER'
#!/bin/bash
echo "$@" >> "${DOCKER_CALLED_MARKER}"
exit 1
FAKE_DOCKER
chmod +x "${FAKE_BIN_DIR}/docker"

PRINT_PLAN_OUTPUT="$(
  cd "$PRINT_PLAN_REPO" || exit 1
  DOCKER_CALLED_MARKER="$DOCKER_CALLED_MARKER" PATH="${FAKE_BIN_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --print-plan
)"
PRINT_PLAN_EXIT=$?

assert_exit_code "--print-plan は exit 0 で終わる" 0 "$PRINT_PLAN_EXIT"

if [ -f "$DOCKER_CALLED_MARKER" ]; then
  fail "--print-plan は docker を起動しない" "docker が呼ばれました: $(cat "$DOCKER_CALLED_MARKER")"
else
  pass "--print-plan は docker を起動しない"
fi

get_plan_value() {
  # get_plan_value <key>  出力から key=value の value 部分（先頭一致1件）を取り出す
  printf '%s\n' "$PRINT_PLAN_OUTPUT" | grep "^${1}=" | head -n1 | cut -d'=' -f2-
}

REPO_BASENAME="$(basename "$PRINT_PLAN_REPO")"

assert_eq "mode=dockerfile" "dockerfile" "$(get_plan_value mode)"
assert_eq "repo は一時リポジトリのディレクトリ名と一致" "$REPO_BASENAME" "$(get_plan_value repo)"
assert_eq "epic 未指定時は空" "" "$(get_plan_value epic)"
assert_eq "mount_target は /workspace" "/workspace" "$(get_plan_value mount_target)"
assert_eq "workdir は /workspace" "/workspace" "$(get_plan_value workdir)"
assert_eq "container はリポジトリ名から決まる" "dw-sandbox-${REPO_BASENAME}" "$(get_plan_value container)"

# image はリポジトリ名 + Dockerfile.dev 内容の hash8（Task #8、仕様書 4.7）で決まる。
# hash8 の具体的な値は Dockerfile.dev の内容依存のため、ここではプレフィックスと
# 末尾8文字が16進数であることだけを確認する（内容変更への追随はケース7で検証する）。
IMAGE_VALUE="$(get_plan_value image)"
case "$IMAGE_VALUE" in
  "dev-sandbox:${REPO_BASENAME}-"*) pass "image はリポジトリ名+hash8のプレフィックスを持つ" ;;
  *) fail "image はリポジトリ名+hash8のプレフィックスを持つ" "image=[${IMAGE_VALUE}]" ;;
esac

IMAGE_HASH_SUFFIX="${IMAGE_VALUE: -8}"
case "$IMAGE_HASH_SUFFIX" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    pass "image の末尾8文字が16進数のhashである" ;;
  *)
    fail "image の末尾8文字が16進数のhashである" "suffix=[${IMAGE_HASH_SUFFIX}]" ;;
esac

assert_eq "dockerfile は Dockerfile.dev" "Dockerfile.dev" "$(get_plan_value dockerfile)"

BUILD_CONTEXT_VALUE="$(get_plan_value build_context)"
case "$BUILD_CONTEXT_VALUE" in
  *"$REPO_BASENAME") pass "--print-plan に build_context が出る（一時リポジトリを指す）" ;;
  *) fail "--print-plan に build_context が出る（一時リポジトリを指す）" "build_context=[${BUILD_CONTEXT_VALUE}]" ;;
esac

# mount_source はこのケースでは一時リポジトリのパス（pwd -W 相当）を指すはず。
MOUNT_SOURCE="$(get_plan_value mount_source)"
case "$MOUNT_SOURCE" in
  *"$REPO_BASENAME") pass "mount_source が一時リポジトリを指す" ;;
  *) fail "mount_source が一時リポジトリを指す" "mount_source=[${MOUNT_SOURCE}]" ;;
esac

# cache_volume が複数行、key=value:path 形式で出ていることを確認する。
CACHE_VOLUME_COUNT="$(printf '%s\n' "$PRINT_PLAN_OUTPUT" | grep -c '^cache_volume=')"
if [ "$CACHE_VOLUME_COUNT" -gt 0 ]; then
  pass "cache_volume が1件以上出力される（${CACHE_VOLUME_COUNT}件）"
else
  fail "cache_volume が1件以上出力される" "0件でした"
fi

FIRST_CACHE_LINE="$(printf '%s\n' "$PRINT_PLAN_OUTPUT" | grep '^cache_volume=' | head -n1)"
case "$FIRST_CACHE_LINE" in
  cache_volume=dw-cache-"${REPO_BASENAME}"-*:*) pass "cache_volume の命名がリポジトリ単位である" ;;
  *) fail "cache_volume の命名がリポジトリ単位である" "実際の1行目: ${FIRST_CACHE_LINE}" ;;
esac

# --epic 指定時にコンテナ名へ反映されることも、この段階の挙動として確認しておく。
PRINT_PLAN_EPIC_OUTPUT="$(
  cd "$PRINT_PLAN_REPO" || exit 1
  DOCKER_CALLED_MARKER="$DOCKER_CALLED_MARKER" PATH="${FAKE_BIN_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --epic epic999 --print-plan
)"
EPIC_CONTAINER="$(printf '%s\n' "$PRINT_PLAN_EPIC_OUTPUT" | grep '^container=' | cut -d'=' -f2-)"
assert_eq "--epic 指定時はコンテナ名に反映される" "dw-sandbox-${REPO_BASENAME}-epic999" "$EPIC_CONTAINER"

if [ -f "$DOCKER_CALLED_MARKER" ]; then
  fail "--epic 付き --print-plan も docker を起動しない" "docker が呼ばれました: $(cat "$DOCKER_CALLED_MARKER")"
else
  pass "--epic 付き --print-plan も docker を起動しない"
fi

# ---------------------------------------------------------------------------
# ケース1〜6: パス解決とコンテナ名の一致（Epic #3 仕様書「5. 検証方針」のケース1〜6、Task #5）
#
# バインドマウント先をリポジトリルートに固定し、コンテナを epic 単位にする変更の検証。
# リポジトリルート / epic worktree / agent worktree のいずれから叩いても
# container が完全に一致し、workdir だけが相対パス分だけ変わることを確認する。
# ---------------------------------------------------------------------------

echo "== パス解決とコンテナ名（ケース1〜6） =="

plan_value() {
  # plan_value <key> <output>  出力から key=value の value 部分（先頭一致1件）を取り出す
  printf '%s\n' "$2" | grep "^${1}=" | head -n1 | cut -d'=' -f2-
}

print_plan_in() {
  # print_plan_in <dir> [追加の引数...]  <dir> で --print-plan を実行し出力全体を返す
  local dir="$1"
  shift
  (
    cd "$dir" || exit 1
    PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan "$@"
  )
}

# --- ケース1: リポジトリルートから ---
CASE1_OUTPUT="$(print_plan_in "$PRINT_PLAN_REPO")"

assert_eq "ケース1: rel_path は空" "" "$(plan_value rel_path "$CASE1_OUTPUT")"
assert_eq "ケース1: fallback は0" "0" "$(plan_value fallback "$CASE1_OUTPUT")"
assert_eq "ケース1: workdir は /workspace" "/workspace" "$(plan_value workdir "$CASE1_OUTPUT")"

CASE1_CONTAINER="$(plan_value container "$CASE1_OUTPUT")"

# --- ケース2: epic worktree（.claude/worktrees/epicN）から ---
EPIC_WORKTREE_DIR="${PRINT_PLAN_REPO}/.claude/worktrees/epic5"
make_worktree "$PRINT_PLAN_REPO" "$EPIC_WORKTREE_DIR" "epic-worktree-branch"

CASE2_OUTPUT="$(print_plan_in "$EPIC_WORKTREE_DIR")"

assert_eq "ケース2: rel_path は .claude/worktrees/epic5" ".claude/worktrees/epic5" "$(plan_value rel_path "$CASE2_OUTPUT")"
assert_eq "ケース2: workdir は相対パス" "/workspace/.claude/worktrees/epic5" "$(plan_value workdir "$CASE2_OUTPUT")"
assert_eq "ケース2: container はルート実行時と同一" "$CASE1_CONTAINER" "$(plan_value container "$CASE2_OUTPUT")"

# --- ケース3: agent worktree（.claude/worktrees/agent-x）から ---
AGENT_WORKTREE_DIR="${PRINT_PLAN_REPO}/.claude/worktrees/agent-x"
make_worktree "$PRINT_PLAN_REPO" "$AGENT_WORKTREE_DIR" "agent-worktree-branch"

CASE3_OUTPUT="$(print_plan_in "$AGENT_WORKTREE_DIR")"

assert_eq "ケース3: rel_path は .claude/worktrees/agent-x" ".claude/worktrees/agent-x" "$(plan_value rel_path "$CASE3_OUTPUT")"
assert_eq "ケース3: workdir は相対パス" "/workspace/.claude/worktrees/agent-x" "$(plan_value workdir "$CASE3_OUTPUT")"
assert_eq "ケース3: container はケース1・2と同一" "$CASE1_CONTAINER" "$(plan_value container "$CASE3_OUTPUT")"

# --- ケース4: --epic 無し + DEV_WORKFLOW_EPIC あり ---
CASE4_OUTPUT="$(
  cd "$PRINT_PLAN_REPO" || exit 1
  DEV_WORKFLOW_EPIC=epic777 PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
assert_eq "ケース4: DEV_WORKFLOW_EPIC がコンテナ名に反映される" "${CASE1_CONTAINER}-epic777" "$(plan_value container "$CASE4_OUTPUT")"
assert_eq "ケース4: epic の値も DEV_WORKFLOW_EPIC になる" "epic777" "$(plan_value epic "$CASE4_OUTPUT")"

# --- ケース5: リポジトリ外の worktree（フォールバック） ---
OUTSIDE_WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-outside.XXXXXX")"
make_worktree "$PRINT_PLAN_REPO" "$OUTSIDE_WORKTREE_DIR" "outside-worktree-branch"

CASE5_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-case5-stderr.XXXXXX")"
CASE5_OUTPUT="$(
  cd "$OUTSIDE_WORKTREE_DIR" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan 2>"$CASE5_STDERR"
)"

assert_eq "ケース5: fallback は1" "1" "$(plan_value fallback "$CASE5_OUTPUT")"

CASE5_CONTAINER="$(plan_value container "$CASE5_OUTPUT")"
if [ "$CASE5_CONTAINER" != "$CASE1_CONTAINER" ]; then
  pass "ケース5: container がリポジトリ共有コンテナと分離される"
else
  fail "ケース5: container がリポジトリ共有コンテナと分離される" "container=[${CASE5_CONTAINER}]（共有コンテナと同一でした）"
fi

if [ -s "$CASE5_STDERR" ]; then
  pass "ケース5: フォールバック時に stderr へ警告する"
else
  fail "ケース5: フォールバック時に stderr へ警告する" "stderr が空でした"
fi

# --- ケース6: キャッシュ volume 名がリポジトリ単位である（worktree から叩いても変わらない） ---
CASE1_CACHE="$(plan_value cache_volume "$CASE1_OUTPUT")"
CASE3_CACHE="$(plan_value cache_volume "$CASE3_OUTPUT")"
assert_eq "ケース6: cache_volume はリポジトリ単位（worktree から叩いても同じ）" "$CASE1_CACHE" "$CASE3_CACHE"

# ---------------------------------------------------------------------------
# ケース7: container_belongs_to_repo（Docker 非依存の所属判定関数、Task #6）
#
# label あり／label なしの旧命名残骸／他リポジトリの3パターンを、docker を一切
# 起動せずに純粋関数として直接検証する。
# ---------------------------------------------------------------------------

echo "== container_belongs_to_repo（所属判定・Docker 非依存） =="

# shellcheck source=../scripts/lib/container-membership.sh
. "${REPO_ROOT}/scripts/lib/container-membership.sh"

HOST_ROOT_SAMPLE="/home/user/repo"

if container_belongs_to_repo "myrepo" "" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label の repo が一致すれば対象に含まれる"
else
  fail "label の repo が一致すれば対象に含まれる"
fi

if container_belongs_to_repo "otherrepo" "${HOST_ROOT_SAMPLE}/anything" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label の repo が不一致なら対象に含まれない" "含まれてしまいました（マウント元が一致していても label 不一致を優先すべき）"
else
  pass "label の repo が不一致なら対象に含まれない"
fi

if container_belongs_to_repo "" "${HOST_ROOT_SAMPLE}/.claude/worktrees/agent-old" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label なし・マウント元がリポジトリルート配下なら対象に含まれる（旧命名の残骸回収）"
else
  fail "label なし・マウント元がリポジトリルート配下なら対象に含まれる"
fi

if container_belongs_to_repo "" "$HOST_ROOT_SAMPLE" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label なし・マウント元がリポジトリルート自身でも対象に含まれる"
else
  fail "label なし・マウント元がリポジトリルート自身でも対象に含まれる"
fi

if container_belongs_to_repo "" "/home/user/other-repo/subdir" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label なし・マウント元が別リポジトリなら対象に含まれない" "含まれてしまいました"
else
  pass "label なし・マウント元が別リポジトリなら対象に含まれない"
fi

if container_belongs_to_repo "" "" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label もマウント元も無ければ対象に含まれない" "含まれてしまいました"
else
  pass "label もマウント元も無ければ対象に含まれない"
fi

# ---------------------------------------------------------------------------
# ケース8: --ls / --down --all（偽 docker で label・マウント元を注入し、実際の docker を起動せず検証する）
#
# 偽 docker は DW_TEST_MANIFEST（name|managed|repo|epic|image|status|created|mount_source
# の '|' 区切り行）を読み、docker ps / docker container inspect / docker rm を模擬する。
# `docker rm` は本物を一切呼ばず、DW_TEST_RM_LOG に対象名を追記するだけにする。
# ---------------------------------------------------------------------------

echo "== --ls / --down --all（偽 docker） =="

LS_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$LS_REPO"

LS_PLAN_OUTPUT="$(
  cd "$LS_REPO" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
LS_REPO_BASENAME="$(basename "$LS_REPO")"
LS_HOST_ROOT="$(plan_value repo_root "$LS_PLAN_OUTPUT")"

DW_TEST_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/dw-test-manifest.XXXXXX")"
DW_TEST_RM_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-rmlog.XXXXXX")"
: > "$DW_TEST_RM_LOG"

# 1) label ありで現リポジトリに属するコンテナ（現行の起動中コンテナを模す）
# 2) label なしの旧命名残骸で、マウント元が現リポジトリのルート配下（回収されるべき）
# 3) label ありで他リポジトリに属するコンテナ（--down --all の対象に含まれてはいけない）
# 4) label なしで、マウント元が他リポジトリ配下（対象に含まれてはいけない）
cat > "$DW_TEST_MANIFEST" <<MANIFEST
dw-sandbox-${LS_REPO_BASENAME}|1|${LS_REPO_BASENAME}||dev-sandbox:${LS_REPO_BASENAME}|running|2024-01-01T00:00:00Z|${LS_HOST_ROOT}
dw-sandbox-${LS_REPO_BASENAME}-legacy|||||exited|2023-01-01T00:00:00Z|${LS_HOST_ROOT}/.claude/worktrees/agent-old
dw-sandbox-otherrepo|1|otherrepo||dev-sandbox:otherrepo|running|2024-02-02T00:00:00Z|/home/user/otherrepo
dw-sandbox-otherrepo-legacy|||||exited|2023-03-03T00:00:00Z|/home/user/otherrepo/subdir
MANIFEST

FAKE_DOCKER_MANIFEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin-manifest.XXXXXX")"
cat > "${FAKE_DOCKER_MANIFEST_DIR}/docker" <<'FAKE_DOCKER_MANIFEST'
#!/bin/bash
# tests/run-tests.sh 用の偽 docker（マニフェスト駆動）。ps / container inspect / rm / volume rm に対応する。
set -u
MANIFEST="${DW_TEST_MANIFEST:?DW_TEST_MANIFEST is required}"

manifest_line() {
  awk -F'|' -v n="$1" '$1==n{print; exit}' "$MANIFEST"
}

case "${1:-}" in
  ps)
    shift
    filter=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --filter) filter="$2"; shift 2 ;;
        --format) shift 2 ;;
        *) shift ;;
      esac
    done
    case "$filter" in
      "label=dev-workflow.managed=1")
        awk -F'|' '$2=="1"{print $1}' "$MANIFEST"
        ;;
      "name=dw-sandbox-")
        awk -F'|' '$1 ~ /dw-sandbox-/{print $1}' "$MANIFEST"
        ;;
    esac
    exit 0
    ;;
  container)
    shift
    [ "${1:-}" = "inspect" ] || exit 1
    shift
    tmpl=""
    name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) tmpl="$2"; shift 2 ;;
        *) name="$1"; shift ;;
      esac
    done
    line="$(manifest_line "$name")"
    [ -n "$line" ] || exit 1
    IFS='|' read -r f_name f_managed f_repo f_epic f_image f_status f_created f_mount <<< "$line"
    case "$tmpl" in
      *'dev-workflow.repo'*) printf '%s\n' "$f_repo" ;;
      *'dev-workflow.epic'*) printf '%s\n' "$f_epic" ;;
      *'Mounts'*)            printf '%s\n' "$f_mount" ;;
      *'Config.Image'*)      printf '%s\n' "$f_image" ;;
      *'State.Status'*)      printf '%s\n' "$f_status" ;;
      *'State.Running'*)
        if [ "$f_status" = "running" ]; then printf 'true\n'; else printf 'false\n'; fi
        ;;
      *'Created'*)           printf '%s\n' "$f_created" ;;
      *)                     printf '\n' ;;
    esac
    exit 0
    ;;
  rm)
    shift
    target=""
    for a in "$@"; do
      case "$a" in
        -f) ;;
        *) target="$a" ;;
      esac
    done
    echo "$target" >> "${DW_TEST_RM_LOG:?DW_TEST_RM_LOG is required}"
    exit 0
    ;;
  volume)
    shift
    [ "${1:-}" = "rm" ] || exit 1
    shift
    for a in "$@"; do
      echo "$a" >> "${DW_TEST_VOLUME_RM_LOG:?DW_TEST_VOLUME_RM_LOG is required}"
    done
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
FAKE_DOCKER_MANIFEST
chmod +x "${FAKE_DOCKER_MANIFEST_DIR}/docker"

# --- --ls: 他リポジトリの管理コンテナも含めて一覧表示する ---
LS_OUTPUT="$(
  cd "$LS_REPO" || exit 1
  DW_TEST_MANIFEST="$DW_TEST_MANIFEST" PATH="${FAKE_DOCKER_MANIFEST_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --ls
)"

case "$LS_OUTPUT" in
  *"dw-sandbox-${LS_REPO_BASENAME}"*"dw-sandbox-otherrepo"*|*"dw-sandbox-otherrepo"*"dw-sandbox-${LS_REPO_BASENAME}"*)
    pass "--ls は自リポジトリと他リポジトリの管理コンテナを両方表示する"
    ;;
  *)
    fail "--ls は自リポジトリと他リポジトリの管理コンテナを両方表示する" "output=[${LS_OUTPUT}]"
    ;;
esac

if printf '%s\n' "$LS_OUTPUT" | grep -q "dw-sandbox-${LS_REPO_BASENAME}-legacy"; then
  pass "--ls は label なしの旧命名残骸も表示する"
else
  fail "--ls は label なしの旧命名残骸も表示する" "output=[${LS_OUTPUT}]"
fi

# --- --down --all: 削除前に対象名を列挙し、自リポジトリ分のみ削除する ---
: > "$DW_TEST_RM_LOG"
DOWN_ALL_OUTPUT="$(
  cd "$LS_REPO" || exit 1
  DW_TEST_MANIFEST="$DW_TEST_MANIFEST" DW_TEST_RM_LOG="$DW_TEST_RM_LOG" \
    PATH="${FAKE_DOCKER_MANIFEST_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --down --all
)"

if printf '%s\n' "$DOWN_ALL_OUTPUT" | grep -q "dw-sandbox-${LS_REPO_BASENAME}$"; then
  pass "--down --all は削除前に label ありの自リポジトリコンテナ名を列挙する"
else
  fail "--down --all は削除前に label ありの自リポジトリコンテナ名を列挙する" "output=[${DOWN_ALL_OUTPUT}]"
fi

if printf '%s\n' "$DOWN_ALL_OUTPUT" | grep -q "dw-sandbox-${LS_REPO_BASENAME}-legacy"; then
  pass "--down --all は削除前に label なしの旧命名残骸（マウント元一致）も列挙する"
else
  fail "--down --all は削除前に label なしの旧命名残骸（マウント元一致）も列挙する" "output=[${DOWN_ALL_OUTPUT}]"
fi

if printf '%s\n' "$DOWN_ALL_OUTPUT" | grep -q "otherrepo"; then
  fail "--down --all は他リポジトリのコンテナを列挙しない" "output=[${DOWN_ALL_OUTPUT}]"
else
  pass "--down --all は他リポジトリのコンテナを列挙しない"
fi

RM_LOG_CONTENT="$(cat "$DW_TEST_RM_LOG")"
RM_LOG_COUNT="$(printf '%s\n' "$RM_LOG_CONTENT" | grep -c . || true)"
assert_eq "--down --all は自リポジトリ分の2件だけを docker rm する" "2" "$RM_LOG_COUNT"

if printf '%s\n' "$RM_LOG_CONTENT" | grep -q "otherrepo"; then
  fail "--down --all は他リポジトリのコンテナを削除しない" "rm_log=[${RM_LOG_CONTENT}]"
else
  pass "--down --all は他リポジトリのコンテナを削除しない"
fi

# ---------------------------------------------------------------------------
# ケース9: --reset-cache のガード（列挙・running 検出・--force。Task #7、Epic #3 仕様書 4.6）
#
# キャッシュ volume はリポジトリ単位で共有するため、running 判定は現在の epic だけでなく
# 同一リポジトリの管理コンテナ全体（他 epic のものも含む）を対象にする。--ls / --down --all
# と同じ偽 docker（マニフェスト駆動、State.Running / volume rm に対応済み）を再利用する。
# ---------------------------------------------------------------------------

echo "== --reset-cache（列挙・running 検出・--force。Task #7） =="

RESET_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$RESET_REPO"

RESET_PLAN_OUTPUT="$(
  cd "$RESET_REPO" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
RESET_REPO_BASENAME="$(basename "$RESET_REPO")"
RESET_HOST_ROOT="$(plan_value repo_root "$RESET_PLAN_OUTPUT")"
RESET_CACHE_VOLUME_COUNT="$(printf '%s\n' "$RESET_PLAN_OUTPUT" | grep -c '^cache_volume=')"

DW_TEST_VOLUME_RM_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-volrmlog.XXXXXX")"
: > "$DW_TEST_VOLUME_RM_LOG"

run_reset_cache() {
  # run_reset_cache <manifest内容> [追加の引数...]
  local manifest_body="$1"
  shift
  printf '%s\n' "$manifest_body" > "$DW_TEST_MANIFEST"
  : > "$DW_TEST_RM_LOG"
  : > "$DW_TEST_VOLUME_RM_LOG"
  (
    cd "$RESET_REPO" || exit 1
    DW_TEST_MANIFEST="$DW_TEST_MANIFEST" DW_TEST_RM_LOG="$DW_TEST_RM_LOG" \
      DW_TEST_VOLUME_RM_LOG="$DW_TEST_VOLUME_RM_LOG" \
      PATH="${FAKE_DOCKER_MANIFEST_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh --reset-cache "$@"
  )
}

# --- 常に: 削除対象 volume がすべて列挙表示される（実行結果の成否によらない） ---
NOT_RUNNING_MANIFEST="dw-sandbox-${RESET_REPO_BASENAME}-epicA|1|${RESET_REPO_BASENAME}|epicA|dev-sandbox:${RESET_REPO_BASENAME}|exited|2024-01-01T00:00:00Z|${RESET_HOST_ROOT}"

RESET_ENUM_OUTPUT="$(run_reset_cache "$NOT_RUNNING_MANIFEST" 2>&1)"
NOT_RUNNING_EXIT=$?
RESET_ENUM_LISTED_COUNT="$(printf '%s\n' "$RESET_ENUM_OUTPUT" | grep -c '^  - dw-cache-')"
assert_eq "--reset-cache は削除対象 volume をすべて列挙表示する" "$RESET_CACHE_VOLUME_COUNT" "$RESET_ENUM_LISTED_COUNT"

# --- 同一リポジトリのコンテナが running でないときは --force なしでも実行される ---
if [ "$NOT_RUNNING_EXIT" -eq 0 ]; then
  pass "同一リポジトリのコンテナが running でないとき --force なしでも成功する"
else
  fail "同一リポジトリのコンテナが running でないとき --force なしでも成功する" "exit=${NOT_RUNNING_EXIT}"
fi

VOL_RM_COUNT="$(grep -c . "$DW_TEST_VOLUME_RM_LOG" || true)"
assert_eq "running でないとき docker volume rm が volume 数だけ呼ばれる" "$RESET_CACHE_VOLUME_COUNT" "$VOL_RM_COUNT"

# --- 同一リポジトリの管理コンテナ（他 epic）が running なら --force なしでは中断する ---
RUNNING_OWN_REPO_MANIFEST="dw-sandbox-${RESET_REPO_BASENAME}-epicA|1|${RESET_REPO_BASENAME}|epicA|dev-sandbox:${RESET_REPO_BASENAME}|running|2024-01-01T00:00:00Z|${RESET_HOST_ROOT}"

RESET_BLOCK_STDERR="$(run_reset_cache "$RUNNING_OWN_REPO_MANIFEST" 2>&1 1>/dev/null)"
RESET_BLOCK_EXIT=$?

if [ "$RESET_BLOCK_EXIT" -ne 0 ]; then
  pass "同一リポジトリの他 epic コンテナが running なら --force なしでは非0で終了する"
else
  fail "同一リポジトリの他 epic コンテナが running なら --force なしでは非0で終了する" "exit=0"
fi

VOL_RM_COUNT_BLOCKED="$(grep -c . "$DW_TEST_VOLUME_RM_LOG" || true)"
assert_eq "running のとき --force なしでは docker volume rm を呼ばない" "0" "$VOL_RM_COUNT_BLOCKED"

case "$RESET_BLOCK_STDERR" in
  *"dw-sandbox-${RESET_REPO_BASENAME}-epicA"*) pass "中断メッセージに running なコンテナ名が含まれる" ;;
  *) fail "中断メッセージに running なコンテナ名が含まれる" "stderr=[${RESET_BLOCK_STDERR}]" ;;
esac

case "$RESET_BLOCK_STDERR" in
  *"--force"*) pass "中断メッセージに --force の案内が含まれる" ;;
  *) fail "中断メッセージに --force の案内が含まれる" "stderr=[${RESET_BLOCK_STDERR}]" ;;
esac

# --- --force 指定時は running でも実行される ---
RESET_FORCE_EXIT_OUTPUT="$(run_reset_cache "$RUNNING_OWN_REPO_MANIFEST" --force 2>&1)"
RESET_FORCE_EXIT=$?

if [ "$RESET_FORCE_EXIT" -eq 0 ]; then
  pass "--force 指定時は running でも成功する"
else
  fail "--force 指定時は running でも成功する" "exit=${RESET_FORCE_EXIT} output=[${RESET_FORCE_EXIT_OUTPUT}]"
fi

VOL_RM_COUNT_FORCED="$(grep -c . "$DW_TEST_VOLUME_RM_LOG" || true)"
assert_eq "--force 指定時は docker volume rm が volume 数だけ呼ばれる" "$RESET_CACHE_VOLUME_COUNT" "$VOL_RM_COUNT_FORCED"

# --- 別リポジトリのコンテナが running でも中断しない（誤って巻き込まない） ---
OTHER_REPO_RUNNING_MANIFEST="dw-sandbox-otherrepo|1|otherrepo||dev-sandbox:otherrepo|running|2024-02-02T00:00:00Z|/home/user/otherrepo"

RESET_OTHER_REPO_OUTPUT="$(run_reset_cache "$OTHER_REPO_RUNNING_MANIFEST" 2>&1)"
RESET_OTHER_REPO_EXIT=$?

if [ "$RESET_OTHER_REPO_EXIT" -eq 0 ]; then
  pass "別リポジトリのコンテナが running でも中断しない"
else
  fail "別リポジトリのコンテナが running でも中断しない" "exit=${RESET_OTHER_REPO_EXIT} output=[${RESET_OTHER_REPO_OUTPUT}]"
fi

# --- ヘルプに作用範囲（リポジトリ全体）の記載がある ---
SANDBOX_EXEC_HEADER="$(sed -n '1,25p' "${REPO_ROOT}/scripts/sandbox-exec.sh")"
case "$SANDBOX_EXEC_HEADER" in
  *"リポジトリ全体"*) pass "ヘッダコメントに --reset-cache の作用範囲（リポジトリ全体）の記載がある" ;;
  *) fail "ヘッダコメントに --reset-cache の作用範囲（リポジトリ全体）の記載がある" "header=[${SANDBOX_EXEC_HEADER}]" ;;
esac

case "$RESET_BLOCK_STDERR" in
  *"リポジトリ全体"*) pass "中断メッセージにも作用範囲（リポジトリ全体）の記載がある" ;;
  *) fail "中断メッセージにも作用範囲（リポジトリ全体）の記載がある" "stderr=[${RESET_BLOCK_STDERR}]" ;;
esac

# ---------------------------------------------------------------------------
# ケース7: イメージタグの hash 依存性（Task #8、Epic #3 仕様書「5. 検証方針」ケース7）
#
# Dockerfile.dev の内容を変更するとタグの hash 部分（末尾8文字）が変わり、内容が同じなら
# 別リポジトリでも hash が変わらないことを確認する。
# ---------------------------------------------------------------------------

echo "== イメージタグの hash 依存性（ケース7、Task #8） =="

IMG_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$IMG_REPO"

IMG_PLAN_OUTPUT="$(
  cd "$IMG_REPO" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
IMG_IMAGE="$(plan_value image "$IMG_PLAN_OUTPUT")"
IMG_DOCKERFILE="$(plan_value dockerfile "$IMG_PLAN_OUTPUT")"
IMG_BUILD_CONTEXT="$(plan_value build_context "$IMG_PLAN_OUTPUT")"
IMG_CONTAINER="$(plan_value container "$IMG_PLAN_OUTPUT")"
IMG_MOUNT_SOURCE="$(plan_value mount_source "$IMG_PLAN_OUTPUT")"
IMG_HASH_BEFORE="${IMG_IMAGE: -8}"

# --- Dockerfile.dev の内容を変更してコミットすると hash（タグの末尾8文字）が変わる ---
printf '\n# case7 marker\n' >> "${IMG_REPO}/Dockerfile.dev"
(
  cd "$IMG_REPO" || exit 1
  git add Dockerfile.dev
  git commit -q -m "case7: change Dockerfile.dev"
) >/dev/null 2>&1

IMG_PLAN_AFTER_CHANGE="$(
  cd "$IMG_REPO" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
IMG_IMAGE_AFTER_CHANGE="$(plan_value image "$IMG_PLAN_AFTER_CHANGE")"
IMG_HASH_AFTER_CHANGE="${IMG_IMAGE_AFTER_CHANGE: -8}"

if [ "$IMG_HASH_BEFORE" != "$IMG_HASH_AFTER_CHANGE" ]; then
  pass "ケース7: Dockerfile.dev の内容変更でタグの hash が変わる"
else
  fail "ケース7: Dockerfile.dev の内容変更でタグの hash が変わる" "hash が変わりませんでした: ${IMG_HASH_BEFORE}"
fi

# 以降の自動ビルド系テストは、この時点（Dockerfile.dev 変更後）の IMG_REPO を使い回す。
# resolve-sandbox.sh の出力は Dockerfile.dev の内容に追随するため、変更後の値で
# 上書きしておかないと docker build の実引数と食い違う。
IMG_IMAGE="$(plan_value image "$IMG_PLAN_AFTER_CHANGE")"
IMG_DOCKERFILE="$(plan_value dockerfile "$IMG_PLAN_AFTER_CHANGE")"
IMG_BUILD_CONTEXT="$(plan_value build_context "$IMG_PLAN_AFTER_CHANGE")"
IMG_CONTAINER="$(plan_value container "$IMG_PLAN_AFTER_CHANGE")"
IMG_MOUNT_SOURCE="$(plan_value mount_source "$IMG_PLAN_AFTER_CHANGE")"

# --- 内容が同じなら別リポジトリ（worktree 相当）でも hash が変わらない ---
IMG_REPO2="$(make_temp_repo)"
copy_sandbox_scripts "$IMG_REPO2"

IMG_PLAN2_OUTPUT="$(
  cd "$IMG_REPO2" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
IMG_HASH2="$(plan_value image "$IMG_PLAN2_OUTPUT")"
IMG_HASH2="${IMG_HASH2: -8}"

assert_eq "ケース7: 内容が同じなら別リポジトリでも hash が変わらない" "$IMG_HASH_BEFORE" "$IMG_HASH2"

# ---------------------------------------------------------------------------
# 自動ビルド・--rebuild・イメージID差分による再作成（Task #8、Epic #3 仕様書 4.7 / 4.3 の1）
#
# 偽 docker は状態をファイルに保持し、docker build / docker rm / docker run の呼び出しを
# 実際の docker を起動せずに検証する。container の存在状態は docker rm / docker run に
# 応じて更新するため、削除後に作り直されることまで検証できる。
# ---------------------------------------------------------------------------

echo "== 自動ビルド・--rebuild・イメージID差分による再作成（Task #8） =="

FAKE_DOCKER_IMAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin-image.XXXXXX")"
cat > "${FAKE_DOCKER_IMAGE_DIR}/docker" <<'FAKE_DOCKER_IMAGE'
#!/bin/bash
# tests/run-tests.sh 用の偽 docker（イメージ解決・自動ビルド・コンテナ再作成の検証専用）。
# 実際の docker には一切触れない。呼び出し引数は DW_IMG_LOG にすべて記録する。
set -u

IMG_LOG="${DW_IMG_LOG:?DW_IMG_LOG is required}"
STATE_FILE="${DW_IMG_CONTAINER_STATE:?DW_IMG_CONTAINER_STATE is required}"          # 1=存在 0=不在
RUNNING_FILE="${DW_IMG_CONTAINER_RUNNING_STATE:?DW_IMG_CONTAINER_RUNNING_STATE is required}" # true/false
RM_LOG="${DW_IMG_RM_LOG:?DW_IMG_RM_LOG is required}"
RUN_LOG="${DW_IMG_RUN_LOG:?DW_IMG_RUN_LOG is required}"

echo "$*" >> "$IMG_LOG"

case "${1:-}" in
  image)
    shift
    [ "${1:-}" = "inspect" ] || exit 1
    shift
    tmpl=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) tmpl="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [ "${DW_IMG_IMAGE_EXISTS:-0}" = "1" ] || exit 1
    [ -n "$tmpl" ] && printf '%s\n' "${DW_IMG_IMAGE_ID:-sha256:default-image-id}"
    exit 0
    ;;
  build)
    exit "${DW_IMG_BUILD_EXIT:-0}"
    ;;
  container)
    shift
    [ "${1:-}" = "inspect" ] || exit 1
    shift
    tmpl=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) tmpl="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [ "$(cat "$STATE_FILE" 2>/dev/null)" = "1" ] || exit 1
    case "$tmpl" in
      *'Mounts'*)        printf '%s\n' "${DW_IMG_CONTAINER_MOUNT:-}" ;;
      *'.Image'*)        printf '%s\n' "${DW_IMG_CONTAINER_IMAGE_ID:-}" ;;
      *'State.Running'*) cat "$RUNNING_FILE" 2>/dev/null || printf 'false\n' ;;
      '') : ;;
      *) printf '\n' ;;
    esac
    exit 0
    ;;
  run)
    echo "$*" >> "$RUN_LOG"
    printf '1' > "$STATE_FILE"
    printf 'true\n' > "$RUNNING_FILE"
    exit 0
    ;;
  start)
    printf 'true\n' > "$RUNNING_FILE"
    exit 0
    ;;
  rm)
    shift
    target=""
    for a in "$@"; do
      case "$a" in
        -f) ;;
        *)  target="$a" ;;
      esac
    done
    echo "$target" >> "$RM_LOG"
    printf '0' > "$STATE_FILE"
    exit 0
    ;;
  exec)
    shift
    cmd=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -w) shift 2 ;;
        sh) shift ;;
        -c) cmd="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    sh -c "$cmd"
    exit $?
    ;;
  *)
    exit 1
    ;;
esac
FAKE_DOCKER_IMAGE
chmod +x "${FAKE_DOCKER_IMAGE_DIR}/docker"

IMG_TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-imglog.XXXXXX")"
IMG_TEST_RM_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgrmlog.XXXXXX")"
IMG_TEST_RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgrunlog.XXXXXX")"
IMG_TEST_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgstate.XXXXXX")"
IMG_TEST_RUNNING_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgrunning.XXXXXX")"

run_img_case() {
  # run_img_case <container_exists 0/1> <container_running true/false> <container_image_id>
  #              <container_mount> <image_exists 0/1> <image_id> [追加の sandbox-exec.sh 引数...]
  local container_exists="$1" container_running="$2" container_image_id="$3" container_mount="$4"
  local image_exists="$5" image_id="$6"
  shift 6

  : > "$IMG_TEST_LOG"
  : > "$IMG_TEST_RM_LOG"
  : > "$IMG_TEST_RUN_LOG"
  printf '%s' "$container_exists" > "$IMG_TEST_STATE_FILE"
  printf '%s\n' "$container_running" > "$IMG_TEST_RUNNING_FILE"

  (
    cd "$IMG_REPO" || exit 1
    DW_IMG_LOG="$IMG_TEST_LOG" \
      DW_IMG_RM_LOG="$IMG_TEST_RM_LOG" \
      DW_IMG_RUN_LOG="$IMG_TEST_RUN_LOG" \
      DW_IMG_CONTAINER_STATE="$IMG_TEST_STATE_FILE" \
      DW_IMG_CONTAINER_RUNNING_STATE="$IMG_TEST_RUNNING_FILE" \
      DW_IMG_CONTAINER_IMAGE_ID="$container_image_id" \
      DW_IMG_CONTAINER_MOUNT="$container_mount" \
      DW_IMG_IMAGE_EXISTS="$image_exists" \
      DW_IMG_IMAGE_ID="$image_id" \
      PATH="${FAKE_DOCKER_IMAGE_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh "$@"
  )
}

# --- イメージが存在しない場合、docker build が正しい引数で呼ばれる ---
IMG_A_EXIT=0
run_img_case 0 false "" "" 0 "" 'true' >/dev/null 2>&1 || IMG_A_EXIT=$?
assert_exit_code "イメージ未存在時: 実行全体が成功する" 0 "$IMG_A_EXIT"

IMG_A_BUILD_LINE="$(grep '^build ' "$IMG_TEST_LOG" | head -n1)"
assert_eq "イメージ未存在時: docker build が正しい引数で呼ばれる" \
  "build -f ${IMG_DOCKERFILE} -t ${IMG_IMAGE} ${IMG_BUILD_CONTEXT}" "$IMG_A_BUILD_LINE"

# --- イメージが存在する場合はビルドしない ---
IMG_B_EXIT=0
run_img_case 0 false "" "" 1 "sha256:existing" 'true' >/dev/null 2>&1 || IMG_B_EXIT=$?
assert_exit_code "イメージ存在時: 実行全体が成功する" 0 "$IMG_B_EXIT"

IMG_B_BUILD_COUNT="$(grep -c '^build ' "$IMG_TEST_LOG" || true)"
assert_eq "イメージ存在時: docker build を呼ばない" "0" "$IMG_B_BUILD_COUNT"

# --- --rebuild 指定時は存在してもビルドする ---
IMG_C_EXIT=0
run_img_case 0 false "" "" 1 "sha256:existing" --rebuild 'true' >/dev/null 2>&1 || IMG_C_EXIT=$?
assert_exit_code "--rebuild 指定時: 実行全体が成功する" 0 "$IMG_C_EXIT"

IMG_C_BUILD_COUNT="$(grep -c '^build ' "$IMG_TEST_LOG" || true)"
assert_eq "--rebuild 指定時: イメージが存在してもビルドする" "1" "$IMG_C_BUILD_COUNT"

# --- DEV_WORKFLOW_DOCKER_IMAGE 指定でイメージが無い場合はビルドせずエラーで停止する ---
: > "$IMG_TEST_LOG"
: > "$IMG_TEST_RM_LOG"
: > "$IMG_TEST_RUN_LOG"
printf '0' > "$IMG_TEST_STATE_FILE"
printf 'false\n' > "$IMG_TEST_RUNNING_FILE"

EXPLICIT_IMAGE_STDERR="$(
  cd "$IMG_REPO" || exit 1
  DEV_WORKFLOW_DOCKER_IMAGE="external/image:notfound" \
    DW_IMG_LOG="$IMG_TEST_LOG" \
    DW_IMG_RM_LOG="$IMG_TEST_RM_LOG" \
    DW_IMG_RUN_LOG="$IMG_TEST_RUN_LOG" \
    DW_IMG_CONTAINER_STATE="$IMG_TEST_STATE_FILE" \
    DW_IMG_CONTAINER_RUNNING_STATE="$IMG_TEST_RUNNING_FILE" \
    DW_IMG_IMAGE_EXISTS=0 \
    PATH="${FAKE_DOCKER_IMAGE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh 'true' 2>&1 1>/dev/null
)"
EXPLICIT_IMAGE_EXIT=$?

if [ "$EXPLICIT_IMAGE_EXIT" -ne 0 ]; then
  pass "DEV_WORKFLOW_DOCKER_IMAGE 指定でイメージが無い場合は非0で終了する"
else
  fail "DEV_WORKFLOW_DOCKER_IMAGE 指定でイメージが無い場合は非0で終了する" "exit=0"
fi

EXPLICIT_IMAGE_BUILD_COUNT="$(grep -c '^build ' "$IMG_TEST_LOG" || true)"
assert_eq "DEV_WORKFLOW_DOCKER_IMAGE 指定時: イメージが無くてもビルドしない" "0" "$EXPLICIT_IMAGE_BUILD_COUNT"

case "$EXPLICIT_IMAGE_STDERR" in
  *"DEV_WORKFLOW_DOCKER_IMAGE"*"external/image:notfound"*)
    pass "DEV_WORKFLOW_DOCKER_IMAGE 指定時のエラーに取得方法の案内が含まれる" ;;
  *)
    fail "DEV_WORKFLOW_DOCKER_IMAGE 指定時のエラーに取得方法の案内が含まれる" "stderr=[${EXPLICIT_IMAGE_STDERR}]" ;;
esac

# --- 既存コンテナのイメージIDが異なれば削除して作り直す（仕様書 4.3 の1） ---
IMG_E_EXIT=0
run_img_case 1 true "sha256:old" "$IMG_MOUNT_SOURCE" 1 "sha256:new" 'true' >/dev/null 2>&1 || IMG_E_EXIT=$?
assert_exit_code "イメージID差分時: 実行全体が成功する" 0 "$IMG_E_EXIT"

IMG_E_RM_COUNT="$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "イメージID差分時: 既存コンテナが削除される" "1" "$IMG_E_RM_COUNT"

IMG_E_RUN_COUNT="$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "イメージID差分時: コンテナが作り直される" "1" "$IMG_E_RUN_COUNT"

# --- 既存コンテナのイメージIDが同じなら作り直さない ---
IMG_F_EXIT=0
run_img_case 1 true "sha256:same" "$IMG_MOUNT_SOURCE" 1 "sha256:same" 'true' >/dev/null 2>&1 || IMG_F_EXIT=$?
assert_exit_code "イメージID同一時: 実行全体が成功する" 0 "$IMG_F_EXIT"

IMG_F_RM_COUNT="$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "イメージID同一時: 既存コンテナを削除しない" "0" "$IMG_F_RM_COUNT"

IMG_F_RUN_COUNT="$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "イメージID同一時: コンテナを作り直さない" "0" "$IMG_F_RUN_COUNT"

# ---------------------------------------------------------------------------
# ケース10: compose_conflict_warnings（Docker 非依存の衝突検出関数、Task #9）
#
# container_name / 固定ホストポートの検出を、docker を一切起動せずに純粋関数として
# 直接検証する（Epic #3 仕様書 4.8）。
# ---------------------------------------------------------------------------

echo "== compose_conflict_warnings（衝突検出・Docker 非依存） =="

# shellcheck source=../scripts/lib/compose-conflicts.sh
. "${REPO_ROOT}/scripts/lib/compose-conflicts.sh"

COMPOSE_CONFLICT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-compose-conflict.XXXXXX")"

COMPOSE_FILE_CONTAINER_NAME="${COMPOSE_CONFLICT_DIR}/container-name.yml"
cat > "$COMPOSE_FILE_CONTAINER_NAME" <<'YAML'
services:
  app:
    build: .
    container_name: myapp
    volumes:
      - .:/workspace
YAML

COMPOSE_FILE_FIXED_PORT="${COMPOSE_CONFLICT_DIR}/fixed-port.yml"
cat > "$COMPOSE_FILE_FIXED_PORT" <<'YAML'
services:
  app:
    build: .
    ports:
      - "8080:80"
    volumes:
      - .:/workspace
YAML

COMPOSE_FILE_NO_CONFLICT="${COMPOSE_CONFLICT_DIR}/no-conflict.yml"
cat > "$COMPOSE_FILE_NO_CONFLICT" <<'YAML'
services:
  app:
    build: .
    ports:
      - "3000"
    volumes:
      - .:/workspace
YAML

CONTAINER_NAME_WARNINGS="$(compose_conflict_warnings "$COMPOSE_FILE_CONTAINER_NAME")"
if [ -n "$CONTAINER_NAME_WARNINGS" ]; then
  pass "container_name: を含む compose ファイルで警告が出る"
else
  fail "container_name: を含む compose ファイルで警告が出る" "警告が空でした"
fi

FIXED_PORT_WARNINGS="$(compose_conflict_warnings "$COMPOSE_FILE_FIXED_PORT")"
if [ -n "$FIXED_PORT_WARNINGS" ]; then
  pass "固定ホストポートを含む compose ファイルで警告が出る"
else
  fail "固定ホストポートを含む compose ファイルで警告が出る" "警告が空でした"
fi

NO_CONFLICT_WARNINGS="$(compose_conflict_warnings "$COMPOSE_FILE_NO_CONFLICT")"
assert_eq "衝突が無い compose ファイル（コンテナ側ポートのみ）では警告が出ない" "" "$NO_CONFLICT_WARNINGS"

# ---------------------------------------------------------------------------
# ケース8: compose モードの compose_project / compose_file / compose_service / workdir
# （Epic #3 仕様書「5. 検証方針」ケース8、Task #9）
#
# --project-directory がどの worktree から叩いてもリポジトリルートを指すこと、
# -p に渡るプロジェクト名が worktree 名に依存しないことが本タスクの本丸。
# ---------------------------------------------------------------------------

echo "== compose モード（ケース8） =="

COMPOSE_REPO="$(make_temp_repo)"
copy_sandbox_scripts_no_dockerfile "$COMPOSE_REPO"

COMPOSE_FILE_DEFAULT="${COMPOSE_REPO}/docker-compose.dev.yml"
cat > "$COMPOSE_FILE_DEFAULT" <<'YAML'
services:
  app:
    build: .
    volumes:
      - .:/workspace
YAML
(
  cd "$COMPOSE_REPO" || exit 1
  git add docker-compose.dev.yml
  git commit -q -m "add compose file"
) >/dev/null 2>&1

COMPOSE_REPO_BASENAME="$(basename "$COMPOSE_REPO")"

# --- print-plan（リポジトリルートから） ---
COMPOSE_CASE1_OUTPUT="$(print_plan_in "$COMPOSE_REPO")"

assert_eq "compose: mode=compose" "compose" "$(plan_value mode "$COMPOSE_CASE1_OUTPUT")"
assert_eq "compose: compose_file は docker-compose.dev.yml" "docker-compose.dev.yml" "$(plan_value compose_file "$COMPOSE_CASE1_OUTPUT")"
assert_eq "compose: compose_service は既定値 app" "app" "$(plan_value compose_service "$COMPOSE_CASE1_OUTPUT")"
assert_eq "compose: compose_project は dw-<repo>" "dw-${COMPOSE_REPO_BASENAME}" "$(plan_value compose_project "$COMPOSE_CASE1_OUTPUT")"
assert_eq "compose: workdir はリポジトリルートで /workspace" "/workspace" "$(plan_value workdir "$COMPOSE_CASE1_OUTPUT")"

# --- agent worktree から叩いても compose_project が worktree 名に依存しない（本タスクの本丸） ---
COMPOSE_AGENT_WORKTREE_DIR="${COMPOSE_REPO}/.claude/worktrees/agent-x"
make_worktree "$COMPOSE_REPO" "$COMPOSE_AGENT_WORKTREE_DIR" "compose-agent-worktree-branch"

COMPOSE_CASE_AGENT_OUTPUT="$(print_plan_in "$COMPOSE_AGENT_WORKTREE_DIR")"

assert_eq "compose: agent worktree からでも compose_project は同一（worktree 名非依存）" \
  "$(plan_value compose_project "$COMPOSE_CASE1_OUTPUT")" "$(plan_value compose_project "$COMPOSE_CASE_AGENT_OUTPUT")"
assert_eq "compose: agent worktree からの workdir は相対パス" \
  "/workspace/.claude/worktrees/agent-x" "$(plan_value workdir "$COMPOSE_CASE_AGENT_OUTPUT")"

# --- epic worktree からも compose_project が同一（agent worktree とも一致） ---
COMPOSE_EPIC_WORKTREE_DIR="${COMPOSE_REPO}/.claude/worktrees/epic7"
make_worktree "$COMPOSE_REPO" "$COMPOSE_EPIC_WORKTREE_DIR" "compose-epic-worktree-branch"

COMPOSE_CASE_EPIC_OUTPUT="$(print_plan_in "$COMPOSE_EPIC_WORKTREE_DIR")"

assert_eq "compose: epic worktree の compose_project も agent worktree と同一" \
  "$(plan_value compose_project "$COMPOSE_CASE_AGENT_OUTPUT")" "$(plan_value compose_project "$COMPOSE_CASE_EPIC_OUTPUT")"

# ---------------------------------------------------------------------------
# compose モードの実行系（偽 docker で `docker compose` を模擬する）。
#
# 偽 docker は `compose -p PROJECT --project-directory DIR -f FILE <サブコマンド>...`
# を解釈し、状態ファイルでサービスの running / not-running を切り替える。
# 実際の docker には一切触れない。呼び出し引数は DW_COMPOSE_LOG にすべて記録する。
# ---------------------------------------------------------------------------

FAKE_DOCKER_COMPOSE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin-compose.XXXXXX")"
cat > "${FAKE_DOCKER_COMPOSE_DIR}/docker" <<'FAKE_DOCKER_COMPOSE'
#!/bin/bash
# tests/run-tests.sh 用の偽 docker（compose モード専用）。実際の docker には一切触れない。
set -u

LOG="${DW_COMPOSE_LOG:?DW_COMPOSE_LOG is required}"
STATE_FILE="${DW_COMPOSE_SERVICE_STATE:?DW_COMPOSE_SERVICE_STATE is required}"   # "" | running
UP_SUCCEEDS="${DW_COMPOSE_UP_SUCCEEDS:-1}"
WORKDIR_OK="${DW_COMPOSE_WORKDIR_OK:-1}"

echo "$*" >> "$LOG"

case "${1:-}" in
  compose)
    shift
    # 先頭の共通オプション（-p / --project-directory / -f）を読み飛ばしてサブコマンドを取り出す
    while [ $# -gt 0 ]; do
      case "$1" in
        -p|--project-directory|-f) shift 2 ;;
        *) break ;;
      esac
    done
    sub="${1:-}"
    shift || true
    case "$sub" in
      ps)
        state="$(cat "$STATE_FILE" 2>/dev/null || true)"
        if [ "$state" = "running" ]; then
          echo "fake-compose-container-id"
        fi
        exit 0
        ;;
      up)
        if [ "$UP_SUCCEEDS" = "1" ]; then
          printf 'running\n' > "$STATE_FILE"
        fi
        exit 0
        ;;
      exec)
        case "$*" in
          *"test -d"*)
            [ "$WORKDIR_OK" = "1" ] && exit 0 || exit 1
            ;;
          *)
            # -c の次の引数がコマンド文字列（quoting により1引数として渡ってくる）
            cmd=""
            prev=""
            for a in "$@"; do
              [ "$prev" = "-c" ] && cmd="$a"
              prev="$a"
            done
            sh -c "$cmd"
            exit $?
            ;;
        esac
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  container)
    shift
    [ "${1:-}" = "inspect" ] || exit 1
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) shift 2 ;;
        *)  shift ;;
      esac
    done
    state="$(cat "$STATE_FILE" 2>/dev/null || true)"
    if [ "$state" = "running" ]; then echo "true"; else echo "false"; fi
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
FAKE_DOCKER_COMPOSE
chmod +x "${FAKE_DOCKER_COMPOSE_DIR}/docker"

COMPOSE_TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-composelog.XXXXXX")"
COMPOSE_TEST_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-composestate.XXXXXX")"

run_compose_case() {
  # run_compose_case <dir> <initial_state> <up_succeeds 0/1> <workdir_ok 0/1> [追加のsandbox-exec.sh引数...]
  local dir="$1" initial_state="$2" up_succeeds="$3" workdir_ok="$4"
  shift 4

  : > "$COMPOSE_TEST_LOG"
  printf '%s' "$initial_state" > "$COMPOSE_TEST_STATE_FILE"

  (
    cd "$dir" || exit 1
    DW_COMPOSE_LOG="$COMPOSE_TEST_LOG" \
      DW_COMPOSE_SERVICE_STATE="$COMPOSE_TEST_STATE_FILE" \
      DW_COMPOSE_UP_SUCCEEDS="$up_succeeds" \
      DW_COMPOSE_WORKDIR_OK="$workdir_ok" \
      PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh "$@"
  )
}

# --- agent worktree から叩いても --project-directory がリポジトリルートを指す（本タスクの本丸） ---
COMPOSE_HOST_ROOT="$(plan_value repo_root "$COMPOSE_CASE1_OUTPUT")"

COMPOSE_RUN1_EXIT=0
run_compose_case "$COMPOSE_AGENT_WORKTREE_DIR" "running" 1 1 'true' >/dev/null 2>&1 || COMPOSE_RUN1_EXIT=$?
assert_exit_code "compose: agent worktree からの実行が成功する" 0 "$COMPOSE_RUN1_EXIT"

case "$(cat "$COMPOSE_TEST_LOG")" in
  *"--project-directory ${COMPOSE_HOST_ROOT}"*)
    pass "compose: agent worktree から叩いても --project-directory がリポジトリルートを指す" ;;
  *)
    fail "compose: agent worktree から叩いても --project-directory がリポジトリルートを指す" \
      "log=[$(cat "$COMPOSE_TEST_LOG")] expected_root=[${COMPOSE_HOST_ROOT}]" ;;
esac

case "$(cat "$COMPOSE_TEST_LOG")" in
  *"-p dw-${COMPOSE_REPO_BASENAME} "*)
    pass "compose: -p に渡るプロジェクト名が agent worktree でも repo 基準" ;;
  *)
    fail "compose: -p に渡るプロジェクト名が agent worktree でも repo 基準" "log=[$(cat "$COMPOSE_TEST_LOG")]" ;;
esac

# --- サービス未起動時に up -d が呼ばれる ---
COMPOSE_RUN2_EXIT=0
run_compose_case "$COMPOSE_REPO" "" 1 1 'true' >/dev/null 2>&1 || COMPOSE_RUN2_EXIT=$?
assert_exit_code "compose: サービス未起動から up -d 成功時は実行全体が成功する" 0 "$COMPOSE_RUN2_EXIT"

if grep -q ' up -d app$' "$COMPOSE_TEST_LOG"; then
  pass "compose: サービス未起動時に up -d が呼ばれる"
else
  fail "compose: サービス未起動時に up -d が呼ばれる" "log=[$(cat "$COMPOSE_TEST_LOG")]"
fi

# --- up -d しても起動しない場合、サービス名と DEV_WORKFLOW_COMPOSE_SERVICE を含むエラーで停止する ---
COMPOSE_RUN3_STDERR="$(run_compose_case "$COMPOSE_REPO" "" 0 1 'true' 2>&1 1>/dev/null)"
COMPOSE_RUN3_EXIT=$?

if [ "$COMPOSE_RUN3_EXIT" -ne 0 ]; then
  pass "compose: up -d しても起動しない場合は非0で終了する"
else
  fail "compose: up -d しても起動しない場合は非0で終了する" "exit=0"
fi

case "$COMPOSE_RUN3_STDERR" in
  *"app"*) pass "compose: 起動失敗エラーにサービス名が含まれる" ;;
  *) fail "compose: 起動失敗エラーにサービス名が含まれる" "stderr=[${COMPOSE_RUN3_STDERR}]" ;;
esac

case "$COMPOSE_RUN3_STDERR" in
  *"DEV_WORKFLOW_COMPOSE_SERVICE"*) pass "compose: 起動失敗エラーに DEV_WORKFLOW_COMPOSE_SERVICE の案内が含まれる" ;;
  *) fail "compose: 起動失敗エラーに DEV_WORKFLOW_COMPOSE_SERVICE の案内が含まれる" "stderr=[${COMPOSE_RUN3_STDERR}]" ;;
esac

# --- workdir が無い場合、DEV_WORKFLOW_COMPOSE_WORKDIR に言及したエラーで停止する ---
COMPOSE_RUN4_STDERR="$(run_compose_case "$COMPOSE_REPO" "running" 1 0 'true' 2>&1 1>/dev/null)"
COMPOSE_RUN4_EXIT=$?

if [ "$COMPOSE_RUN4_EXIT" -ne 0 ]; then
  pass "compose: workdir が無い場合は非0で終了する"
else
  fail "compose: workdir が無い場合は非0で終了する" "exit=0"
fi

case "$COMPOSE_RUN4_STDERR" in
  *"DEV_WORKFLOW_COMPOSE_WORKDIR"*) pass "compose: workdir 不在エラーに DEV_WORKFLOW_COMPOSE_WORKDIR の案内が含まれる" ;;
  *) fail "compose: workdir 不在エラーに DEV_WORKFLOW_COMPOSE_WORKDIR の案内が含まれる" "stderr=[${COMPOSE_RUN4_STDERR}]" ;;
esac

# --- container_name: を含む compose ファイルを使うと、実行時に stderr へ警告が出る（停止はしない） ---
COMPOSE_WARN_REPO="$(make_temp_repo)"
copy_sandbox_scripts_no_dockerfile "$COMPOSE_WARN_REPO"
cat > "${COMPOSE_WARN_REPO}/docker-compose.dev.yml" <<'YAML'
services:
  app:
    build: .
    container_name: myapp
    volumes:
      - .:/workspace
YAML
(
  cd "$COMPOSE_WARN_REPO" || exit 1
  git add docker-compose.dev.yml
  git commit -q -m "add compose file with container_name"
) >/dev/null 2>&1

COMPOSE_WARN_STDERR="$(
  : > "$COMPOSE_TEST_LOG"
  printf 'running' > "$COMPOSE_TEST_STATE_FILE"
  cd "$COMPOSE_WARN_REPO" || exit 1
  DW_COMPOSE_LOG="$COMPOSE_TEST_LOG" \
    DW_COMPOSE_SERVICE_STATE="$COMPOSE_TEST_STATE_FILE" \
    DW_COMPOSE_UP_SUCCEEDS=1 \
    DW_COMPOSE_WORKDIR_OK=1 \
    PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh 'true' 2>&1 1>/dev/null
)"

case "$COMPOSE_WARN_STDERR" in
  *"container_name"*) pass "compose: 実行時に container_name の衝突警告が stderr に出る" ;;
  *) fail "compose: 実行時に container_name の衝突警告が stderr に出る" "stderr=[${COMPOSE_WARN_STDERR}]" ;;
esac

# ---------------------------------------------------------------------------
# CRLF 警告（crlf_warning_message、Docker 非依存の純粋関数、Task #11、Epic #3 仕様書 4.10）
#
# check-prerequisites.sh を source しても本体（gh/docker/git リポジトリチェック等）が
# 実行されないことを利用し、crlf_warning_message だけを直接呼び出して検証する。
# 一時 git リポジトリの core.autocrlf / .gitattributes を組み合わせて条件を再現する。
# ---------------------------------------------------------------------------

echo "== crlf_warning_message（CRLF警告・Docker非依存。Task #11） =="

CHECK_PREREQS_SCRIPT="${REPO_ROOT}/scripts/check-prerequisites.sh"

make_crlf_test_repo() {
  # make_crlf_test_repo <autocrlf値> <gitattributes内容 or 空>
  # core.autocrlf と .gitattributes を指定して一時リポジトリを作り、パスを返す。
  local autocrlf="$1" attrs="$2"
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-crlf-repo.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email "dev-workflow-test@example.com"
    git config user.name "dev-workflow test"
    git config core.autocrlf "$autocrlf"
    if [ -n "$attrs" ]; then
      printf '%s\n' "$attrs" > .gitattributes
    fi
  ) >/dev/null 2>&1
  printf '%s' "$dir"
}

crlf_warning_in() {
  # crlf_warning_in <dir>  <dir> 内で check-prerequisites.sh を source し
  # crlf_warning_message を呼び出した標準出力を返す（stderr は捨てる）。
  local dir="$1"
  (
    cd "$dir" || exit 1
    # shellcheck source=../scripts/check-prerequisites.sh
    source "$CHECK_PREREQS_SCRIPT"
    crlf_warning_message
  ) 2>/dev/null
}

# --- autocrlf=true かつ .gitattributes に *.sh の eol=lf が無ければ警告が出る ---
CRLF_NOATTR_REPO="$(make_crlf_test_repo true "")"
CRLF_NOATTR_WARNING="$(crlf_warning_in "$CRLF_NOATTR_REPO")"

if [ -n "$CRLF_NOATTR_WARNING" ]; then
  pass "autocrlf=true かつ eol=lf 未設定なら警告が出る"
else
  fail "autocrlf=true かつ eol=lf 未設定なら警告が出る" "警告が空でした"
fi

case "$CRLF_NOATTR_WARNING" in
  *".gitattributes"*) pass "警告文に .gitattributes への言及がある" ;;
  *) fail "警告文に .gitattributes への言及がある" "warning=[${CRLF_NOATTR_WARNING}]" ;;
esac

case "$CRLF_NOATTR_WARNING" in
  *"*.sh text eol=lf"*) pass "警告文に *.sh text eol=lf の追記案内がある" ;;
  *) fail "警告文に *.sh text eol=lf の追記案内がある" "warning=[${CRLF_NOATTR_WARNING}]" ;;
esac

if printf '%s' "$CRLF_NOATTR_WARNING" | grep -qF '$'"'"'{\r'"'"''; then
  pass "警告文に構文エラーの症状（\$'{\\r'）が含まれる"
else
  fail "警告文に構文エラーの症状（\$'{\\r'）が含まれる" "warning=[${CRLF_NOATTR_WARNING}]"
fi

# --- autocrlf=true でも .gitattributes に *.sh text eol=lf があれば警告は出ない ---
CRLF_WITHATTR_REPO="$(make_crlf_test_repo true "*.sh text eol=lf")"
CRLF_WITHATTR_WARNING="$(crlf_warning_in "$CRLF_WITHATTR_REPO")"

assert_eq "autocrlf=true でも *.sh text eol=lf があれば警告が出ない" "" "$CRLF_WITHATTR_WARNING"

# --- autocrlf=false なら警告は出ない ---
CRLF_FALSE_REPO="$(make_crlf_test_repo false "")"
CRLF_FALSE_WARNING="$(crlf_warning_in "$CRLF_FALSE_REPO")"

assert_eq "autocrlf=false なら警告が出ない" "" "$CRLF_FALSE_WARNING"

# --- autocrlf=input でも警告は出ない（true のときだけが対象） ---
CRLF_INPUT_REPO="$(make_crlf_test_repo input "")"
CRLF_INPUT_WARNING="$(crlf_warning_in "$CRLF_INPUT_REPO")"

assert_eq "autocrlf=input なら警告が出ない" "" "$CRLF_INPUT_WARNING"

# --- 警告が出るケースでも check-prerequisites.sh 全体の終了コードは変わらない（exit 2 でブロックしない） ---
#
# check-prerequisites.sh 本体は gh/docker の実コマンドを呼び、gh 認証済みなら
# `git config --global credential.helper` まで書き換える副作用を持つ。テストで
# 実ホストの状態を変えないよう、gh/docker は偽コマンドに差し替え、--global の参照先も
# 隔離した HOME に向ける（実際の docker/gh には一切触れない）。
CRLF_FAKE_BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-crlf-fakebin.XXXXXX")"
cat > "${CRLF_FAKE_BIN_DIR}/gh" <<'FAKE_GH'
#!/bin/bash
# tests/run-tests.sh 用の偽 gh。認証済み扱いにして常に成功させる。
exit 0
FAKE_GH
chmod +x "${CRLF_FAKE_BIN_DIR}/gh"
cat > "${CRLF_FAKE_BIN_DIR}/docker" <<'FAKE_DOCKER_PREREQ'
#!/bin/bash
# tests/run-tests.sh 用の偽 docker。起動済み扱いにして常に成功させる。
exit 0
FAKE_DOCKER_PREREQ
chmod +x "${CRLF_FAKE_BIN_DIR}/docker"

CRLF_FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-crlf-fakehome.XXXXXX")"
printf '[credential]\n\thelper = gh\n' > "${CRLF_FAKE_HOME}/.gitconfig"

CRLF_FULL_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-crlf-full-stderr.XXXXXX")"
CRLF_FULL_EXIT=0
(
  cd "$CRLF_NOATTR_REPO" || exit 1
  HOME="$CRLF_FAKE_HOME" PATH="${CRLF_FAKE_BIN_DIR}:${PATH}" \
    bash "$CHECK_PREREQS_SCRIPT" 1>/dev/null 2>"$CRLF_FULL_STDERR"
) || CRLF_FULL_EXIT=$?

assert_exit_code "偽gh/偽dockerが揃った状態でCRLF警告があっても exit 0（ブロックしない）" 0 "$CRLF_FULL_EXIT"

if grep -q "core.autocrlf=true" "$CRLF_FULL_STDERR"; then
  pass "check-prerequisites.sh 本体からも CRLF 警告が stderr に出る"
else
  fail "check-prerequisites.sh 本体からも CRLF 警告が stderr に出る" "stderr=[$(cat "$CRLF_FULL_STDERR")]"
fi

# ---------------------------------------------------------------------------
# check-readability.sh の非対話ハング修正（Task #10、Epic #3 仕様書 4.9）
#
# `--git` / `--staged` / ファイル引数が1つでもあれば stdin を一切読まない。
# 引数なし・非ttyのフック経路だけ上限付きで読み、タイムアウト時は exit 0 で
# 素通りする。ガード本体の判定ロジック（base64ブロブ検出・長い行検出）は
# 変更しない仕様のため、違反検出が従来どおり働くこともあわせて検証する。
#
# 「stdinを読まない」ことの検証は、プロセス置換 `< <(sleep N)` で終端しない
# stdinを用意して行う。パイプ（`sleep N | cmd`）だと親シェルが sleep の終了まで
# 待たされてテストが遅くなるが、プロセス置換なら判定対象コマンドが先に終われば
# 親シェルはバックグラウンドの sleep を待たない。もしスクリプトが誤って stdin を
# 読もうとした場合だけ `timeout` に引っかかり、それを失敗として検出する。
# ---------------------------------------------------------------------------

echo "== check-readability.sh（非対話ハング修正・Task #10） =="

CHECK_READABILITY_SCRIPT="${REPO_ROOT}/scripts/check-readability.sh"

RG_TMP_REPO="$(make_temp_repo)"
RG_CLEAN_FILE="clean.txt"
(
  cd "$RG_TMP_REPO" || exit 1
  printf 'clean file\n' > "$RG_CLEAN_FILE"
) >/dev/null 2>&1

# --- --git はstdinが開いたままでもハングせず即座に返る ---
RG_GIT_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  timeout 5 bash "$CHECK_READABILITY_SCRIPT" --git < <(sleep 10) >/dev/null 2>&1
)
RG_GIT_EXIT=$?
assert_exit_code "--git はstdinが開いたままでもハングせず即座に返る" 0 "$RG_GIT_EXIT"

# --- ファイル引数を渡した場合もstdinを読まない ---
RG_FILEARG_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  timeout 5 bash "$CHECK_READABILITY_SCRIPT" "$RG_CLEAN_FILE" < <(sleep 10) >/dev/null 2>&1
)
RG_FILEARG_EXIT=$?
assert_exit_code "ファイル引数を渡した場合もstdinを読まず即座に返る" 0 "$RG_FILEARG_EXIT"

# --- --staged も同様 ---
(
  cd "$RG_TMP_REPO" || exit 1
  git add "$RG_CLEAN_FILE"
) >/dev/null 2>&1

RG_STAGED_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  timeout 5 bash "$CHECK_READABILITY_SCRIPT" --staged < <(sleep 10) >/dev/null 2>&1
)
RG_STAGED_EXIT=$?
assert_exit_code "--stagedもstdinが開いたままでもハングせず即座に返る" 0 "$RG_STAGED_EXIT"

# --- 引数なし・非ttyで入力が来ない場合、タイムアウト後にexit 0で素通りする ---
# テストを遅くしないよう READABILITY_STDIN_TIMEOUT=1 で短くする。
RG_TIMEOUT_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-rg-timeout-stderr.XXXXXX")"
RG_TIMEOUT_EXIT=0
timeout 5 env READABILITY_STDIN_TIMEOUT=1 bash "$CHECK_READABILITY_SCRIPT" \
  < <(sleep 10) >/dev/null 2>"$RG_TIMEOUT_STDERR"
RG_TIMEOUT_EXIT=$?
assert_exit_code "引数なし・非ttyで入力が来ない場合はタイムアウト後exit 0で素通りする" 0 "$RG_TIMEOUT_EXIT"

if grep -q "1秒" "$RG_TIMEOUT_STDERR"; then
  pass "タイムアウト時にREADABILITY_STDIN_TIMEOUTの秒数を含む警告がstderrに出る"
else
  fail "タイムアウト時にREADABILITY_STDIN_TIMEOUTの秒数を含む警告がstderrに出る" "stderr=[$(cat "$RG_TIMEOUT_STDERR")]"
fi

# --- 引数なし・非ttyでフックJSONが渡された場合は従来どおり処理される（クリーンなファイル） ---
RG_HOOK_CLEAN_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  printf '{"tool_input":{"file_path":"%s"}}' "$RG_CLEAN_FILE" | bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG_HOOK_CLEAN_EXIT=$?
assert_exit_code "フックJSONのfile_pathから抽出したクリーンなファイルはexit 0" 0 "$RG_HOOK_CLEAN_EXIT"

# --- 引数なし・非ttyでフックJSONが渡された場合は従来どおり処理される（違反ファイル） ---
RG_VIOLATION_FILE="violation.txt"
(
  cd "$RG_TMP_REPO" || exit 1
  head -c 3000 /dev/zero | tr '\0' 'A' > "$RG_VIOLATION_FILE"
) >/dev/null 2>&1

RG_HOOK_VIOLATION_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  printf '{"tool_input":{"file_path":"%s"}}' "$RG_VIOLATION_FILE" \
    | READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG_HOOK_VIOLATION_EXIT=$?
assert_exit_code "フックJSON経由でも違反ファイルはブロックされる" 2 "$RG_HOOK_VIOLATION_EXIT"

# --- 違反検出ロジックは従来どおり働く（巨大なbase64ブロブ） ---
RG_BLOB_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" "$RG_VIOLATION_FILE" >/dev/null 2>&1
)
RG_BLOB_EXIT=$?
assert_exit_code "巨大なbase64ブロブを含むファイルはexit 2" 2 "$RG_BLOB_EXIT"

# --- 違反検出ロジックは従来どおり働く（極端に長い行）。
# base64文字集合に含まれない '-' で埋めることで、base64ブロブ検出とは
# 独立に「長い行」ルール単体の検出を確認する。
RG_LONGLINE_FILE="longline.txt"
(
  cd "$RG_TMP_REPO" || exit 1
  head -c 6000 /dev/zero | tr '\0' '-' > "$RG_LONGLINE_FILE"
  printf '\n' >> "$RG_LONGLINE_FILE"
) >/dev/null 2>&1

RG_LONGLINE_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG_LONGLINE_FILE" >/dev/null 2>&1
)
RG_LONGLINE_EXIT=$?
assert_exit_code "極端に長い行を含むファイルはexit 2" 2 "$RG_LONGLINE_EXIT"

# --- クリーンなファイルはexit 0（引数指定） ---
RG_CLEAN_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG_CLEAN_FILE" >/dev/null 2>&1
)
RG_CLEAN_EXIT=$?
assert_exit_code "クリーンなファイルはexit 0" 0 "$RG_CLEAN_EXIT"

# --- ヘッダコメントに実在しない --exit-code の記述が残っていない ---
if grep -q -- '--exit-code' "$CHECK_READABILITY_SCRIPT"; then
  fail "ヘッダコメントに実在しない--exit-codeの記述が残っていない" "grep hit: $(grep -n -- '--exit-code' "$CHECK_READABILITY_SCRIPT")"
else
  pass "ヘッダコメントに実在しない--exit-codeの記述が残っていない"
fi

if grep -q "DEV_WORKFLOW_HOOK_VENDOR=exit-code" "$CHECK_READABILITY_SCRIPT"; then
  pass "ヘッダコメントがDEV_WORKFLOW_HOOK_VENDOR=exit-codeの正しい説明に修正されている"
else
  fail "ヘッダコメントがDEV_WORKFLOW_HOOK_VENDOR=exit-codeの正しい説明に修正されている" "grepで見つかりませんでした"
fi

# ---------------------------------------------------------------------------
# .gitattributes の eol=lf カバレッジ（回帰防止）
#
# *.toml（adapters/*/overlays/*.toml・codex-agents/*.toml）に eol=lf 指定が無かったため、
# core.autocrlf=true の環境でワーキングツリー上の *.toml が CRLF 化され、
# adapters/codex/build.sh の include 展開（1行ずつの case 一致）が壊れて
# `build.sh --check` が生成物を誤って STALE 判定する事故が実際に発生した。
# 同じ障害クラスが *.sh / *.toml のどちらでも起きないことを検証する。
#
# このリポジトリ自身（REPO_ROOT）に対して直接 git check-attr を呼ばないのは、
# generator の worktree（.claude/worktrees/agent-*）はリンク済みworktreeであり、
# サンドボックスのバインドマウント経由では .git ファイルが指す gitdir の絶対パスが
# 解決できず `fatal: not a git repository` になる環境依存の問題があるため。
# 実際に使う .gitattributes の内容を、worktree に依存しない素の一時リポジトリへ
# コピーして検証する（他のテストケースの make_temp_repo と同じ考え方）。
# ---------------------------------------------------------------------------

echo "== .gitattributes の eol=lf カバレッジ（回帰防止） =="

GITATTRIBUTES_TEST_REPO="$(make_temp_repo)"
cp "${REPO_ROOT}/.gitattributes" "${GITATTRIBUTES_TEST_REPO}/.gitattributes"
(
  cd "$GITATTRIBUTES_TEST_REPO" || exit 1
  git add .gitattributes
  git commit -q -m "add .gitattributes"
) >/dev/null 2>&1

check_eol_lf() {
  # check_eol_lf <repo> <プローブ用パス（repo内の任意の相対パスでよい）>
  # git check-attr eol の解決結果が lf なら true を返す（Docker 非依存）。
  local repo="$1" probe_path="$2"
  local eol
  eol="$(cd "$repo" && git check-attr eol -- "$probe_path" 2>/dev/null | sed -n 's/^.*: eol: //p')"
  [ "$eol" = "lf" ]
}

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" "dev-workflow-gitattributes-probe.sh"; then
  pass ".gitattributes: *.sh の eol 解決が lf である"
else
  fail ".gitattributes: *.sh の eol 解決が lf である" "check-attr の解決結果が lf ではありませんでした"
fi

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" "dev-workflow-gitattributes-probe.toml"; then
  pass ".gitattributes: *.toml の eol 解決が lf である"
else
  fail ".gitattributes: *.toml の eol 解決が lf である" "check-attr の解決結果が lf ではありませんでした"
fi

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" "adapters/codex/overlays/dev-workflow-gitattributes-probe.toml"; then
  pass ".gitattributes: adapters/codex/overlays/ 配下の *.toml も eol=lf が効く"
else
  fail ".gitattributes: adapters/codex/overlays/ 配下の *.toml も eol=lf が効く" "check-attr の解決結果が lf ではありませんでした"
fi

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" "codex-agents/dev-workflow-gitattributes-probe.toml"; then
  pass ".gitattributes: codex-agents/ 配下の *.toml も eol=lf が効く"
else
  fail ".gitattributes: codex-agents/ 配下の *.toml も eol=lf が効く" "check-attr の解決結果が lf ではありませんでした"
fi

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" ".gitattributes"; then
  pass ".gitattributes: .gitattributes 自身の eol 解決も lf である（自己参照ルール）"
else
  fail ".gitattributes: .gitattributes 自身の eol 解決も lf である（自己参照ルール）" "check-attr の解決結果が lf ではありませんでした"
fi

# ---------------------------------------------------------------------------
# 役割定義・生成物に docker 直接呼び出しの記述が残っていない（回帰防止 #26）
#
# core/roles/evaluator.md の「テスト実行（サンドボックス内）」節が、イメージタグを
# hash 付けに変えた本Epicの変更に追随せず、`docker run --rm ... dev-sandbox:[project]` /
# `docker compose -f docker-compose.dev.yml exec app` という旧い直接呼び出しのまま
# 生成物（agents/evaluator.md・codex-agents/evaluator.toml）に伝播していた。
# Task #12・#13 が対象ファイル一覧に evaluator.md を含めていなかったことが原因なので、
# ファイル名を列挙するのではなく core/roles・agents・codex-agents をディレクトリごと
# 走査する。core/instructions.md も同じ理由で対象に含める。
# ---------------------------------------------------------------------------

echo "== 役割定義・生成物に docker 直接呼び出しの記述が残っていない（回帰防止 #26） =="

FORBIDDEN_SANDBOX_PATTERN='docker run --rm|dev-sandbox:\[project\]|docker compose -f docker-compose\.dev\.yml exec'

check_no_forbidden_sandbox_calls() {
  # check_no_forbidden_sandbox_calls <説明> <検査対象（ファイルまたはディレクトリ）>
  local desc="$1" target="$2"
  local hits
  hits="$(grep -rnE "$FORBIDDEN_SANDBOX_PATTERN" "$target" 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    pass "$desc"
  else
    fail "$desc" "$hits"
  fi
}

check_no_forbidden_sandbox_calls "core/roles/ に docker 直接呼び出しが残っていない" "${REPO_ROOT}/core/roles"
check_no_forbidden_sandbox_calls "core/instructions.md に docker 直接呼び出しが残っていない" "${REPO_ROOT}/core/instructions.md"
check_no_forbidden_sandbox_calls "agents/ に docker 直接呼び出しが残っていない" "${REPO_ROOT}/agents"
check_no_forbidden_sandbox_calls "codex-agents/ に docker 直接呼び出しが残っていない" "${REPO_ROOT}/codex-agents"

# ---------------------------------------------------------------------------
# 結果集計
# ---------------------------------------------------------------------------

echo ""
echo "== 結果: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped =="

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "失敗したケース:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  - ${c}"
  done
  exit 1
fi

exit 0
