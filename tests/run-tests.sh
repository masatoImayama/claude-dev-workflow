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
  cp "${REPO_ROOT}/scripts/lib/mount-path.sh"           "${dest}/scripts/lib/mount-path.sh"
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
  cp "${REPO_ROOT}/scripts/lib/mount-path.sh"           "${dest}/scripts/lib/mount-path.sh"
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

# --- --epic に値が無いまま渡された場合は無限ループせず明快なエラーで停止する ---
# shift 2 が失敗して $# が減らないまま while ループが回り続ける不具合があった
# （実測: timeout 8 bash scripts/sandbox-exec.sh --epic は exit 124 だった）。
if command -v timeout >/dev/null 2>&1; then
  EPIC_NO_VALUE_STDERR="$(
    cd "$PRINT_PLAN_REPO" || exit 1
    PATH="${FAKE_BIN_DIR}:${PATH}" timeout 8 bash scripts/sandbox-exec.sh --epic 2>&1 1>/dev/null
  )"
  EPIC_NO_VALUE_EXIT=$?

  if [ "$EPIC_NO_VALUE_EXIT" -eq 124 ]; then
    fail "--epic に値が無い場合は無限ループしない" "timeout（exit 124）で停止しました"
  elif [ "$EPIC_NO_VALUE_EXIT" -eq 0 ]; then
    fail "--epic に値が無い場合は非0で終了する" "exit=0"
  else
    pass "--epic に値が無い場合は無限ループせず非0で終了する"
  fi

  case "$EPIC_NO_VALUE_STDERR" in
    *"--epic"*) pass "--epic に値が無い場合のエラーに --epic の記載がある" ;;
    *) fail "--epic に値が無い場合のエラーに --epic の記載がある" "stderr=[${EPIC_NO_VALUE_STDERR}]" ;;
  esac
else
  skip "--epic に値が無い場合は無限ループせず明快なエラーで停止する" "timeout コマンドが利用できません"
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
# ケース7a: normalize_mount_source（Docker 非依存の純粋関数、issue #25）
#
# Windows + Docker Desktop の bind mount .Source（/run/desktop/mnt/host/<drive>/...）と
# pwd -W によるホスト側パス（<DRIVE>:/...）を、大小文字・区切りを揃えた同一表現に
# 正規化できることを、docker を一切起動せずに直接検証する。
# ---------------------------------------------------------------------------

echo "== normalize_mount_source（マウント元の正規化・Docker 非依存・issue #25） =="

# shellcheck source=../scripts/lib/mount-path.sh
. "${REPO_ROOT}/scripts/lib/mount-path.sh"

assert_eq "normalize_mount_source: Docker Desktop 形式 (/run/desktop/mnt/host/<drive>/...) を <DRIVE>:/... へ変換する" \
  "C:/users/mimay/documents/github/dev-workflow" \
  "$(normalize_mount_source "/run/desktop/mnt/host/c/Users/mimay/Documents/github/dev-workflow")"

assert_eq "normalize_mount_source: pwd -W 形式（既に <DRIVE>:/...）も同じ表現に正規化する" \
  "C:/users/mimay/documents/github/dev-workflow" \
  "$(normalize_mount_source "C:/Users/mimay/Documents/github/dev-workflow")"

assert_eq "normalize_mount_source: /mnt/<drive>/...（WSL）も同じ表現に正規化する" \
  "C:/users/mimay/documents/github/dev-workflow" \
  "$(normalize_mount_source "/mnt/c/Users/mimay/Documents/github/dev-workflow")"

assert_eq "normalize_mount_source: //<drive>/...（Git Bash 等）も同じ表現に正規化する" \
  "C:/users/mimay/documents/github/dev-workflow" \
  "$(normalize_mount_source "//c/Users/mimay/Documents/github/dev-workflow")"

assert_eq "normalize_mount_source: バックスラッシュ区切りもスラッシュへ統一する" \
  "C:/users/mimay/repo" \
  "$(normalize_mount_source 'C:\Users\mimay\repo')"

assert_eq "normalize_mount_source: ドライブ形式でない通常の Unix パスは大小文字を変えずそのまま返す" \
  "/home/User/Repo" \
  "$(normalize_mount_source "/home/User/Repo")"

# ---------------------------------------------------------------------------
# ケース7b: container_belongs_to_repo（Docker 非依存の所属判定関数、Task #6 / issue #29）
#
# label あり／label なしの旧命名残骸／他リポジトリの各パターンに加え、
# dev-workflow.root label による同名 basename・別 root の判別（issue #29）と、
# Docker Desktop 形式マウント元の正規化済み比較（issue #25）を、docker を一切
# 起動せずに純粋関数として直接検証する。
#
# シグネチャ: container_belongs_to_repo <label_repo> <label_root> <mount_source> <host_root> <project>
# ---------------------------------------------------------------------------

echo "== container_belongs_to_repo（所属判定・Docker 非依存） =="

# shellcheck source=../scripts/lib/container-membership.sh
. "${REPO_ROOT}/scripts/lib/container-membership.sh"

HOST_ROOT_SAMPLE="/home/user/repo"

if container_belongs_to_repo "myrepo" "$HOST_ROOT_SAMPLE" "" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label の repo と root label が一致すれば対象に含まれる"
else
  fail "label の repo と root label が一致すれば対象に含まれる"
fi

if container_belongs_to_repo "myrepo" "/home/user2/repo" "" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "同名 basename でも root label が不一致なら対象に含まれない（issue #29）" "含まれてしまいました"
else
  pass "同名 basename でも root label が不一致なら対象に含まれない（issue #29）"
fi

if container_belongs_to_repo "otherrepo" "" "${HOST_ROOT_SAMPLE}/anything" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label の repo が不一致なら対象に含まれない" "含まれてしまいました（マウント元が一致していても label 不一致を優先すべき）"
else
  pass "label の repo が不一致なら対象に含まれない"
fi

if container_belongs_to_repo "myrepo" "" "${HOST_ROOT_SAMPLE}/anything" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "root label が空（旧コンテナ）の場合はマウント元判定にフォールバックする"
else
  fail "root label が空（旧コンテナ）の場合はマウント元判定にフォールバックする"
fi

if container_belongs_to_repo "myrepo" "" "/home/user/other-repo/subdir" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "root label が空でもマウント元が別リポジトリなら対象に含まれない" "含まれてしまいました"
else
  pass "root label が空でもマウント元が別リポジトリなら対象に含まれない"
fi

if container_belongs_to_repo "" "" "${HOST_ROOT_SAMPLE}/.claude/worktrees/agent-old" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label なし・マウント元がリポジトリルート配下なら対象に含まれる（旧命名の残骸回収）"
else
  fail "label なし・マウント元がリポジトリルート配下なら対象に含まれる"
fi

if container_belongs_to_repo "" "" "$HOST_ROOT_SAMPLE" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label なし・マウント元がリポジトリルート自身でも対象に含まれる"
else
  fail "label なし・マウント元がリポジトリルート自身でも対象に含まれる"
fi

if container_belongs_to_repo "" "" "/home/user/other-repo/subdir" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label なし・マウント元が別リポジトリなら対象に含まれない" "含まれてしまいました"
else
  pass "label なし・マウント元が別リポジトリなら対象に含まれない"
fi

if container_belongs_to_repo "" "" "" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label もマウント元も無ければ対象に含まれない" "含まれてしまいました"
else
  pass "label もマウント元も無ければ対象に含まれない"
fi

# --- issue #25: label なし・Docker Desktop 形式のマウント元でも正規化して同一ツリーと判定する ---
if container_belongs_to_repo "" "" "/run/desktop/mnt/host/c/Users/mimay/Documents/github/dev-workflow" \
    "C:/Users/mimay/Documents/github/dev-workflow" "dev-workflow"; then
  pass "label なし・Docker Desktop 形式のマウント元でも正規化して同一ツリーと判定する（issue #25）"
else
  fail "label なし・Docker Desktop 形式のマウント元でも正規化して同一ツリーと判定する（issue #25）"
fi

if container_belongs_to_repo "" "" "/run/desktop/mnt/host/c/Users/mimay/Documents/github/other-repo" \
    "C:/Users/mimay/Documents/github/dev-workflow" "dev-workflow"; then
  fail "Docker Desktop 形式でも別ツリーなら対象に含まれない" "含まれてしまいました"
else
  pass "Docker Desktop 形式でも別ツリーなら対象に含まれない"
fi

# --- issue #29: root label が Docker Desktop 形式・pwd -W 形式など異なる表現でも正規化して一致する ---
if container_belongs_to_repo "myrepo" "/run/desktop/mnt/host/c/Users/mimay/repo" "" \
    "C:/Users/mimay/repo" "myrepo"; then
  pass "root label が別表現（Docker Desktop 形式）でも正規化して一致すれば対象に含まれる（issue #29）"
else
  fail "root label が別表現（Docker Desktop 形式）でも正規化して一致すれば対象に含まれる（issue #29）"
fi

# ---------------------------------------------------------------------------
# ケース8: --ls / --down --all（偽 docker で label・マウント元を注入し、実際の docker を起動せず検証する）
#
# 偽 docker は DW_TEST_MANIFEST（name|managed|repo|epic|image|status|created|mount_source|root_label
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

# 1) label ありで現リポジトリに属するコンテナ（現行の起動中コンテナを模す。root label も一致）
# 2) label なしの旧命名残骸で、マウント元が現リポジトリのルート配下（回収されるべき）
# 3) label ありで他リポジトリに属するコンテナ（--down --all の対象に含まれてはいけない）
# 4) label なしで、マウント元が他リポジトリ配下（対象に含まれてはいけない）
# 5) label ありで repo（basename）は一致するが root label が異なる（別クローン。issue #29。
#    --down --all の対象に含まれてはいけない）
cat > "$DW_TEST_MANIFEST" <<MANIFEST
dw-sandbox-${LS_REPO_BASENAME}|1|${LS_REPO_BASENAME}||dev-sandbox:${LS_REPO_BASENAME}|running|2024-01-01T00:00:00Z|${LS_HOST_ROOT}|${LS_HOST_ROOT}
dw-sandbox-${LS_REPO_BASENAME}-legacy|||||exited|2023-01-01T00:00:00Z|${LS_HOST_ROOT}/.claude/worktrees/agent-old|
dw-sandbox-otherrepo|1|otherrepo||dev-sandbox:otherrepo|running|2024-02-02T00:00:00Z|/home/user/otherrepo|/home/user/otherrepo
dw-sandbox-otherrepo-legacy|||||exited|2023-03-03T00:00:00Z|/home/user/otherrepo/subdir|
dw-sandbox-${LS_REPO_BASENAME}-otherclone|1|${LS_REPO_BASENAME}||dev-sandbox:${LS_REPO_BASENAME}|running|2024-03-03T00:00:00Z|/home/otheruser/${LS_REPO_BASENAME}|/home/otheruser/${LS_REPO_BASENAME}
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
    IFS='|' read -r f_name f_managed f_repo f_epic f_image f_status f_created f_mount f_root <<< "$line"
    case "$tmpl" in
      *'dev-workflow.root'*) printf '%s\n' "$f_root" ;;
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

if printf '%s\n' "$DOWN_ALL_OUTPUT" | grep -q "otherclone"; then
  fail "--down --all は repo(basename) が同じでも root label が異なるコンテナを列挙しない（issue #29）" "output=[${DOWN_ALL_OUTPUT}]"
else
  pass "--down --all は repo(basename) が同じでも root label が異なるコンテナを列挙しない（issue #29）"
fi

RM_LOG_CONTENT="$(cat "$DW_TEST_RM_LOG")"
RM_LOG_COUNT="$(printf '%s\n' "$RM_LOG_CONTENT" | grep -c . || true)"
assert_eq "--down --all は自リポジトリ分の2件だけを docker rm する" "2" "$RM_LOG_COUNT"

if printf '%s\n' "$RM_LOG_CONTENT" | grep -q "otherrepo"; then
  fail "--down --all は他リポジトリのコンテナを削除しない" "rm_log=[${RM_LOG_CONTENT}]"
else
  pass "--down --all は他リポジトリのコンテナを削除しない"
fi

if printf '%s\n' "$RM_LOG_CONTENT" | grep -q "otherclone"; then
  fail "--down --all は repo(basename) が同じでも root label が異なるコンテナを削除しない（issue #29）" "rm_log=[${RM_LOG_CONTENT}]"
else
  pass "--down --all は repo(basename) が同じでも root label が異なるコンテナを削除しない（issue #29）"
fi

# --- --down（単体）: 削除対象名を表示し、現在の repo+epic のコンテナ1個だけを rm する（issue #30） ---
: > "$DW_TEST_RM_LOG"
DOWN_SINGLE_OUTPUT="$(
  cd "$LS_REPO" || exit 1
  DW_TEST_MANIFEST="$DW_TEST_MANIFEST" DW_TEST_RM_LOG="$DW_TEST_RM_LOG" \
    PATH="${FAKE_DOCKER_MANIFEST_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --down
)"

case "$DOWN_SINGLE_OUTPUT" in
  *"削除対象のコンテナ: dw-sandbox-${LS_REPO_BASENAME}"*)
    pass "--down（単体）は削除対象名を表示する（issue #30）" ;;
  *)
    fail "--down（単体）は削除対象名を表示する（issue #30）" "output=[${DOWN_SINGLE_OUTPUT}]" ;;
esac

DOWN_SINGLE_RM_CONTENT="$(cat "$DW_TEST_RM_LOG")"
DOWN_SINGLE_RM_COUNT="$(printf '%s\n' "$DOWN_SINGLE_RM_CONTENT" | grep -c . || true)"
assert_eq "--down（単体）は当該コンテナ1件だけを docker rm する（issue #30）" "1" "$DOWN_SINGLE_RM_COUNT"
assert_eq "--down（単体）は現在の repo+epic のコンテナ名を rm する（issue #30）" \
  "dw-sandbox-${LS_REPO_BASENAME}" "$DOWN_SINGLE_RM_CONTENT"

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
IMG_WORKDIR="$(plan_value workdir "$IMG_PLAN_AFTER_CHANGE")"
IMG_REPO_NAME="$(plan_value repo "$IMG_PLAN_AFTER_CHANGE")"
IMG_HOST_ROOT="$(plan_value repo_root "$IMG_PLAN_AFTER_CHANGE")"

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
    workdir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -w) workdir="$2"; shift 2 ;;
        sh) shift ;;
        -c) cmd="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    printf '%s\n' "$workdir" >> "${DW_IMG_EXEC_LOG:?DW_IMG_EXEC_LOG is required}"
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
IMG_TEST_EXEC_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgexeclog.XXXXXX")"
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
  : > "$IMG_TEST_EXEC_LOG"
  printf '%s' "$container_exists" > "$IMG_TEST_STATE_FILE"
  printf '%s\n' "$container_running" > "$IMG_TEST_RUNNING_FILE"

  (
    cd "$IMG_REPO" || exit 1
    DW_IMG_LOG="$IMG_TEST_LOG" \
      DW_IMG_RM_LOG="$IMG_TEST_RM_LOG" \
      DW_IMG_RUN_LOG="$IMG_TEST_RUN_LOG" \
      DW_IMG_EXEC_LOG="$IMG_TEST_EXEC_LOG" \
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

# --- コンテナが無い場合の docker run に label / マウント / workdir が正しく渡る（issue #30） ---
# これまで DW_IMG_RUN_LOG は記録するだけで一度もアサートしていなかった
# （label ベースの後片付け全体がこの配線に依存しているにもかかわらず）。
IMG_A_RUN_LINE="$(head -n1 "$IMG_TEST_RUN_LOG")"

case "$IMG_A_RUN_LINE" in
  *"--label dev-workflow.managed=1"*)
    pass "イメージ未存在時: docker run に --label dev-workflow.managed=1 が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に --label dev-workflow.managed=1 が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

case "$IMG_A_RUN_LINE" in
  *"--label dev-workflow.repo=${IMG_REPO_NAME}"*)
    pass "イメージ未存在時: docker run に --label dev-workflow.repo=<repo> が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に --label dev-workflow.repo=<repo> が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

case "$IMG_A_RUN_LINE" in
  *"--label dev-workflow.epic="*)
    pass "イメージ未存在時: docker run に --label dev-workflow.epic=<epic> が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に --label dev-workflow.epic=<epic> が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

case "$IMG_A_RUN_LINE" in
  *"--label dev-workflow.root=${IMG_HOST_ROOT}"*)
    pass "イメージ未存在時: docker run に --label dev-workflow.root=<host_root> が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に --label dev-workflow.root=<host_root> が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

case "$IMG_A_RUN_LINE" in
  *"-v ${IMG_MOUNT_SOURCE}:/workspace"*)
    pass "イメージ未存在時: docker run に -v <mount_source>:/workspace が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に -v <mount_source>:/workspace が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

IMG_A_EXEC_WORKDIR="$(head -n1 "$IMG_TEST_EXEC_LOG")"
assert_eq "イメージ未存在時: docker exec に解決済み workdir が -w で渡る（issue #30）" \
  "$IMG_WORKDIR" "$IMG_A_EXEC_WORKDIR"

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
# マウント元不一致による再作成の検証（issue #30）
#
# これまでの既存コンテナありケース（E・F）はどちらも container_mount に
# $IMG_MOUNT_SOURCE をそのまま渡しており、マウント元が期待値と異なる場合に
# 再作成される分岐（仕様書 4.3 の2。この Epic の「静かに間違ったツリーを
# 実行しない」ための本体）を検証するケースが存在しなかった。
#
# docker_desktop_equivalent は、実際の IMG_MOUNT_SOURCE の形式（Windows の
# pwd -W 形式か、Linux 等の素のパスか）に応じて「同一ツリーを指す別表現」を
# 作る。ドライブレター形式なら Docker Desktop の変換済みパス
# （/run/desktop/mnt/host/<drive>/...）へ、そうでなければバックスラッシュ区切りへ
# 変換する。どちらの実行環境でも normalize_mount_source が同一表現へ正規化する
# ことを、実際の sandbox-exec.sh（docker はモック）経由で確認するため。
# ---------------------------------------------------------------------------

docker_desktop_equivalent() {
  # docker_desktop_equivalent <mount_source>
  local src="$1" drive rest
  case "$src" in
    [A-Za-z]:/*|[A-Za-z]:)
      drive="${src%%:*}"
      rest="${src#*:}"
      drive="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
      printf '/run/desktop/mnt/host/%s%s' "$drive" "$rest"
      ;;
    *)
      printf '%s' "${src//\//\\}"
      ;;
  esac
}

IMG_MOUNT_EQUIVALENT="$(docker_desktop_equivalent "$IMG_MOUNT_SOURCE")"
IMG_G_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgg-stderr.XXXXXX")"

# --- (a) container_mount が MOUNT_SOURCE と異なる場合は削除して作り直す ---
IMG_G_EXIT=0
run_img_case 1 true "sha256:same" "${IMG_MOUNT_SOURCE}/different-tree" 1 "sha256:same" 'true' \
  2>"$IMG_G_STDERR_FILE" >/dev/null || IMG_G_EXIT=$?
assert_exit_code "マウント元不一致時: 実行全体が成功する（issue #30）" 0 "$IMG_G_EXIT"

IMG_G_RM_COUNT="$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "マウント元不一致時: 既存コンテナが削除される（issue #30）" "1" "$IMG_G_RM_COUNT"

IMG_G_RUN_COUNT="$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "マウント元不一致時: コンテナが作り直される（issue #30）" "1" "$IMG_G_RUN_COUNT"

IMG_G_STDERR="$(cat "$IMG_G_STDERR_FILE")"
case "$IMG_G_STDERR" in
  *"別ツリー実行の防止"*) pass "マウント元不一致時: 別ツリー実行の防止の警告が出る（issue #30）" ;;
  *) fail "マウント元不一致時: 別ツリー実行の防止の警告が出る（issue #30）" "stderr=[${IMG_G_STDERR}]" ;;
esac

# --- (b) Docker Desktop 形式（等）でも同一ツリーと判定され再作成されない ---
IMG_H_EXIT=0
run_img_case 1 true "sha256:same" "$IMG_MOUNT_EQUIVALENT" 1 "sha256:same" 'true' >/dev/null 2>&1 || IMG_H_EXIT=$?
assert_exit_code "マウント元が別表現でも同一ツリー時: 実行全体が成功する（issue #30）" 0 "$IMG_H_EXIT"

IMG_H_RM_COUNT="$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "マウント元が別表現（Docker Desktop 形式等）でも同一ツリーなら削除しない（issue #25 / #30）" "0" "$IMG_H_RM_COUNT"

IMG_H_RUN_COUNT="$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "マウント元が別表現（Docker Desktop 形式等）でも同一ツリーなら作り直さない（issue #25 / #30）" "0" "$IMG_H_RUN_COUNT"

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

# --- リポジトリ外の worktree（フォールバック）では compose_project も分離される（issue #27） ---
#
# 修正前は CONTAINER だけがフォールバック接尾辞で分離され、COMPOSE_PROJECT は
# 常に dw-<repo> のままだった。compose は project 名だけで既存サービスを探すため、
# リポジトリルートからの実行とリポジトリ外worktreeからの実行が同じ project を
# 共有してしまい、片方が起動した compose サービスへもう片方が警告なしに exec してしまう
# （実行系の再現テストは下記の compose_project 分離を前提にした別ケースで検証する）。
COMPOSE_OUTSIDE_WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-compose-outside.XXXXXX")"
make_worktree "$COMPOSE_REPO" "$COMPOSE_OUTSIDE_WORKTREE_DIR" "compose-outside-worktree-branch"

COMPOSE_CASE_OUTSIDE_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-compose-outside-stderr.XXXXXX")"
COMPOSE_CASE_OUTSIDE_OUTPUT="$(
  cd "$COMPOSE_OUTSIDE_WORKTREE_DIR" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan 2>"$COMPOSE_CASE_OUTSIDE_STDERR"
)"

assert_eq "compose: リポジトリ外worktreeでは fallback=1" "1" "$(plan_value fallback "$COMPOSE_CASE_OUTSIDE_OUTPUT")"

COMPOSE_OUTSIDE_PROJECT="$(plan_value compose_project "$COMPOSE_CASE_OUTSIDE_OUTPUT")"
COMPOSE_ROOT_PROJECT="$(plan_value compose_project "$COMPOSE_CASE1_OUTPUT")"
if [ "$COMPOSE_OUTSIDE_PROJECT" != "$COMPOSE_ROOT_PROJECT" ]; then
  pass "compose: リポジトリ外worktree（フォールバック）では compose_project が分離される（issue #27）"
else
  fail "compose: リポジトリ外worktree（フォールバック）では compose_project が分離される（issue #27）" \
    "compose_project=[${COMPOSE_OUTSIDE_PROJECT}]（共有 project と同一でした）"
fi

COMPOSE_OUTSIDE_CONTAINER="$(plan_value container "$COMPOSE_CASE_OUTSIDE_OUTPUT")"
COMPOSE_ROOT_CONTAINER="$(plan_value container "$COMPOSE_CASE1_OUTPUT")"
if [ "$COMPOSE_OUTSIDE_CONTAINER" != "$COMPOSE_ROOT_CONTAINER" ]; then
  pass "compose: リポジトリ外worktree（フォールバック）では container も分離される（issue #27）"
else
  fail "compose: リポジトリ外worktree（フォールバック）では container も分離される（issue #27）" \
    "container=[${COMPOSE_OUTSIDE_CONTAINER}]（共有コンテナと同一でした）"
fi

if [ -s "$COMPOSE_CASE_OUTSIDE_STDERR" ]; then
  pass "compose: リポジトリ外worktreeのフォールバック時に stderr へ警告する"
else
  fail "compose: リポジトリ外worktreeのフォールバック時に stderr へ警告する" "stderr が空でした"
fi

# ---------------------------------------------------------------------------
# compose モードの実行系（偽 docker で `docker compose` を模擬する）。
#
# 偽 docker は `compose -p PROJECT --project-directory DIR -f FILE <サブコマンド>...`
# を解釈し、状態ファイルでサービスの running / not-running を切り替える。
# 実際の docker には一切触れない。呼び出し引数は DW_COMPOSE_LOG にすべて記録する。
#
# DW_COMPOSE_MOUNT_SOURCE（既定は未設定=空）: `container inspect -f <Mountsを含むテンプレート>`
# の戻り値。既存サービスのマウント元検証（issue #27）を検証するために使う。
# `docker rm -f <id>` を呼ぶと状態ファイルを空にし、以後 running ではなくなったものとして扱う
# （issue #27 の「不一致なら削除して作り直す」を再現するため）。
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
MOUNT_SOURCE="${DW_COMPOSE_MOUNT_SOURCE:-}"
# issue #34 用: 「project|working_dir|running」形式のマニフェスト（1行1project）。
# list_compose_projects_in_repo() の top-level `docker ps -a --filter
# label=com.docker.compose.project ...` を模擬するために使う（未設定なら空扱い）。
PROJECTS_MANIFEST="${DW_COMPOSE_PROJECTS_MANIFEST:-}"
# issue #32 用: 1にすると一覧取得（label=com.docker.compose.project 単体フィルタ）を
# 実機で観測したテンプレート誤用と同様に失敗させ、非0終了 + stderr 出力を模擬する。
PS_FAIL="${DW_COMPOSE_PS_FAIL:-0}"

echo "$*" >> "$LOG"

case "${1:-}" in
  ps)
    shift
    filter=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -a) shift ;;
        --filter) filter="$2"; shift 2 ;;
        --format) shift 2 ;;
        *) shift ;;
      esac
    done
    case "$filter" in
      "label=com.docker.compose.project")
        if [ "$PS_FAIL" = "1" ]; then
          echo 'failed to execute template: error calling index: cannot index slice/array with type string' >&2
          exit 1
        fi
        # 自リポジトリ・他リポジトリ両方の compose project をマニフェストのまま返す。
        # どれを対象にするかは production 側（正規化して working_dir を判定）に委ねる。
        if [ -n "$PROJECTS_MANIFEST" ] && [ -f "$PROJECTS_MANIFEST" ]; then
          while IFS='|' read -r m_proj m_wd _m_running; do
            [ -n "$m_proj" ] || continue
            printf '%s|%s\n' "$m_proj" "$m_wd"
          done < "$PROJECTS_MANIFEST"
        fi
        exit 0
        ;;
      label=com.docker.compose.project=*)
        target_proj="${filter#label=com.docker.compose.project=}"
        if [ -n "$PROJECTS_MANIFEST" ] && [ -f "$PROJECTS_MANIFEST" ]; then
          while IFS='|' read -r m_proj _m_wd m_running; do
            [ "$m_proj" = "$target_proj" ] || continue
            [ "$m_running" = "running" ] && echo "fake-compose-container-id"
          done < "$PROJECTS_MANIFEST"
        fi
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
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
      down)
        printf '\n' > "$STATE_FILE"
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
    tmpl=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) tmpl="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    case "$tmpl" in
      *'Mounts'*)
        printf '%s\n' "$MOUNT_SOURCE"
        ;;
      *)
        state="$(cat "$STATE_FILE" 2>/dev/null || true)"
        if [ "$state" = "running" ]; then echo "true"; else echo "false"; fi
        ;;
    esac
    exit 0
    ;;
  rm)
    shift
    # `docker rm -f <id>`。マウント元不一致で再作成する際に呼ばれる（issue #27）。
    # 実際の docker には触れず、状態ファイルを空にして「削除済み」を再現する。
    printf '\n' > "$STATE_FILE"
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
  # 環境変数 COMPOSE_TEST_MOUNT_SOURCE が設定されていれば、既存サービスのマウント元検証
  # （issue #27）を再現するための DW_COMPOSE_MOUNT_SOURCE として渡す（未設定なら空のまま）。
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
      DW_COMPOSE_MOUNT_SOURCE="${COMPOSE_TEST_MOUNT_SOURCE:-}" \
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
# 既存サービスが running でも、マウント元が期待値（MOUNT_SOURCE）と異なれば削除して
# 作り直す（issue #27）。フォールバック時の compose_project 分離（本コミットで修正済み）が
# 主たる対策だが、その二重チェックとして dockerfile モードと同様の検証をここでも固定する。
# ---------------------------------------------------------------------------

echo "== compose: 既存サービスのマウント元検証（issue #27） =="

COMPOSE_TEST_MOUNT_SOURCE="/some/other/tree"
COMPOSE_MISMATCH_STDERR="$(run_compose_case "$COMPOSE_REPO" "running" 1 1 'true' 2>&1 1>/dev/null)"
COMPOSE_MISMATCH_EXIT=$?
unset COMPOSE_TEST_MOUNT_SOURCE

assert_exit_code "compose: マウント元不一致を検出して削除・作り直し後に成功する（issue #27）" 0 "$COMPOSE_MISMATCH_EXIT"

case "$COMPOSE_MISMATCH_STDERR" in
  *"マウント元"*"削除して作り直します"*)
    pass "compose: 既存サービスのマウント元不一致を検出して警告する（issue #27）" ;;
  *)
    fail "compose: 既存サービスのマウント元不一致を検出して警告する（issue #27）" \
      "stderr=[${COMPOSE_MISMATCH_STDERR}]" ;;
esac

if grep -q '^rm -f fake-compose-container-id$' "$COMPOSE_TEST_LOG"; then
  pass "compose: マウント元不一致の既存コンテナを docker rm -f で削除する（issue #27）"
else
  fail "compose: マウント元不一致の既存コンテナを docker rm -f で削除する（issue #27）" \
    "log=[$(cat "$COMPOSE_TEST_LOG")]"
fi

if grep -q ' up -d app$' "$COMPOSE_TEST_LOG"; then
  pass "compose: マウント元不一致で削除した後は up -d で作り直す（issue #27）"
else
  fail "compose: マウント元不一致で削除した後は up -d で作り直す（issue #27）" \
    "log=[$(cat "$COMPOSE_TEST_LOG")]"
fi

# --- マウント元が一致していれば、running なサービスを削除せず再利用する（回帰防止） ---
COMPOSE_TEST_MOUNT_SOURCE="$COMPOSE_HOST_ROOT"
COMPOSE_MATCH_EXIT=0
run_compose_case "$COMPOSE_REPO" "running" 1 1 'true' >/dev/null 2>&1 || COMPOSE_MATCH_EXIT=$?
unset COMPOSE_TEST_MOUNT_SOURCE

assert_exit_code "compose: マウント元一致時は成功する" 0 "$COMPOSE_MATCH_EXIT"

if grep -q '^rm -f fake-compose-container-id$' "$COMPOSE_TEST_LOG"; then
  fail "compose: マウント元が一致していれば既存コンテナを削除しない（回帰防止）" \
    "log=[$(cat "$COMPOSE_TEST_LOG")]"
else
  pass "compose: マウント元が一致していれば既存コンテナを削除しない（回帰防止）"
fi

# ---------------------------------------------------------------------------
# --down が compose モードのとき docker compose down を -p / --project-directory 付きで
# 呼ぶことを固定する（issue #28）。本 Epic で compose モードは対象サービスが running で
# なければ up -d を自動実行するようになった一方、以前の --down は dw-sandbox-* という
# 名前のコンテナしか削除せず、compose が起動したコンテナを落とす主体がいなかった。
# ---------------------------------------------------------------------------

echo "== compose: --down（issue #28） =="

COMPOSE_DOWN_EXIT=0
COMPOSE_DOWN_STDOUT="$(run_compose_case "$COMPOSE_REPO" "running" 1 1 --down 2>/dev/null)" || COMPOSE_DOWN_EXIT=$?
assert_exit_code "compose: --down は成功する（issue #28）" 0 "$COMPOSE_DOWN_EXIT"

case "$(cat "$COMPOSE_TEST_LOG")" in
  *"compose -p dw-${COMPOSE_REPO_BASENAME} --project-directory ${COMPOSE_HOST_ROOT} -f docker-compose.dev.yml down"*)
    pass "compose: --down は docker compose down を -p / --project-directory 付きで呼ぶ（issue #28）" ;;
  *)
    fail "compose: --down は docker compose down を -p / --project-directory 付きで呼ぶ（issue #28）" \
      "log=[$(cat "$COMPOSE_TEST_LOG")]" ;;
esac

case "$COMPOSE_DOWN_STDOUT" in
  *"dw-${COMPOSE_REPO_BASENAME}"*) pass "compose: --down の出力に project 名が表示される（issue #28）" ;;
  *) fail "compose: --down の出力に project 名が表示される（issue #28）" "output=[${COMPOSE_DOWN_STDOUT}]" ;;
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
# check-readability.sh: 複数行フックJSONの読み取り（回帰防止 #31）
#
# Task #10 のハング修正で stdin を「上限付きで読む」形にした際、実装が
# `read -r -t` を1回しか呼ばず先頭1行しか読んでいなかった。フック入力は
# 整形された（複数行の）JSONで来ることがあり、1行目に file_path が無い場合
# 検査対象を取りこぼして警告もログも無く exit 0 してしまう欠陥があった
# （可読性ガードが最優先で守るルールが、入力形式の差で黙って無効化される）。
#
# ここでは stdin 全体をタイムアウト付きで読み切る修正後の実装が、
#   1) 複数行JSONでも file_path を抽出して違反を検出できること
#   2) 1行目に file_path が無い複数行JSONでも検出できること
#   3) Task #10 で固定した「stdinを開いたままでもハングしない」性質を
#      壊していないこと
# を確認する。
# ---------------------------------------------------------------------------

echo "== check-readability.sh（複数行フックJSONの読み取り・回帰防止 #31） =="

RG31_TMP_REPO="$(make_temp_repo)"
RG31_VIOLATION_FILE="violation.txt"
(
  cd "$RG31_TMP_REPO" || exit 1
  head -c 3000 /dev/zero | tr '\0' 'A' > "$RG31_VIOLATION_FILE"
) >/dev/null 2>&1

# --- 整形された（複数行の）フックJSON。file_path は先頭行ではなく途中の行にある ---
RG31_MULTILINE_JSON=$(cat <<EOF
{
  "session_id": "abc123",
  "tool_input": {
    "file_path": "${RG31_VIOLATION_FILE}"
  },
  "tool_name": "Write"
}
EOF
)

RG31_MULTILINE_EXIT=0
(
  cd "$RG31_TMP_REPO" || exit 1
  printf '%s' "$RG31_MULTILINE_JSON" \
    | READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG31_MULTILINE_EXIT=$?
assert_exit_code "複数行に整形されたフックJSONでもfile_pathを抽出して違反を検出する" 2 "$RG31_MULTILINE_EXIT"

# --- 1行目に file_path が無い複数行JSON（file_path はJSONの末尾近くの行にある） ---
RG31_LATE_FIELD_JSON=$(cat <<EOF
{
  "session_id": "abc123",
  "cwd": "/tmp/somewhere",
  "hook_event_name": "PostToolUse",
  "tool_name": "Write",
  "tool_input": {
    "content": "dummy",
    "file_path": "${RG31_VIOLATION_FILE}"
  }
}
EOF
)

RG31_LATE_FIELD_EXIT=0
(
  cd "$RG31_TMP_REPO" || exit 1
  printf '%s' "$RG31_LATE_FIELD_JSON" \
    | READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG31_LATE_FIELD_EXIT=$?
assert_exit_code "1行目にfile_pathが無い複数行JSONでも検出できる" 2 "$RG31_LATE_FIELD_EXIT"

# --- 上記と同じ複数行JSONで、クリーンなファイルならexit 0（誤検出しないことの確認） ---
RG31_CLEAN_FILE="clean-multiline.txt"
(
  cd "$RG31_TMP_REPO" || exit 1
  printf 'clean file\n' > "$RG31_CLEAN_FILE"
) >/dev/null 2>&1

RG31_CLEAN_MULTILINE_JSON=$(cat <<EOF
{
  "session_id": "abc123",
  "tool_input": {
    "file_path": "${RG31_CLEAN_FILE}"
  }
}
EOF
)

RG31_CLEAN_MULTILINE_EXIT=0
(
  cd "$RG31_TMP_REPO" || exit 1
  printf '%s' "$RG31_CLEAN_MULTILINE_JSON" | bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG31_CLEAN_MULTILINE_EXIT=$?
assert_exit_code "複数行JSONでもクリーンなファイルはexit 0（誤検出しない）" 0 "$RG31_CLEAN_MULTILINE_EXIT"

# --- Task #10 の性質を壊していないことの再確認: stdinを開いたまま --git を叩いても即座に返る ---
# RG31_TMP_REPO には未追跡の違反ファイル（violation.txt等）があるため、
# --git で検査すれば違反検出（exit 2）になり得る。ここで確認したいのは
# 「ハングしないこと」だけなので、違反ファイルの無いクリーンな一時リポジトリを別途使う。
RG31_HANG_REPO="$(make_temp_repo)"
RG31_GIT_HANG_EXIT=0
(
  cd "$RG31_HANG_REPO" || exit 1
  timeout 8 bash "$CHECK_READABILITY_SCRIPT" --git < <(sleep 30) >/dev/null 2>&1
)
RG31_GIT_HANG_EXIT=$?
assert_exit_code "stdinを開いたまま--gitを叩いても即座に返る（ハング再発なし）" 0 "$RG31_GIT_HANG_EXIT"

# --- 引数なし・非ttyで入力が来ない場合も、複数行読み取りに変えた後で引き続きタイムアウトする ---
RG31_TIMEOUT_EXIT=0
(
  cd "$RG31_HANG_REPO" || exit 1
  timeout 8 env READABILITY_STDIN_TIMEOUT=1 bash "$CHECK_READABILITY_SCRIPT" \
    < <(sleep 30) >/dev/null 2>&1
)
RG31_TIMEOUT_EXIT=$?
assert_exit_code "複数行読み取りに変えた後も、入力が来ない場合はタイムアウトしてexit 0で素通りする" 0 "$RG31_TIMEOUT_EXIT"

# ---------------------------------------------------------------------------
# compose: --down --all / --ls の project 絞り込み（レビュー2巡目 issue #32 / #33 / #34）
#
# list_compose_projects_in_repo() は本Epicのレビューで次の2点を指摘された:
#   - issue #32: docker ps のフォーマットで `{{ index .Labels "..." }}` を使っていたが、
#     `docker ps` コンテキストでは .Labels は map ではなく文字列であり必ず失敗する。
#     正しくは `{{.Label "..."}}`。失敗を 2>/dev/null で握り潰さず、非0終了時は
#     stderr に警告を出すことも合わせて固定する。
#   - issue #33: 絞り込みが project 名の接頭辞一致だけで、他リポジトリ（basename が
#     接頭辞になる／同じ basename を別ディレクトリにクローンした）の project を
#     巻き込みうる。正しくは com.docker.compose.project.working_dir label
#     （--project-directory に渡した値）を正規化して HOST_ROOT 配下のものだけを対象にする。
#
# 上記2つの穴は、偽 docker が compose モードの `ps`（-a なし・ありの両方）を
# 未実装（*) exit 1）だったため一度もテストされていなかった（issue #34）。
# FAKE_DOCKER_COMPOSE に「project|working_dir|running」形式のマニフェストで駆動する
# ps 実装を追加した（DW_COMPOSE_PROJECTS_MANIFEST）ので、ここでそれを使って固定する。
# 実 docker には一切触れない。
# ---------------------------------------------------------------------------

echo "== compose: --down --all / --ls の project 絞り込み（issue #32 / #33 / #34） =="

COMPOSE_PROJECTS_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-composeprojlog.XXXXXX")"
COMPOSE_PROJECTS_STATE="$(mktemp "${TMPDIR:-/tmp}/dw-test-composeprojstate.XXXXXX")"
: > "$COMPOSE_PROJECTS_STATE"

COMPOSE_PROJECTS_MANIFEST_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-composeprojects.XXXXXX")"

# 他リポジトリのマウント元は正規化後も HOST_ROOT と一致しない、実在しないダミーパスでよい。
COMPOSE_OTHER_CLONE_ROOT="/some/other/clone/root"
COMPOSE_UNRELATED_ROOT="/home/user/otherrepo"

# 1) 自リポジトリ・epicなし（--project-directory は常に HOST_ROOT）
# 2) 自リポジトリ・epicあり（working_dir は同じ HOST_ROOT）
# 3) 他リポジトリ。project 名は自リポジトリの basename が接頭辞になっている
#    （旧・接頭辞一致ロジックなら誤って巻き込んでいた。working_dir は無関係な別root）
# 4) 自リポジトリと「同名」の project だが working_dir が別root
#    （同じ basename を別ディレクトリにクローンした場合を模す。issue #33 (b) / (c)）
# 5) 全く無関係な他リポジトリ
cat > "$COMPOSE_PROJECTS_MANIFEST_FILE" <<MANIFEST
dw-${COMPOSE_REPO_BASENAME}|${COMPOSE_HOST_ROOT}|running
dw-${COMPOSE_REPO_BASENAME}-epicx|${COMPOSE_HOST_ROOT}|stopped
dw-${COMPOSE_REPO_BASENAME}-otherclone|${COMPOSE_OTHER_CLONE_ROOT}|running
dw-${COMPOSE_REPO_BASENAME}|${COMPOSE_OTHER_CLONE_ROOT}|running
dw-otherrepo|${COMPOSE_UNRELATED_ROOT}|running
MANIFEST

run_compose_projects_case() {
  # run_compose_projects_case <sandbox-exec.shへの引数...>
  (
    cd "$COMPOSE_REPO" || exit 1
    DW_COMPOSE_LOG="$COMPOSE_PROJECTS_LOG" \
      DW_COMPOSE_SERVICE_STATE="$COMPOSE_PROJECTS_STATE" \
      DW_COMPOSE_PROJECTS_MANIFEST="$COMPOSE_PROJECTS_MANIFEST_FILE" \
      PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh "$@"
  )
}

# --- --ls は自リポジトリの compose project の状態のみ表示する（issue #34 の3点目） ---
: > "$COMPOSE_PROJECTS_LOG"
COMPOSE_LS_OUTPUT="$(run_compose_projects_case --ls)"

case "$COMPOSE_LS_OUTPUT" in
  *"dw-${COMPOSE_REPO_BASENAME}"*"running"*)
    pass "compose: --ls は自リポジトリの compose project を running で表示する" ;;
  *)
    fail "compose: --ls は自リポジトリの compose project を running で表示する" \
      "output=[${COMPOSE_LS_OUTPUT}]" ;;
esac

case "$COMPOSE_LS_OUTPUT" in
  *"dw-${COMPOSE_REPO_BASENAME}-epicx"*"stopped"*)
    pass "compose: --ls は自リポジトリの別epic project を stopped で表示する" ;;
  *)
    fail "compose: --ls は自リポジトリの別epic project を stopped で表示する" \
      "output=[${COMPOSE_LS_OUTPUT}]" ;;
esac

if printf '%s\n' "$COMPOSE_LS_OUTPUT" | grep -q "otherclone"; then
  fail "compose: --ls は basename が接頭辞一致するだけの他リポジトリ project を表示しない（issue #33）" \
    "output=[${COMPOSE_LS_OUTPUT}]"
else
  pass "compose: --ls は basename が接頭辞一致するだけの他リポジトリ project を表示しない（issue #33）"
fi

if printf '%s\n' "$COMPOSE_LS_OUTPUT" | grep -q "otherrepo"; then
  fail "compose: --ls は無関係な他リポジトリ project を表示しない" "output=[${COMPOSE_LS_OUTPUT}]"
else
  pass "compose: --ls は無関係な他リポジトリ project を表示しない"
fi

# --- --down --all は自リポジトリの project すべてを down し、他リポジトリは down しない（issue #34 の1・2点目） ---
: > "$COMPOSE_PROJECTS_LOG"
COMPOSE_DOWN_ALL_EXIT=0
run_compose_projects_case --down --all >/dev/null 2>&1 || COMPOSE_DOWN_ALL_EXIT=$?
assert_exit_code "compose: --down --all は成功する" 0 "$COMPOSE_DOWN_ALL_EXIT"

DOWN_ALL_LOG_CONTENT="$(cat "$COMPOSE_PROJECTS_LOG")"

DOWN_COUNT_SELF_NOEPIC="$(printf '%s\n' "$DOWN_ALL_LOG_CONTENT" \
  | grep -Fc "compose -p dw-${COMPOSE_REPO_BASENAME} --project-directory ${COMPOSE_HOST_ROOT} -f docker-compose.dev.yml down" || true)"
assert_eq "compose: --down --all は自リポジトリの project（epicなし）を down する（issue #34）" "1" "$DOWN_COUNT_SELF_NOEPIC"

DOWN_COUNT_SELF_EPIC="$(printf '%s\n' "$DOWN_ALL_LOG_CONTENT" \
  | grep -Fc "compose -p dw-${COMPOSE_REPO_BASENAME}-epicx --project-directory ${COMPOSE_HOST_ROOT} -f docker-compose.dev.yml down" || true)"
assert_eq "compose: --down --all は自リポジトリの別epic project も down する（issue #34）" "1" "$DOWN_COUNT_SELF_EPIC"

if printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -q "otherclone"; then
  fail "compose: --down --all は basename が接頭辞一致するだけの他リポジトリ project を down しない（issue #33）" \
    "log=[${DOWN_ALL_LOG_CONTENT}]"
else
  pass "compose: --down --all は basename が接頭辞一致するだけの他リポジトリ project を down しない（issue #33）"
fi

if printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -q "otherrepo"; then
  fail "compose: --down --all は無関係な他リポジトリ project を down しない" "log=[${DOWN_ALL_LOG_CONTENT}]"
else
  pass "compose: --down --all は無関係な他リポジトリ project を down しない"
fi

# 同名別root（issue #33 (b)/(c)）: 自プロジェクトと同一名だが working_dir が別のエントリが
# マニフェストに混在していても、down 呼び出しの総数は自リポジトリ分の2件のまま増えない。
DOWN_TOTAL_COUNT="$(printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -c '^compose -p .* down$' || true)"
assert_eq "compose: --down --all は同名別rootの混在があっても自リポジトリ分の2件だけを down する（issue #33）" \
  "2" "$DOWN_TOTAL_COUNT"

# --- issue #32 の直接検証: docker ps のフォーマットに .Label を使い、.Labels は使わない ---
if printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -qF '.Label "com.docker.compose.project"'; then
  pass "compose: docker ps のフォーマットに .Label を使う（issue #32）"
else
  fail "compose: docker ps のフォーマットに .Label を使う（issue #32）" "log=[${DOWN_ALL_LOG_CONTENT}]"
fi

if printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -qF 'index .Labels'; then
  fail "compose: docker ps のフォーマットに index .Labels を使わない（issue #32）" "log=[${DOWN_ALL_LOG_CONTENT}]"
else
  pass "compose: docker ps のフォーマットに index .Labels を使わない（issue #32）"
fi

# --- issue #32: docker ps 失敗時は stderr に警告を出し、--ls 自体は非0で落ちない ---
: > "$COMPOSE_PROJECTS_LOG"
COMPOSE_PS_FAIL_STDERR="$(
  cd "$COMPOSE_REPO" || exit 1
  DW_COMPOSE_LOG="$COMPOSE_PROJECTS_LOG" \
    DW_COMPOSE_SERVICE_STATE="$COMPOSE_PROJECTS_STATE" \
    DW_COMPOSE_PROJECTS_MANIFEST="$COMPOSE_PROJECTS_MANIFEST_FILE" \
    DW_COMPOSE_PS_FAIL=1 \
    PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --ls 2>&1 1>/dev/null
)"

case "$COMPOSE_PS_FAIL_STDERR" in
  *"WARNING"*"docker ps"*)
    pass "compose: docker ps の失敗を握り潰さず stderr に警告する（issue #32）" ;;
  *)
    fail "compose: docker ps の失敗を握り潰さず stderr に警告する（issue #32）" \
      "stderr=[${COMPOSE_PS_FAIL_STDERR}]" ;;
esac

COMPOSE_PS_FAIL_EXIT=0
(
  cd "$COMPOSE_REPO" || exit 1
  DW_COMPOSE_LOG="$COMPOSE_PROJECTS_LOG" \
    DW_COMPOSE_SERVICE_STATE="$COMPOSE_PROJECTS_STATE" \
    DW_COMPOSE_PROJECTS_MANIFEST="$COMPOSE_PROJECTS_MANIFEST_FILE" \
    DW_COMPOSE_PS_FAIL=1 \
    PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --ls >/dev/null 2>&1
)
COMPOSE_PS_FAIL_EXIT=$?
assert_exit_code "compose: docker ps の列挙に失敗しても --ls 自体は成功する（compose project欄なしで継続）" \
  0 "$COMPOSE_PS_FAIL_EXIT"

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
