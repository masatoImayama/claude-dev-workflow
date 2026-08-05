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

assert_no_hang() {
  # assert_no_hang <説明> <期待する終了コード> <実際の終了コード> <実際のstderr(またはstdout+stderr)> <stderrに含まれるべき文字列>
  #
  # 「無限ループしない（ハングしない）」ことを検証するテストは `timeout` でコマンドを
  # 打ち切って回帰を防ぐが、timeout がタイムアウト時に返す終了コードは環境依存
  # （GNU coreutils=124, BusyBox=143 など SIGTERM由来の 128+シグナル番号）であり、
  # 「タイムアウトで打ち切られた（=ハングしたまま殺された）」ことを終了コードだけで
  # 判定できない。ハングした場合はエラーメッセージも出力されないため、
  # 「期待する終了コードちょうどであること」と「期待するエラーメッセージが出ていること」の
  # 両方を assert することで、ハング（timeoutによる強制終了）を確実に不合格にする。
  local desc="$1" expected_exit="$2" actual_exit="$3" actual_output="$4" expected_msg="$5"
  if [ "$actual_exit" -eq "$expected_exit" ] && printf '%s' "$actual_output" | grep -Fq -- "$expected_msg"; then
    pass "$desc"
  else
    fail "$desc" "expected exit=${expected_exit}（メッセージに[${expected_msg}]を含む） actual exit=${actual_exit} output=[${actual_output}]"
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
# （実測: timeout 8 bash scripts/sandbox-exec.sh --epic は exit 124 だった。
# ただし sandbox 内の BusyBox timeout は exit 143 を返すため、終了コードのみでは
# 「ハングして timeout に強制終了させられた」ことを判定できない。詳細は assert_no_hang 参照）。
if command -v timeout >/dev/null 2>&1; then
  EPIC_NO_VALUE_STDERR="$(
    cd "$PRINT_PLAN_REPO" || exit 1
    PATH="${FAKE_BIN_DIR}:${PATH}" timeout 8 bash scripts/sandbox-exec.sh --epic 2>&1 1>/dev/null
  )"
  EPIC_NO_VALUE_EXIT=$?

  assert_no_hang "--epic に値が無い場合は無限ループせず exit 2 かつ --epic の記載があるエラーで停止する" \
    2 "$EPIC_NO_VALUE_EXIT" "$EPIC_NO_VALUE_STDERR" "--epic には値が必要です"
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
# ケース7c: dev_workflow_marker_root（マーカー置き場の解決・外部プロセス0、Task #43）
#
# heartbeat.sh（フックから高頻度に呼ばれる。Phase 2 で追加予定）の前提として、この関数は
# 解決処理の中で外部プロセスを一切起動しない。worktree の .git は
# `gitdir: <メインリポ>/.git/worktrees/<名前>` という1行ファイルなので bash の read だけで
# 解析できる（Epic #42 仕様書「3. ファイルと責務」）。
#
# ---------------------------------------------------------------------------

echo "== dev_workflow_marker_root（マーカー置き場の解決・外部プロセス0・Task #43） =="

MARKER_ROOT_LIB="${REPO_ROOT}/scripts/lib/marker-root.sh"

# shellcheck source=../scripts/lib/marker-root.sh
. "$MARKER_ROOT_LIB"

canon_root() {
  # canon_root <dir>  ディレクトリの正規化された絶対パスを返す（pwd -W があれば使う）
  (
    cd "$1" 2>/dev/null || exit 1
    pwd -W 2>/dev/null || pwd
  )
}

# Windows では mktemp が /tmp 配下（MSYS のエイリアス）を返すことがあり、これは
# dev_workflow_marker_root の -d .git 分岐（渡された表現をそのまま返す）と、
# .git ファイル分岐（git 自身が書いた実パスを読む。Windows では常にドライブレター形式）とで
# 表現が食い違う原因になる（実機で確認済み。ドライブレター形式どうしの揺れは
# _dev_workflow_marker_root_normalize が吸収するが、/tmp エイリアスの実パスへの
# 解決は対象外＝コマンド置換なしでは原理的にできない）。
# そのため一時リポジトリのパスは最初に canon_root で実パスへ正規化してから使う。
MR_REPO="$(canon_root "$(make_temp_repo)")"
MR_EXPECTED="$MR_REPO"

assert_eq "dev_workflow_marker_root: メインリポのルートで正しいパスを返す" \
  "$MR_EXPECTED" "$(dev_workflow_marker_root "$MR_REPO")"

mkdir -p "${MR_REPO}/sub/dir"
assert_eq "dev_workflow_marker_root: メインリポのサブディレクトリから呼んでもルートを返す" \
  "$MR_EXPECTED" "$(dev_workflow_marker_root "${MR_REPO}/sub/dir")"

MR_EPIC_WT="${MR_REPO}/.claude/worktrees/epic9"
make_worktree "$MR_REPO" "$MR_EPIC_WT" "mr-epic-branch"
assert_eq "dev_workflow_marker_root: epic worktree（.claude/worktrees/epicN）からメインリポのルートを返す" \
  "$MR_EXPECTED" "$(dev_workflow_marker_root "$MR_EPIC_WT")"

MR_AGENT_WT="${MR_REPO}/.claude/worktrees/agent-x"
make_worktree "$MR_REPO" "$MR_AGENT_WT" "mr-agent-branch"
assert_eq "dev_workflow_marker_root: agent worktree（.claude/worktrees/agent-xxx）からメインリポのルートを返す" \
  "$MR_EXPECTED" "$(dev_workflow_marker_root "$MR_AGENT_WT")"

MR_NONGIT="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-nongit.XXXXXX")"
MR_NONGIT_OUT="$(dev_workflow_marker_root "$MR_NONGIT")"
MR_NONGIT_EXIT=$?
assert_eq "dev_workflow_marker_root: git 管理外のディレクトリでは空文字を返す" "" "$MR_NONGIT_OUT"
assert_exit_code "dev_workflow_marker_root: git 管理外のディレクトリでは非0終了する" 1 "$MR_NONGIT_EXIT"

MR_OVERRIDE_VALUE="/custom/marker/root/for/test"
MR_OVERRIDE_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$MR_OVERRIDE_VALUE" dev_workflow_marker_root "$MR_REPO")"
assert_eq "dev_workflow_marker_root: DEV_WORKFLOW_MARKER_ROOT が最優先で使われる" \
  "$MR_OVERRIDE_VALUE" "$MR_OVERRIDE_OUT"

# CLAUDE_PROJECT_DIR はそのまま使う仕様（正規化しない）なので、既に実パス化済みの
# $MR_REPO をそのまま渡す。
MR_CLAUDE_PROJECT_OUT="$(CLAUDE_PROJECT_DIR="$MR_REPO" dev_workflow_marker_root "${MR_REPO}/sub/dir")"
assert_eq "dev_workflow_marker_root: CLAUDE_PROJECT_DIR 直下に .git があればそれを使う" \
  "$MR_EXPECTED" "$MR_CLAUDE_PROJECT_OUT"

# --- 解決処理が外部コマンド・コマンド置換を一切起動していないことの静的確認 ---
# コメント行は対象外にし、単語境界での一致だけを見る
# （"gitdir:" 等の識別子内の "git" 部分文字列や、算術展開 $(( )) の "$(" を
# 誤検知しないよう、"git "は後ろに空白を要求し、"$(" は直後が "(" でないものだけを見る）
MR_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$MARKER_ROOT_LIB" \
  | grep -E '(^|[^A-Za-z0-9_])(git|sed|dirname|basename)[[:space:]]|\$\([^(]|`' || true)"
if [ -z "$MR_FORBIDDEN_HITS" ]; then
  pass "dev_workflow_marker_root: 解決処理が外部コマンド・コマンド置換を使っていない"
else
  fail "dev_workflow_marker_root: 解決処理が外部コマンド・コマンド置換を使っていない" "$MR_FORBIDDEN_HITS"
fi

# --- 性能: 100回呼び出しが十分速いこと（外部プロセス0の下地。受け入れ条件10） ---
MR_PERF_START=""
printf -v MR_PERF_START '%(%s)T' -1
MR_PERF_I=0
while [ "$MR_PERF_I" -lt 100 ]; do
  dev_workflow_marker_root "$MR_EPIC_WT" >/dev/null
  MR_PERF_I=$((MR_PERF_I + 1))
done
MR_PERF_END=""
printf -v MR_PERF_END '%(%s)T' -1
MR_PERF_ELAPSED=$((MR_PERF_END - MR_PERF_START))
if [ "$MR_PERF_ELAPSED" -lt 2 ]; then
  pass "dev_workflow_marker_root: 100回呼び出しが2秒未満（実測 ${MR_PERF_ELAPSED}s、外部プロセス0の下地・受け入れ条件10）"
else
  fail "dev_workflow_marker_root: 100回呼び出しが2秒未満" "実測 ${MR_PERF_ELAPSED}s"
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
# optional_tools_notice（任意ツールの非ブロッキング検出、Epic #66 Phase1・Task #68）
#
# context7 / code-review-graph の導入状況（docs/optional-mcp-tools.md「## 申し送りに対してどう応えたか
# （#80 レビュー対応）」節のとおり、dev-workflowが実際に`command`へ指定するコマンド名:
# context7-mcp / code-review-graph）を command -v で判定する純粋関数。`npx`はNode.js同梱でほぼ
# 常に存在し「context7 = 常に導入済み」と誤判定するため使わない（レビュー指摘 #82）。
# crlf_warning_message と同じく check-prerequisites.sh を source して単体テストする。
# ---------------------------------------------------------------------------

echo "== optional_tools_notice（任意ツールの非ブロッキング検出。Task #68） =="

make_tool_stub_dir() {
  # make_tool_stub_dir <ツール名...>  指定した名前の実行可能スタブだけを持つ一時ディレクトリを作る。
  local dir tool
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-optional-tools.XXXXXX")"
  for tool in "$@"; do
    cat > "${dir}/${tool}" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "${dir}/${tool}"
  done
  printf '%s' "$dir"
}

optional_tools_notice_with_path() {
  # optional_tools_notice_with_path <PATH>
  # 指定した PATH だけを使って optional_tools_notice を呼び出し、標準出力を返す（stderr は捨てる）。
  # 関数内部は command -v の判定しか行わないため、PATH をこのスタブだけに絞っても安全。
  local fake_path="$1"
  (
    # shellcheck source=../scripts/check-prerequisites.sh
    source "$CHECK_PREREQS_SCRIPT"
    PATH="$fake_path" optional_tools_notice
  ) 2>/dev/null
}

# --- 両方とも利用可能な環境では何も出力しない ---
OPT_TOOLS_BOTH_DIR="$(make_tool_stub_dir context7-mcp code-review-graph)"
OPT_TOOLS_BOTH_NOTICE="$(optional_tools_notice_with_path "$OPT_TOOLS_BOTH_DIR")"
assert_eq "context7 / code-review-graph が両方利用可能なら何も出力しない" "" "$OPT_TOOLS_BOTH_NOTICE"

# --- context7 のみ未導入な環境では、context7 と「従来どおり」を含む警告を返す ---
OPT_TOOLS_NO_CONTEXT7_DIR="$(make_tool_stub_dir code-review-graph)"
OPT_TOOLS_NO_CONTEXT7_NOTICE="$(optional_tools_notice_with_path "$OPT_TOOLS_NO_CONTEXT7_DIR")"

case "$OPT_TOOLS_NO_CONTEXT7_NOTICE" in
  *"context7"*) pass "context7 未導入時、警告に context7 という文字列が含まれる" ;;
  *) fail "context7 未導入時、警告に context7 という文字列が含まれる" "notice=[${OPT_TOOLS_NO_CONTEXT7_NOTICE}]" ;;
esac

case "$OPT_TOOLS_NO_CONTEXT7_NOTICE" in
  *"従来どおり"*) pass "context7 未導入時、警告に『従来どおり』の文言が含まれる" ;;
  *) fail "context7 未導入時、警告に『従来どおり』の文言が含まれる" "notice=[${OPT_TOOLS_NO_CONTEXT7_NOTICE}]" ;;
esac

case "$OPT_TOOLS_NO_CONTEXT7_NOTICE" in
  *"code-review-graph"*) fail "context7 のみ未導入なら code-review-graph には言及しない" "notice=[${OPT_TOOLS_NO_CONTEXT7_NOTICE}]" ;;
  *) pass "context7 のみ未導入なら code-review-graph には言及しない" ;;
esac

# --- code-review-graph のみ未導入な環境でも同様（片方が未導入なら未導入分だけ列挙する） ---
OPT_TOOLS_NO_CRG_DIR="$(make_tool_stub_dir context7-mcp)"
OPT_TOOLS_NO_CRG_NOTICE="$(optional_tools_notice_with_path "$OPT_TOOLS_NO_CRG_DIR")"

case "$OPT_TOOLS_NO_CRG_NOTICE" in
  *"code-review-graph"*) pass "code-review-graph 未導入時、警告に code-review-graph という文字列が含まれる" ;;
  *) fail "code-review-graph 未導入時、警告に code-review-graph という文字列が含まれる" "notice=[${OPT_TOOLS_NO_CRG_NOTICE}]" ;;
esac

case "$OPT_TOOLS_NO_CRG_NOTICE" in
  *"従来どおり"*) pass "code-review-graph 未導入時、警告に『従来どおり』の文言が含まれる" ;;
  *) fail "code-review-graph 未導入時、警告に『従来どおり』の文言が含まれる" "notice=[${OPT_TOOLS_NO_CRG_NOTICE}]" ;;
esac

# --- レビュー指摘 #82 の再発防止: npx はあるが context7-mcp が無い環境では、
#     context7 が「未導入」と正しく通知されること（npx の有無を context7 の代わりに
#     見てしまう歪みが直したはずなのに戻っていないかを検出する） ---
OPT_TOOLS_NPX_ONLY_DIR="$(make_tool_stub_dir npx code-review-graph)"
OPT_TOOLS_NPX_ONLY_NOTICE="$(optional_tools_notice_with_path "$OPT_TOOLS_NPX_ONLY_DIR")"

case "$OPT_TOOLS_NPX_ONLY_NOTICE" in
  *"context7"*) pass "npx はあるが context7-mcp が無い環境で、context7 が未導入と正しく通知される（#82再発防止）" ;;
  *) fail "npx はあるが context7-mcp が無い環境で、context7 が未導入と正しく通知される（#82再発防止）" \
    "notice=[${OPT_TOOLS_NPX_ONLY_NOTICE}]" ;;
esac

case "$OPT_TOOLS_NPX_ONLY_NOTICE" in
  *"code-review-graph"*) fail "npx はあるが context7-mcp が無い環境で、code-review-graph には言及しない（#82再発防止）" \
    "notice=[${OPT_TOOLS_NPX_ONLY_NOTICE}]" ;;
  *) pass "npx はあるが context7-mcp が無い環境で、code-review-graph には言及しない（#82再発防止）" ;;
esac

# --- 両方未導入でも check-prerequisites.sh 全体の終了コードは 2 にならない ---
#
# 他の必須依存（gh/docker）は満たされている前提を再現するため、CRLF警告テストと同じ
# 偽 gh / 偽 docker を使う。context7-mcp / code-review-graph が「未導入」であることを
# 環境非依存で保証するため、実際の $PATH からこの2つの実行ファイルを含むディレクトリだけを
# 取り除いた PATH を組み立てる（git / sed / cat / grep 等、他に必要な外部コマンドはそのまま残す）。
# npx は取り除かない（context7 の判定に npx を使わないことの確認を兼ねる。#82）。
strip_optional_tools_from_path() {
  local dir out=""
  local IFS=':'
  for dir in $PATH; do
    if [ -x "${dir}/context7-mcp" ] || [ -x "${dir}/code-review-graph" ]; then
      continue
    fi
    out="${out:+${out}:}${dir}"
  done
  printf '%s' "$out"
}

OPT_TOOLS_STRIPPED_PATH="$(strip_optional_tools_from_path)"
OPT_TOOLS_FULL_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-optional-tools-full-stderr.XXXXXX")"
OPT_TOOLS_FULL_EXIT=0
(
  cd "$CRLF_WITHATTR_REPO" || exit 1
  HOME="$CRLF_FAKE_HOME" PATH="${CRLF_FAKE_BIN_DIR}:${OPT_TOOLS_STRIPPED_PATH}" \
    bash "$CHECK_PREREQS_SCRIPT" 1>/dev/null 2>"$OPT_TOOLS_FULL_STDERR"
) || OPT_TOOLS_FULL_EXIT=$?

assert_exit_code "context7 / code-review-graph が両方未導入でも exit 0（ブロックしない）" 0 "$OPT_TOOLS_FULL_EXIT"

if grep -q "任意ツールが未導入です" "$OPT_TOOLS_FULL_STDERR"; then
  pass "check-prerequisites.sh 本体からも任意ツールの未導入通知が stderr に出る"
else
  fail "check-prerequisites.sh 本体からも任意ツールの未導入通知が stderr に出る" "stderr=[$(cat "$OPT_TOOLS_FULL_STDERR")]"
fi

# --- errors 配列に context7 / code-review-graph という文字列が追加されていないこと（静的検査） ---
if grep -n "errors+=" "$CHECK_PREREQS_SCRIPT" | grep -qiE "context7|code-review-graph"; then
  fail "errors 配列に任意ツール（context7 / code-review-graph）が追加されていない" \
    "$(grep -n "errors+=" "$CHECK_PREREQS_SCRIPT" | grep -iE "context7|code-review-graph")"
else
  pass "errors 配列に任意ツール（context7 / code-review-graph）が追加されていない"
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
# check-readability.sh: 外部 `timeout` コマンドへの非依存化（回帰防止 #35・レビュー2巡目）
#
# #31 の修正で stdin 読み取りを `timeout "$secs" cat` に丸ごと委譲するようになったが、
# `timeout` は GNU coreutils / BusyBox のコマンドで macOS の既定環境には無い
# （`gtimeout` のみ）。command not found（status 127）を「入力が来なかった」と
# 誤判定し、macOS では可読性ガードの PostToolUse フック経路が常時無効化されて
# いた（#31 が問題視した「入力形式の差でガードが黙って無効化される」のと
# 同じ事故が環境の差で再現していた）。
#
# 修正後は bash 組み込みの `read -t` だけで複数行を読み切り、外部コマンドに
# 依存しない。ここでは
#   1) 末尾に改行の無い入力でも最終行（file_path）を取りこぼさないこと
#   2) PATH から timeout/gtimeout を完全に排除した環境でも、複数行JSONの
#      違反検出・クリーン判定・タイムアウト・--gitのハング防止が
#      引き続き機能すること
# を確認する。
# ---------------------------------------------------------------------------

echo "== check-readability.sh（外部timeoutコマンドへの非依存化・回帰防止 #35） =="

RG35_TMP_REPO="$(make_temp_repo)"
RG35_VIOLATION_FILE="violation.txt"
(
  cd "$RG35_TMP_REPO" || exit 1
  head -c 3000 /dev/zero | tr '\0' 'A' > "$RG35_VIOLATION_FILE"
) >/dev/null 2>&1

# --- 末尾に改行の無いフックJSONでも最終行(file_path)を取りこぼさず違反を検出する ---
RG35_NO_TRAILING_NEWLINE_JSON="$(printf '{\n  "tool_input": {\n    "file_path": "%s"\n  }\n}' "$RG35_VIOLATION_FILE")"

# 検証用入力の末尾に改行が無いこと自体を前提として固定しておく
case "$RG35_NO_TRAILING_NEWLINE_JSON" in
  *$'\n') fail "検証用入力の末尾に改行が無い（前提）" "末尾に改行がありました" ;;
  *) pass "検証用入力の末尾に改行が無い（前提）" ;;
esac

RG35_NO_TRAILING_NEWLINE_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  printf '%s' "$RG35_NO_TRAILING_NEWLINE_JSON" \
    | READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG35_NO_TRAILING_NEWLINE_EXIT=$?
assert_exit_code "末尾に改行の無いフックJSONでも最終行(file_path)を取りこぼさず違反を検出する" 2 "$RG35_NO_TRAILING_NEWLINE_EXIT"

# --- PATHから timeout/gtimeout を排除した環境を構築する ---
# 特定のディレクトリを丸ごとPATHから外すと、同じディレクトリに同居する
# grep/sed/awk/git 等の必須コマンドまで失われてしまうため、ファイル名単位で
# timeout/gtimeout だけを除外したシンボリックリンク集を新設のディレクトリに作る。
build_path_without_timeout() {
  local dest="$1"
  local IFS=':'
  local p f b
  for p in $PATH; do
    [ -n "$p" ] && [ -d "$p" ] || continue
    for f in "$p"/*; do
      [ -e "$f" ] || continue
      b="$(basename "$f")"
      case "$b" in
        timeout|gtimeout) continue ;;
      esac
      [ -e "${dest}/${b}" ] || ln -sf "$f" "${dest}/${b}" 2>/dev/null
    done
  done
}

RG35_NOTIMEOUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-notimeout-bin.XXXXXX")"
build_path_without_timeout "$RG35_NOTIMEOUT_DIR"
RG35_BASH_BIN="$(command -v bash)"

# 構築したPATHに timeout/gtimeout が存在しないこと自体を前提として固定しておく
# （この前提が崩れていたら以降のテストは無意味なので、まず単独で確認する）。
if PATH="$RG35_NOTIMEOUT_DIR" command -v timeout >/dev/null 2>&1 \
  || PATH="$RG35_NOTIMEOUT_DIR" command -v gtimeout >/dev/null 2>&1; then
  fail "検証用PATHにtimeout/gtimeoutが存在しない（前提）" "timeoutまたはgtimeoutが見つかりました"
else
  pass "検証用PATHにtimeout/gtimeoutが存在しない（前提）"
fi

# --- timeoutコマンドがPATHに無くても、複数行に整形されたフックJSONの違反を検出できる ---
RG35_MULTILINE_JSON=$(cat <<EOF
{
  "session_id": "abc123",
  "tool_input": {
    "file_path": "${RG35_VIOLATION_FILE}"
  },
  "tool_name": "Write"
}
EOF
)

RG35_MULTILINE_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  printf '%s' "$RG35_MULTILINE_JSON" \
    | PATH="$RG35_NOTIMEOUT_DIR" READABILITY_MAX_BASE64=50 "$RG35_BASH_BIN" "$CHECK_READABILITY_SCRIPT" \
      >/dev/null 2>&1
)
RG35_MULTILINE_EXIT=$?
assert_exit_code "timeoutコマンドがPATHに無くても複数行JSONの違反を検出する" 2 "$RG35_MULTILINE_EXIT"

# --- timeoutコマンドがPATHに無くても、クリーンなファイルはexit 0（誤検出しない） ---
RG35_CLEAN_FILE="clean-notimeout.txt"
(
  cd "$RG35_TMP_REPO" || exit 1
  printf 'clean file\n' > "$RG35_CLEAN_FILE"
) >/dev/null 2>&1

RG35_CLEAN_JSON=$(cat <<EOF
{
  "tool_input": {
    "file_path": "${RG35_CLEAN_FILE}"
  }
}
EOF
)

RG35_CLEAN_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  printf '%s' "$RG35_CLEAN_JSON" \
    | PATH="$RG35_NOTIMEOUT_DIR" "$RG35_BASH_BIN" "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG35_CLEAN_EXIT=$?
assert_exit_code "timeoutコマンドがPATHに無くてもクリーンなファイルはexit 0（誤検出しない）" 0 "$RG35_CLEAN_EXIT"

# --- timeoutコマンドがPATHに無くても、入力が来ない場合はハングせずタイムアウトしてexit 0 ---
RG35_NOINPUT_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  timeout 8 env READABILITY_STDIN_TIMEOUT=1 PATH="$RG35_NOTIMEOUT_DIR" "$RG35_BASH_BIN" \
    "$CHECK_READABILITY_SCRIPT" < <(sleep 30) >/dev/null 2>&1
)
RG35_NOINPUT_EXIT=$?
assert_exit_code "timeoutコマンドがPATHに無くても、入力が来ない場合はハングせずタイムアウトしてexit 0で素通りする" \
  0 "$RG35_NOINPUT_EXIT"

# --- timeoutコマンドがPATHに無くても、stdinを開いたまま--gitを叩けば即座に返る（ハング再発なし） ---
RG35_GIT_HANG_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  timeout 8 env PATH="$RG35_NOTIMEOUT_DIR" "$RG35_BASH_BIN" "$CHECK_READABILITY_SCRIPT" --git \
    < <(sleep 30) >/dev/null 2>&1
)
RG35_GIT_HANG_EXIT=$?
assert_exit_code "timeoutコマンドがPATHに無くても、stdinを開いたまま--gitを叩けば即座に返る" 0 "$RG35_GIT_HANG_EXIT"

# ---------------------------------------------------------------------------
# plan-waves.sh（依存グラフとウェーブ分解、Task #15、Epic #14 仕様書 5.2）
#
# --from-file はタブ区切り、1行1タスク: <番号>\t<state:open|closed>\t<前提行の生テキスト>。
# 前提行が空文字列＝「- 前提:」行そのものが無い（宣言漏れ）を意味する。docker には一切触れない。
# ---------------------------------------------------------------------------

echo "== plan-waves.sh（依存グラフとウェーブ分解） =="

PLAN_WAVES_SCRIPT="${REPO_ROOT}/scripts/plan-waves.sh"

pw_value() {
  # pw_value <task番号> <field> <output>
  # 出力の "task <n> wave <W> subbatch <S> deps <deps>" 行から field の値を取り出す
  printf '%s\n' "$3" | awk -F'\t' -v n="$1" -v f="$2" '
    $1=="task" && $2==n {
      for (i=1; i<=NF; i++) { if ($i==f) { print $(i+1); exit } }
    }'
}

pw_wave_tasks() {
  # pw_wave_tasks <wave番号> <output>
  printf '%s\n' "$2" | awk -F'\t' -v w="$1" '$1=="wave" && $2==w {print $4}'
}

# --- ケース1: Epic #3 の実 issue データ（#4〜#13 の "- 前提:" 宣言）で6ウェーブになる ---
# #4 は実際に「- 前提:」行が無い（宣言漏れの実例）。fail-safe は「自分より番号が小さい
# 全タスクに依存」だが、#4 は最小番号なので依存は空になり、警告だけが出る。
PW_EPIC3_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-epic3.XXXXXX")"
cat > "$PW_EPIC3_FIXTURE" <<'FIXTURE'
4	open
5	open	- 前提: #4
6	open	- 前提: #5（label による所属判定を使う）
7	open	- 前提: #6
8	open	- 前提: #5
9	open	- 前提: #5
10	open	- 前提: #4
11	open	- 前提: #4
12	open	- 前提: #7, #9, #11（全実装の完了後）
13	open	- 前提: #12
FIXTURE

PW_EPIC3_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE")"
PW_EPIC3_EXIT=$?

assert_exit_code "Epic #3 実データ: exit 0" 0 "$PW_EPIC3_EXIT"
assert_eq "Epic #3 実データ: 既定の lanes は3" "3" "$(printf '%s\n' "$PW_EPIC3_OUTPUT" | awk -F'\t' '$1=="lanes"{print $2}')"
assert_eq "Epic #3 実データ: W1={4}" "4" "$(pw_wave_tasks 1 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W2={5,10,11}" "5,10,11" "$(pw_wave_tasks 2 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W3={6,8,9}" "6,8,9" "$(pw_wave_tasks 3 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W4={7}" "7" "$(pw_wave_tasks 4 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W5={12}" "12" "$(pw_wave_tasks 5 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W6={13}" "13" "$(pw_wave_tasks 6 "$PW_EPIC3_OUTPUT")"

if printf '%s\n' "$PW_EPIC3_OUTPUT" | grep -q '^wave	7	'; then
  fail "Epic #3 実データ: ウェーブは6個で打ち止め（W7が存在しない）"
else
  pass "Epic #3 実データ: ウェーブは6個で打ち止め（W7が存在しない）"
fi

assert_eq "Epic #3 実データ: #12 の deps は 7,9,11" "7,9,11" "$(pw_value 12 deps "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: #4 は実際に宣言漏れ（前提行が無い）として警告される" \
  "1" "$(printf '%s\n' "$PW_EPIC3_OUTPUT" | grep -c '^warn	missing-deps	4$')"

# --- ケース2: --lanes 2 でウェーブ2が {5,10} と {11} のサブバッチに割れる ---
PW_LANES2_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE" --lanes 2)"

assert_eq "--lanes 2: #5 は subbatch 1" "1" "$(pw_value 5 subbatch "$PW_LANES2_OUTPUT")"
assert_eq "--lanes 2: #10 は subbatch 1" "1" "$(pw_value 10 subbatch "$PW_LANES2_OUTPUT")"
assert_eq "--lanes 2: #11 は subbatch 2" "2" "$(pw_value 11 subbatch "$PW_LANES2_OUTPUT")"

# --- ケース3: 「- 前提:」行が無いタスクが「自分より小さい全タスクに依存」となり、
#     全件宣言漏れなら完全逐次になる ---
PW_SERIAL_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-serial.XXXXXX")"
cat > "$PW_SERIAL_FIXTURE" <<'FIXTURE'
501	open
502	open
503	open
FIXTURE

PW_SERIAL_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_SERIAL_FIXTURE")"

assert_eq "宣言漏れの完全逐次: #501 は wave1（依存なし）" "1" "$(pw_value 501 wave "$PW_SERIAL_OUTPUT")"
assert_eq "宣言漏れの完全逐次: #502 は wave2（#501 に依存）" "2" "$(pw_value 502 wave "$PW_SERIAL_OUTPUT")"
assert_eq "宣言漏れの完全逐次: #503 は wave3（#501,#502 に依存）" "3" "$(pw_value 503 wave "$PW_SERIAL_OUTPUT")"
assert_eq "宣言漏れの完全逐次: #503 の deps は 501,502" "501,502" "$(pw_value 503 deps "$PW_SERIAL_OUTPUT")"
PW_SERIAL_MISSING_COUNT="$(printf '%s\n' "$PW_SERIAL_OUTPUT" | grep -c '^warn	missing-deps	')"
assert_eq "宣言漏れの完全逐次: 3件すべてに missing-deps 警告が出る" "3" "$PW_SERIAL_MISSING_COUNT"

# --- ケース4: 循環依存で exit 3 になり、循環に含まれるタスクが列挙される ---
PW_CYCLE_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-cycle.XXXXXX")"
cat > "$PW_CYCLE_FIXTURE" <<'FIXTURE'
601	open	- 前提: #602
602	open	- 前提: #601
FIXTURE

PW_CYCLE_STDERR="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_CYCLE_FIXTURE" 2>&1 1>/dev/null)"
PW_CYCLE_EXIT=$?

assert_exit_code "循環依存: exit 3" 3 "$PW_CYCLE_EXIT"
case "$PW_CYCLE_STDERR" in
  *"601"*"602"*|*"602"*"601"*) pass "循環依存: 循環に含まれる両タスクがエラーに列挙される" ;;
  *) fail "循環依存: 循環に含まれる両タスクがエラーに列挙される" "stderr=[${PW_CYCLE_STDERR}]" ;;
esac

# --- ケース5: Epic外・存在しない issue への依存が warn unknown-dep として報告され、無視される ---
PW_UNKNOWN_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-unknown.XXXXXX")"
cat > "$PW_UNKNOWN_FIXTURE" <<'FIXTURE'
701	open	- 前提: #999
FIXTURE

PW_UNKNOWN_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_UNKNOWN_FIXTURE")"

assert_eq "unknown-dep: 未知の依存は警告として報告される" "1" \
  "$(printf '%s\n' "$PW_UNKNOWN_OUTPUT" | grep -c '^warn	unknown-dep	701	999$')"
assert_eq "unknown-dep: 未知の依存は無視され #701 は wave1 になる" "1" "$(pw_value 701 wave "$PW_UNKNOWN_OUTPUT")"
assert_eq "unknown-dep: #701 の deps は空（未知の依存を数えない）" "" "$(pw_value 701 deps "$PW_UNKNOWN_OUTPUT")"

# --- ケース6: --skipped の伝播が推移的に効く ---
PW_SKIP_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-skip.XXXXXX")"
cat > "$PW_SKIP_FIXTURE" <<'FIXTURE'
801	open
802	open	- 前提: #801
803	open	- 前提: #802
FIXTURE

PW_SKIP_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_SKIP_FIXTURE" --skipped 802)"

if printf '%s\n' "$PW_SKIP_OUTPUT" | grep -q '^task	802	'; then
  fail "スキップ伝播: 明示的にスキップした #802 はタスク一覧に出ない" "output=[${PW_SKIP_OUTPUT}]"
else
  pass "スキップ伝播: 明示的にスキップした #802 はタスク一覧に出ない"
fi

if printf '%s\n' "$PW_SKIP_OUTPUT" | grep -q '^task	803	'; then
  fail "スキップ伝播: #802 に依存する #803 も推移的にスキップされタスク一覧に出ない" "output=[${PW_SKIP_OUTPUT}]"
else
  pass "スキップ伝播: #802 に依存する #803 も推移的にスキップされタスク一覧に出ない"
fi

assert_eq "スキップ伝播: #803 の skip 行に理由（依存先 #802）が出る" "1" \
  "$(printf '%s\n' "$PW_SKIP_OUTPUT" | grep -c '^skip	803	reason	depends-on-skipped	802$')"

if printf '%s\n' "$PW_SKIP_OUTPUT" | grep -q '^task	801	'; then
  pass "スキップ伝播: スキップに依存しない #801 は影響を受けない"
else
  fail "スキップ伝播: スキップに依存しない #801 は影響を受けない" "output=[${PW_SKIP_OUTPUT}]"
fi

# --- ケース7: クローズ済み issue への依存が充足済みとして扱われる ---
PW_CLOSED_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-closed.XXXXXX")"
cat > "$PW_CLOSED_FIXTURE" <<'FIXTURE'
901	closed
902	open	- 前提: #901
FIXTURE

PW_CLOSED_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_CLOSED_FIXTURE")"

assert_eq "closed依存: クローズ済み依存は充足済みとして扱われ #902 は wave1 になる" "1" "$(pw_value 902 wave "$PW_CLOSED_OUTPUT")"
assert_eq "closed依存: #902 の deps は空（クローズ済みを数えない）" "" "$(pw_value 902 deps "$PW_CLOSED_OUTPUT")"
if printf '%s\n' "$PW_CLOSED_OUTPUT" | grep -q '^task	901	'; then
  fail "closed依存: クローズ済みタスク自体はウェーブ計画の対象に含まれない" "output=[${PW_CLOSED_OUTPUT}]"
else
  pass "closed依存: クローズ済みタスク自体はウェーブ計画の対象に含まれない"
fi
if printf '%s\n' "$PW_CLOSED_OUTPUT" | grep -q '^warn	unknown-dep	902	901$'; then
  fail "closed依存: クローズ済み依存は unknown-dep として警告されない" "output=[${PW_CLOSED_OUTPUT}]"
else
  pass "closed依存: クローズ済み依存は unknown-dep として警告されない"
fi

# --- ケース8: --print が人間向けの表を出す（ドライラン） ---
PW_PRINT_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE" --print)"

case "$PW_PRINT_OUTPUT" in
  *"ウェーブ分解"*) pass "--print: 人間向けの見出しが出る" ;;
  *) fail "--print: 人間向けの見出しが出る" "output=[${PW_PRINT_OUTPUT}]" ;;
esac
case "$PW_PRINT_OUTPUT" in
  *"lanes"$'\t'*) fail "--print: 機械可読な TSV ではなく人間向け表示になっている" "output=[${PW_PRINT_OUTPUT}]" ;;
  *) pass "--print: 機械可読な TSV ではなく人間向け表示になっている" ;;
esac

# --- ケース9: 引数バリデーション（引数エラーは exit 2） ---
bash "$PLAN_WAVES_SCRIPT" >/dev/null 2>&1
assert_exit_code "--epic も --from-file も無ければ exit 2" 2 "$?"

bash "$PLAN_WAVES_SCRIPT" --epic 14 --from-file "$PW_EPIC3_FIXTURE" >/dev/null 2>&1
assert_exit_code "--epic と --from-file の同時指定は exit 2" 2 "$?"

bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE" --lanes abc >/dev/null 2>&1
assert_exit_code "--lanes に数値以外を渡すと exit 2" 2 "$?"

bash "$PLAN_WAVES_SCRIPT" --from-file "${TMPDIR:-/tmp}/dw-test-pw-no-such-file" >/dev/null 2>&1
assert_exit_code "--from-file に存在しないファイルを渡すと exit 2" 2 "$?"

# --- ケース10: DEV_WORKFLOW_MAX_LANES で既定の --lanes を上書きできる ---
PW_ENV_LANES_OUTPUT="$(DEV_WORKFLOW_MAX_LANES=5 bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE")"
assert_eq "DEV_WORKFLOW_MAX_LANES で既定の lanes を上書きできる" "5" \
  "$(printf '%s\n' "$PW_ENV_LANES_OUTPUT" | awk -F'\t' '$1=="lanes"{print $2}')"

# --- ケース11: --epic に非数値を渡すと exit 2（Task #39: sandbox-exec.sh の --epic とは
#     別契約で、plan-waves.sh の --epic は数値のEpic issue番号でなければならない） ---
bash "$PLAN_WAVES_SCRIPT" --epic epic14 >/dev/null 2>&1
assert_exit_code "--epic に epic14 のような非数値を渡すと exit 2" 2 "$?"

bash "$PLAN_WAVES_SCRIPT" --epic abc >/dev/null 2>&1
assert_exit_code "--epic に abc のような非数値を渡すと exit 2" 2 "$?"

# 数値の --epic 単体が拒否されないことは、ケース12（gh フェッチが exit 0 で完了すること）で確認する。

# --- ケース12: gh モードで --limit 200 が付き、本文の「- Epic: #N」行でEpic外を除外し、
#     行が無いタスクはフェイルオープンで含める（Task #39: Epic混入対策と30件上限対策） ---
PW_GH_FAKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-pw-ghfake.XXXXXX")"
PW_GH_CALL_MARKER="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-ghcall.XXXXXX")"
cat > "${PW_GH_FAKE_DIR}/gh" <<'FAKE_GH'
#!/bin/bash
# tests/run-tests.sh 用の偽 gh。load_from_gh が渡す引数を記録し、issue list 呼び出しには
# 固定のレコード（<番号><US><前提行><US><Epic行>、US=0x1f）を返す。実ネットワークには
# 一切触れない。区切り文字は load_from_gh の実装（@tsv ではなく join("")）に合わせる。
US=$'\x1f'
echo "$*" >> "${PW_GH_CALL_MARKER}"
case "$*" in
  *"issue list --label task --state open"*)
    printf '100%s%s- Epic: #14\n' "$US" "$US"    # 指定Epicと一致 -> 含める
    printf '200%s%s- Epic: #3\n' "$US" "$US"     # 別Epic -> 除外する
    printf '300%s%s\n' "$US" "$US"               # Epic行が無い旧形式 -> フェイルオープンで含める
    ;;
esac
FAKE_GH
chmod +x "${PW_GH_FAKE_DIR}/gh"

PW_GH_OUTPUT="$(PATH="${PW_GH_FAKE_DIR}:${PATH}" PW_GH_CALL_MARKER="$PW_GH_CALL_MARKER" bash "$PLAN_WAVES_SCRIPT" --epic 14)"
PW_GH_EXIT=$?
PW_GH_CALL="$(cat "$PW_GH_CALL_MARKER")"

assert_exit_code "gh モード: --epic 14 は exit 0" 0 "$PW_GH_EXIT"

case "$PW_GH_CALL" in
  *"--limit 200"*) pass "gh モード: issue list に --limit 200 が付く（30件上限対策）" ;;
  *) fail "gh モード: issue list に --limit 200 が付く（30件上限対策）" "call=[${PW_GH_CALL}]" ;;
esac

if printf '%s\n' "$PW_GH_OUTPUT" | grep -q '^task	100	'; then
  pass "gh モード: 指定Epicと一致する #100 は対象に含まれる"
else
  fail "gh モード: 指定Epicと一致する #100 は対象に含まれる" "output=[${PW_GH_OUTPUT}]"
fi

if printf '%s\n' "$PW_GH_OUTPUT" | grep -q '^task	200	'; then
  fail "gh モード: 別Epic（#3）を明記する #200 は除外される" "output=[${PW_GH_OUTPUT}]"
else
  pass "gh モード: 別Epic（#3）を明記する #200 は除外される"
fi

if printf '%s\n' "$PW_GH_OUTPUT" | grep -q '^task	300	'; then
  pass "gh モード: Epic行が無い #300 はフェイルオープンで含まれる"
else
  fail "gh モード: Epic行が無い #300 はフェイルオープンで含まれる" "output=[${PW_GH_OUTPUT}]"
fi

# ---------------------------------------------------------------------------
# merge-lane.sh（merge-base 検証と wave ブランチ統合。Task #16）
#
# 一時 git リポジトリを組み立てて検証する（Docker 非依存）。scripts/merge-lane.sh は
# cwd のリポジトリに対して checkout / merge-base / merge / abort を行うため、
# plan-waves.sh と違いスクリプト自体をコピーせず、cwd を一時リポジトリに変えて
# REPO_ROOT のスクリプトを直接呼び出す。
# ---------------------------------------------------------------------------

echo "== merge-lane.sh（merge-base 検証と wave ブランチ統合） =="

MERGE_LANE_SCRIPT="${REPO_ROOT}/scripts/merge-lane.sh"

ml_commit_file() {
  # ml_commit_file <repo_dir> <相対ファイル名> <内容> <コミットメッセージ>
  local repo="$1" file="$2" content="$3" msg="$4"
  (
    cd "$repo" || exit 1
    printf '%s' "$content" > "$file"
    git add "$file"
    git commit -q -m "$msg"
  ) >/dev/null 2>&1
}

ml_branch_from() {
  # ml_branch_from <repo_dir> <新ブランチ名> <開始点（コミットish）>
  local repo="$1" branch="$2" start="$3"
  (
    cd "$repo" || exit 1
    git checkout -q -b "$branch" "$start"
  ) >/dev/null 2>&1
}

ml_head_of() {
  # ml_head_of <repo_dir> <ref>  ref が指すコミットの完全なSHAを返す
  (cd "$1" || exit 1; git rev-parse "$2") 2>/dev/null
}

run_merge_lane() {
  # run_merge_lane <repo_dir> [追加の引数...]  戻り値は標準出力（呼び出し側で $? を確認する）
  local repo="$1"
  shift
  (cd "$repo" || exit 1; bash "$MERGE_LANE_SCRIPT" "$@")
}

# --- ケース8: 同一ベースから分岐した2レーンが順に取り込め、2本目の merge-base が
#     EXPECTED_BASE のままであること ---
ML_REPO8="$(make_temp_repo)"
ml_commit_file "$ML_REPO8" "base.txt" "wave base\n" "wave base commit"
ML8_BASE="$(ml_head_of "$ML_REPO8" HEAD)"
ml_branch_from "$ML_REPO8" "lane-a" "$ML8_BASE"
ml_commit_file "$ML_REPO8" "a.txt" "lane a\n" "lane a change"
ml_branch_from "$ML_REPO8" "lane-b" "$ML8_BASE"
ml_commit_file "$ML_REPO8" "b.txt" "lane b\n" "lane b change"

ML8_OUT1="$(run_merge_lane "$ML_REPO8" --wave-branch "wave/epicT/1" --expected-base "$ML8_BASE" --lane-branch lane-a --task 16 --create)"
ML8_EXIT1=$?
assert_exit_code "ケース8: 1本目（lane-a）の取り込みは exit 0" 0 "$ML8_EXIT1"

# 2本目のマージ実行前（1本目取り込み後）の merge-base を確認する。マージ後は wave が
# lane-b を取り込んで祖先集合が変わるため、必ずマージ「前」に測る。
ML8_ACTUAL_BASE_2ND="$(cd "$ML_REPO8" && git merge-base "wave/epicT/1" lane-b)"
assert_eq "ケース8: 2本目の merge-base（実行前）は EXPECTED_BASE のまま" "$ML8_BASE" "$ML8_ACTUAL_BASE_2ND"

ML8_OUT2="$(run_merge_lane "$ML_REPO8" --wave-branch "wave/epicT/1" --expected-base "$ML8_BASE" --lane-branch lane-b --task 16)"
ML8_EXIT2=$?
assert_exit_code "ケース8: 2本目（lane-b）の取り込みは exit 0" 0 "$ML8_EXIT2"

ML8_WAVE_HEAD="$(ml_head_of "$ML_REPO8" "wave/epicT/1")"
if [ "$ML8_WAVE_HEAD" != "$ML8_BASE" ]; then
  pass "ケース8: wave ブランチが両レーンの成果を含む（HEAD が進んでいる）"
else
  fail "ケース8: wave ブランチが両レーンの成果を含む（HEAD が進んでいる）" "wave HEAD が BASE から動いていません"
fi

# --- ケース9: 別ベースから分岐したレーンが exit 10 で拒否され、wave ブランチが動かないこと ---
ML_REPO9="$(make_temp_repo)"
ML9_OLD_BASE="$(ml_head_of "$ML_REPO9" HEAD)"
ml_commit_file "$ML_REPO9" "base.txt" "wave base\n" "wave base commit"
ML9_EXPECTED_BASE="$(ml_head_of "$ML_REPO9" HEAD)"

ml_branch_from "$ML_REPO9" "lane-ok" "$ML9_EXPECTED_BASE"
ml_commit_file "$ML_REPO9" "ok.txt" "lane ok\n" "lane ok change"

ml_branch_from "$ML_REPO9" "lane-wrong-base" "$ML9_OLD_BASE"
ml_commit_file "$ML_REPO9" "wrong.txt" "lane wrong base\n" "lane wrong base change"

run_merge_lane "$ML_REPO9" --wave-branch "wave/epicT/1" --expected-base "$ML9_EXPECTED_BASE" --lane-branch lane-ok --task 16 --create >/dev/null
ML9_SETUP_EXIT=$?
assert_exit_code "ケース9: 事前準備（lane-ok の取り込み）は exit 0" 0 "$ML9_SETUP_EXIT"

ML9_WAVE_HEAD_BEFORE="$(ml_head_of "$ML_REPO9" "wave/epicT/1")"

ML9_OUT="$(run_merge_lane "$ML_REPO9" --wave-branch "wave/epicT/1" --expected-base "$ML9_EXPECTED_BASE" --lane-branch lane-wrong-base --task 16)"
ML9_EXIT=$?
assert_exit_code "ケース9: 別ベースから分岐したレーンは exit 10" 10 "$ML9_EXIT"

case "$ML9_OUT" in
  *"$ML9_OLD_BASE"*) pass "ケース9: 実際の merge-base とそのコミットログが stdout に出る" ;;
  *) fail "ケース9: 実際の merge-base とそのコミットログが stdout に出る" "output=[${ML9_OUT}]" ;;
esac

ML9_WAVE_HEAD_AFTER="$(ml_head_of "$ML_REPO9" "wave/epicT/1")"
assert_eq "ケース9: exit 10 のとき wave ブランチが動かない" "$ML9_WAVE_HEAD_BEFORE" "$ML9_WAVE_HEAD_AFTER"

# --- ケース10: 競合するレーンが exit 11 で拒否され、git merge --abort 後に作業ツリーが
#     汚れていないこと（git status --porcelain が空） ---
ML_REPO10="$(make_temp_repo)"
ml_commit_file "$ML_REPO10" "conflict.txt" "base\n" "wave base commit"
ML10_BASE="$(ml_head_of "$ML_REPO10" HEAD)"

ml_branch_from "$ML_REPO10" "lane-c1" "$ML10_BASE"
ml_commit_file "$ML_REPO10" "conflict.txt" "change1\n" "lane c1 change"

ml_branch_from "$ML_REPO10" "lane-c2" "$ML10_BASE"
ml_commit_file "$ML_REPO10" "conflict.txt" "change2\n" "lane c2 change"

run_merge_lane "$ML_REPO10" --wave-branch "wave/epicT/1" --expected-base "$ML10_BASE" --lane-branch lane-c1 --task 16 --create >/dev/null
ML10_SETUP_EXIT=$?
assert_exit_code "ケース10: 事前準備（lane-c1 の取り込み）は exit 0" 0 "$ML10_SETUP_EXIT"

ML10_WAVE_HEAD_BEFORE="$(ml_head_of "$ML_REPO10" "wave/epicT/1")"

ML10_OUT="$(run_merge_lane "$ML_REPO10" --wave-branch "wave/epicT/1" --expected-base "$ML10_BASE" --lane-branch lane-c2 --task 16)"
ML10_EXIT=$?
assert_exit_code "ケース10: 競合するレーンは exit 11" 11 "$ML10_EXIT"

case "$ML10_OUT" in
  *"conflict.txt"*) pass "ケース10: 競合ファイル一覧（conflict.txt）が stdout に出る" ;;
  *) fail "ケース10: 競合ファイル一覧（conflict.txt）が stdout に出る" "output=[${ML10_OUT}]" ;;
esac

ML10_PORCELAIN="$(cd "$ML_REPO10" && git status --porcelain)"
assert_eq "ケース10: git merge --abort 後に作業ツリーが汚れていない" "" "$ML10_PORCELAIN"

ML10_WAVE_HEAD_AFTER="$(ml_head_of "$ML_REPO10" "wave/epicT/1")"
assert_eq "ケース10: exit 11 のとき wave ブランチが動かない" "$ML10_WAVE_HEAD_BEFORE" "$ML10_WAVE_HEAD_AFTER"

# --- ケース11: レーン1本のウェーブで履歴が fast-forward になること（lanes=1 相当） ---
ML_REPO11="$(make_temp_repo)"
ml_commit_file "$ML_REPO11" "base.txt" "wave base\n" "wave base commit"
ML11_BASE="$(ml_head_of "$ML_REPO11" HEAD)"

ml_branch_from "$ML_REPO11" "lane-solo" "$ML11_BASE"
ml_commit_file "$ML_REPO11" "solo.txt" "lane solo\n" "lane solo change"
ML11_LANE_HEAD="$(ml_head_of "$ML_REPO11" lane-solo)"

run_merge_lane "$ML_REPO11" --wave-branch "wave/epicT/1" --expected-base "$ML11_BASE" --lane-branch lane-solo --task 16 --create >/dev/null
ML11_EXIT=$?
assert_exit_code "ケース11: 単独レーンの取り込みは exit 0" 0 "$ML11_EXIT"

ML11_WAVE_HEAD="$(ml_head_of "$ML_REPO11" "wave/epicT/1")"
assert_eq "ケース11: fast-forward により wave HEAD がレーンの HEAD と一致する" "$ML11_LANE_HEAD" "$ML11_WAVE_HEAD"

ML11_MERGE_COUNT="$(cd "$ML_REPO11" && git log --merges --oneline "wave/epicT/1" | wc -l | tr -d ' ')"
assert_eq "ケース11: fast-forward によりマージコミットが作られない" "0" "$ML11_MERGE_COUNT"

# --- ケース12: 引数バリデーション（引数エラーは exit 2） ---
ML_REPO_ARGS="$(make_temp_repo)"

run_merge_lane "$ML_REPO_ARGS" >/dev/null 2>&1
assert_exit_code "引数なしは exit 2" 2 "$?"

run_merge_lane "$ML_REPO_ARGS" --expected-base HEAD --lane-branch dummy >/dev/null 2>&1
assert_exit_code "--wave-branch 省略は exit 2" 2 "$?"

run_merge_lane "$ML_REPO_ARGS" --wave-branch wave/epicT/1 --lane-branch dummy >/dev/null 2>&1
assert_exit_code "--expected-base 省略は exit 2" 2 "$?"

run_merge_lane "$ML_REPO_ARGS" --wave-branch wave/epicT/1 --expected-base HEAD >/dev/null 2>&1
assert_exit_code "--lane-branch 省略は exit 2" 2 "$?"

run_merge_lane "$ML_REPO_ARGS" --wave-branch wave/epicT/1 --expected-base no-such-ref --lane-branch dummy >/dev/null 2>&1
assert_exit_code "--expected-base が解決できない値は exit 2" 2 "$?"

# --- ケース13: wave ブランチが無く --create も無ければ exit 1（その他の失敗） ---
ML_REPO_NOCREATE="$(make_temp_repo)"
ML_NOCREATE_BASE="$(ml_head_of "$ML_REPO_NOCREATE" HEAD)"
ml_branch_from "$ML_REPO_NOCREATE" "lane-x" "$ML_NOCREATE_BASE"
ml_commit_file "$ML_REPO_NOCREATE" "x.txt" "lane x\n" "lane x change"

run_merge_lane "$ML_REPO_NOCREATE" --wave-branch "wave/epicT/1" --expected-base "$ML_NOCREATE_BASE" --lane-branch lane-x >/dev/null 2>&1
assert_exit_code "wave ブランチが無く --create 無しは exit 1" 1 "$?"

# --- ケース14: レーンのブランチが存在しなければ exit 1（その他の失敗） ---
ML_REPO_NOLANE="$(make_temp_repo)"
ML_NOLANE_BASE="$(ml_head_of "$ML_REPO_NOLANE" HEAD)"

run_merge_lane "$ML_REPO_NOLANE" --wave-branch "wave/epicT/1" --expected-base "$ML_NOLANE_BASE" --lane-branch no-such-lane-branch --create >/dev/null 2>&1
assert_exit_code "存在しないレーンブランチは exit 1" 1 "$?"

# --- ケース15（Review #40）: 未コミットのローカル変更でマージが「競合ではない理由」で
#     失敗した場合、exit 1 になり（exit 11 にならず）、`git merge --abort` を試みない
#     （呼べば「There is no merge to abort」で失敗し作業ツリーが汚れる）こと。
#     git merge は "Your local changes to the following files would be overwritten by
#     merge" で非0終了するが、MERGE_HEAD は作られず未マージパスも無いため、これは
#     本物の競合と区別しなければならない。 ---
ML_REPO15="$(make_temp_repo)"
ml_commit_file "$ML_REPO15" "file.txt" "base\n" "wave base commit"
ML15_BASE="$(ml_head_of "$ML_REPO15" HEAD)"

(cd "$ML_REPO15" && git branch "wave/epicT/1" "$ML15_BASE") >/dev/null 2>&1

ml_branch_from "$ML_REPO15" "lane-local" "$ML15_BASE"
ml_commit_file "$ML_REPO15" "file.txt" "lane change\n" "lane local change"

# wave ブランチへ切り替え、file.txt に未コミットの変更を残す（この時点でコミット済みの
# 変更は無いので checkout 自体は成功する）。merge-lane.sh 自身も同じブランチへ checkout
# するため（no-op）、この未コミット変更はそのまま merge 実行時まで残る。
(cd "$ML_REPO15" && git checkout -q "wave/epicT/1") >/dev/null 2>&1
(cd "$ML_REPO15" && printf 'uncommitted local change\n' > file.txt) >/dev/null 2>&1

ML15_PORCELAIN_BEFORE="$(cd "$ML_REPO15" && git status --porcelain)"

ML15_OUT="$(run_merge_lane "$ML_REPO15" --wave-branch "wave/epicT/1" --expected-base "$ML15_BASE" --lane-branch lane-local --task 16)"
ML15_EXIT=$?
assert_exit_code "ケース15: ローカル未コミット変更によるマージ失敗は exit 1（exit 11 にならない）" 1 "$ML15_EXIT"

case "$ML15_OUT" in
  *"マージ競合が発生しました"*) fail "ケース15: 「マージ競合が発生しました」の見出しは出ない（本物の競合ではないため）" "output=[${ML15_OUT}]" ;;
  *) pass "ケース15: 「マージ競合が発生しました」の見出しは出ない（本物の競合ではないため）" ;;
esac

case "$ML15_OUT" in
  *"マージに失敗しました（競合ではありません）"*) pass "ケース15: 「競合ではない失敗」の見出しが出る" ;;
  *) fail "ケース15: 「競合ではない失敗」の見出しが出る" "output=[${ML15_OUT}]" ;;
esac

ML15_MERGE_HEAD_EXISTS="$(cd "$ML_REPO15" && [ -f .git/MERGE_HEAD ] && echo yes || echo no)"
assert_eq "ケース15: MERGE_HEAD が存在しない（git merge --abort を呼んでいない証跡）" "no" "$ML15_MERGE_HEAD_EXISTS"

ML15_PORCELAIN_AFTER="$(cd "$ML_REPO15" && git status --porcelain)"
assert_eq "ケース15: 未コミットのローカル変更（file.txt）がそのまま残っている（abort による破棄が起きていない）" \
  "$ML15_PORCELAIN_BEFORE" "$ML15_PORCELAIN_AFTER"

# --- ケース16（Task #54）: --create 指定時に残骸 wave ブランチ（tip が --expected-base と
#     不一致）が既に存在する場合、exit 1 で拒否され、呼び出し元でチェックアウトしていた
#     ブランチ（epic ブランチ相当）も wave ブランチも一切動かないこと。出力に既存 tip・
#     期待ベース・対処（WAVE_NO の採番し直し）が含まれること。 ---
ML_REPO16="$(make_temp_repo)"
ML16_DEFAULT_BRANCH="$(cd "$ML_REPO16" && git rev-parse --abbrev-ref HEAD)"
ml_commit_file "$ML_REPO16" "base.txt" "wave base\n" "wave base commit"
ML16_EXPECTED_BASE="$(ml_head_of "$ML_REPO16" HEAD)"

# 前回セッションの残骸を模す: EXPECTED_BASE から分岐した別コミットを tip に持つ
# wave ブランチ（checkout はしない。ml_branch_from を使うと現在のブランチが切り替わって
# しまうため、直接 `git branch` で作る）
ml_branch_from "$ML_REPO16" "stale-source" "$ML16_EXPECTED_BASE"
ml_commit_file "$ML_REPO16" "stale.txt" "stale\n" "stale unrelated commit (previous session)"
ML16_STALE_TIP="$(ml_head_of "$ML_REPO16" stale-source)"
(cd "$ML_REPO16" && git branch "wave/epicT/1" "$ML16_STALE_TIP") >/dev/null 2>&1

# 呼び出し元（epic ブランチ相当）へ戻し、この時点のHEADを記録する
(cd "$ML_REPO16" && git checkout -q "$ML16_DEFAULT_BRANCH") >/dev/null 2>&1
ML16_CALLER_HEAD_BEFORE="$(ml_head_of "$ML_REPO16" "$ML16_DEFAULT_BRANCH")"
ML16_WAVE_HEAD_BEFORE="$(ml_head_of "$ML_REPO16" "wave/epicT/1")"

ml_branch_from "$ML_REPO16" "lane-y" "$ML16_EXPECTED_BASE"
ml_commit_file "$ML_REPO16" "y.txt" "lane y\n" "lane y change"

ML16_OUT="$(run_merge_lane "$ML_REPO16" --wave-branch "wave/epicT/1" --expected-base "$ML16_EXPECTED_BASE" --lane-branch lane-y --task 54 --create 2>&1)"
ML16_EXIT=$?
assert_exit_code "ケース16: --create で tip 不一致の残骸 wave ブランチは exit 1" 1 "$ML16_EXIT"

ML16_CALLER_HEAD_AFTER="$(ml_head_of "$ML_REPO16" "$ML16_DEFAULT_BRANCH")"
ML16_WAVE_HEAD_AFTER="$(ml_head_of "$ML_REPO16" "wave/epicT/1")"
assert_eq "ケース16: 呼び出し元ブランチ（epic ブランチ相当）の HEAD が動かない" "$ML16_CALLER_HEAD_BEFORE" "$ML16_CALLER_HEAD_AFTER"
assert_eq "ケース16: wave ブランチの tip が動かない（残骸のまま）" "$ML16_WAVE_HEAD_BEFORE" "$ML16_WAVE_HEAD_AFTER"

case "$ML16_OUT" in
  *"$ML16_STALE_TIP"*) pass "ケース16: 出力に既存 wave ブランチの tip が含まれる" ;;
  *) fail "ケース16: 出力に既存 wave ブランチの tip が含まれる" "output=[${ML16_OUT}]" ;;
esac

case "$ML16_OUT" in
  *"$ML16_EXPECTED_BASE"*) pass "ケース16: 出力に期待していたベース（--expected-base）が含まれる" ;;
  *) fail "ケース16: 出力に期待していたベース（--expected-base）が含まれる" "output=[${ML16_OUT}]" ;;
esac

case "$ML16_OUT" in
  *"WAVE_NO"*) pass "ケース16: 出力に対処（WAVE_NO の採番し直し）が含まれる" ;;
  *) fail "ケース16: 出力に対処（WAVE_NO の採番し直し）が含まれる" "output=[${ML16_OUT}]" ;;
esac

# --- ケース17（Task #54）: --create 指定時に既存 wave ブランチの tip が --expected-base と
#     一致する場合（前回まさに --create で作っただけで、まだレーンを取り込んでいない状態）は
#     残骸扱いにせず、従来どおり取り込みが成功すること（冪等性） ---
ML_REPO17="$(make_temp_repo)"
ml_commit_file "$ML_REPO17" "base.txt" "wave base\n" "wave base commit"
ML17_EXPECTED_BASE="$(ml_head_of "$ML_REPO17" HEAD)"

# 前回の --create で作られたが、まだ何も取り込んでいない wave ブランチ（tip = EXPECTED_BASE）
(cd "$ML_REPO17" && git branch "wave/epicT/1" "$ML17_EXPECTED_BASE") >/dev/null 2>&1

ml_branch_from "$ML_REPO17" "lane-z" "$ML17_EXPECTED_BASE"
ml_commit_file "$ML_REPO17" "z.txt" "lane z\n" "lane z change"
ML17_LANE_HEAD="$(ml_head_of "$ML_REPO17" lane-z)"

ML17_OUT="$(run_merge_lane "$ML_REPO17" --wave-branch "wave/epicT/1" --expected-base "$ML17_EXPECTED_BASE" --lane-branch lane-z --task 54 --create)"
ML17_EXIT=$?
assert_exit_code "ケース17: --create で tip 一致の既存 wave ブランチは従来どおり exit 0（冪等性）" 0 "$ML17_EXIT"

ML17_WAVE_HEAD="$(ml_head_of "$ML_REPO17" "wave/epicT/1")"
assert_eq "ケース17: 冪等時は取り込みが成功し wave HEAD がレーンの HEAD と一致する" "$ML17_LANE_HEAD" "$ML17_WAVE_HEAD"

case "$ML17_OUT" in
  *"取り込み成功"*) pass "ケース17: 出力に取り込み成功のメッセージが含まれる" ;;
  *) fail "ケース17: 出力に取り込み成功のメッセージが含まれる" "output=[${ML17_OUT}]" ;;
esac

# ---------------------------------------------------------------------------
# adapters/codex/run-loop.sh: 統合ゲートが全テストを実行すること（回帰防止 #37）
#
# Review #37: mechanical_gate() が check-readability.sh --git だけを実行しており、
# sandbox-exec.sh 経由でプロジェクトの全テストを走らせていなかった（statically
# 検証できる範囲に限定し、実際の gh/docker 呼び出しは行わない）。
# ---------------------------------------------------------------------------

echo ""
echo "== adapters/codex/run-loop.sh（統合ゲートの全テスト実行・回帰防止 #37） =="

RUN_LOOP_SCRIPT="${REPO_ROOT}/adapters/codex/run-loop.sh"

RL_BASHN_OUT="$(bash -n "$RUN_LOOP_SCRIPT" 2>&1)"
assert_exit_code "run-loop.sh: bash -n は exit 0" 0 "$?"
[ -z "$RL_BASHN_OUT" ] || echo "         ${RL_BASHN_OUT}"

if command -v shellcheck >/dev/null 2>&1; then
  RL_SHELLCHECK_OUT="$(cd "$(dirname "$RUN_LOOP_SCRIPT")" && shellcheck -x "$(basename "$RUN_LOOP_SCRIPT")" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "shellcheck: run-loop.sh"
  else
    fail "shellcheck: run-loop.sh" "$RL_SHELLCHECK_OUT"
  fi
else
  skip "shellcheck: run-loop.sh" "コマンドが見つからないためスキップ"
fi

# mechanical_gate() の関数本体だけを取り出して静的に検証する
RL_MECH_GATE_BODY="$(sed -n '/^mechanical_gate() {/,/^}/p' "$RUN_LOOP_SCRIPT")"
RL_MECH_GATE_ONELINE="$(printf '%s' "$RL_MECH_GATE_BODY" | tr '\n' ' ')"

case "$RL_MECH_GATE_ONELINE" in
  *"sandbox-exec.sh"*'"$TEST_CMD"'*)
    pass "run-loop.sh: mechanical_gate() が sandbox-exec.sh に \$TEST_CMD を渡している" ;;
  *)
    fail "run-loop.sh: mechanical_gate() が sandbox-exec.sh に \$TEST_CMD を渡している" "$RL_MECH_GATE_BODY" ;;
esac

case "$RL_MECH_GATE_ONELINE" in
  *"check-readability.sh"*)
    pass "run-loop.sh: mechanical_gate() が check-readability.sh を呼んでいる" ;;
  *)
    fail "run-loop.sh: mechanical_gate() が check-readability.sh を呼んでいる" "$RL_MECH_GATE_BODY" ;;
esac

# テストと可読性ガードが && で連結され、テスト失敗時に可読性ガードへ進まない（AND判定）こと
case "$RL_MECH_GATE_ONELINE" in
  *"sandbox-exec.sh"*'&&'*"check-readability.sh"*)
    pass "run-loop.sh: mechanical_gate() はテストと可読性ガードを && で連結している" ;;
  *)
    fail "run-loop.sh: mechanical_gate() はテストと可読性ガードを && で連結している" "$RL_MECH_GATE_BODY" ;;
esac

# DEV_WORKFLOW_TEST_CMD 未設定時は、gh/git を呼ぶ前に停止すること
RL_FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin-rl.XXXXXX")"
for rl_fake in gh git; do
  cat > "${RL_FAKE_BIN}/${rl_fake}" <<'FAKE_BIN'
#!/bin/bash
exit 0
FAKE_BIN
  chmod +x "${RL_FAKE_BIN}/${rl_fake}"
done

RL_UNSET_OUT="$(PATH="${RL_FAKE_BIN}:${PATH}" DEV_WORKFLOW_DRY_RUN=1 DEV_WORKFLOW_TEST_CMD="" \
  bash "$RUN_LOOP_SCRIPT" 999 2>&1)"
RL_UNSET_EXIT=$?
assert_exit_code "run-loop.sh: DEV_WORKFLOW_TEST_CMD 未設定は exit 1" 1 "$RL_UNSET_EXIT"
case "$RL_UNSET_OUT" in
  *"DEV_WORKFLOW_TEST_CMD"*)
    pass "run-loop.sh: 未設定時のエラーメッセージに DEV_WORKFLOW_TEST_CMD を含む" ;;
  *)
    fail "run-loop.sh: 未設定時のエラーメッセージに DEV_WORKFLOW_TEST_CMD を含む" "$RL_UNSET_OUT" ;;
esac

RL_SET_OUT="$(PATH="${RL_FAKE_BIN}:${PATH}" DEV_WORKFLOW_DRY_RUN=1 DEV_WORKFLOW_TEST_CMD='true' \
  bash "$RUN_LOOP_SCRIPT" 999 2>&1)"
case "$RL_SET_OUT" in
  *"DEV_WORKFLOW_TEST_CMD が未設定です"*)
    fail "run-loop.sh: DEV_WORKFLOW_TEST_CMD 設定時は未設定エラーを出さない" "$RL_SET_OUT" ;;
  *)
    pass "run-loop.sh: DEV_WORKFLOW_TEST_CMD 設定時は未設定エラーを出さない" ;;
esac

# 伝播スキップ（skip <番号> reason depends-on-skipped <依存先番号>）を issue コメントし、
# 同一実行内で重複コメントしないこと（静的検証: 分岐と重複防止の仕組みが存在するか）
# 行番号を固定値でハードコードせず、目印となる固定文字列（grep -F）から範囲を求める。
RL_LOOP_START="$(grep -n -F 'read -r kind sub num extra dep; do' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_LOOP_END_REL="$(tail -n "+${RL_LOOP_START}" "$RUN_LOOP_SCRIPT" | grep -n -F 'done <<< "$PLAN"' | head -1 | cut -d: -f1)"
RL_LOOP_END=$((RL_LOOP_START + RL_LOOP_END_REL - 1))
RL_WARN_LOOP="$(sed -n "${RL_LOOP_START},${RL_LOOP_END}p" "$RUN_LOOP_SCRIPT")"
RL_WARN_LOOP_ONELINE="$(printf '%s' "$RL_WARN_LOOP" | tr '\n' ' ')"

RL_SKIP_BRANCH_OK=1
case "$RL_WARN_LOOP_ONELINE" in
  *'"$kind" = "skip"'*) : ;;
  *) RL_SKIP_BRANCH_OK=0 ;;
esac
case "$RL_WARN_LOOP_ONELINE" in
  *"gh issue comment"*) : ;;
  *) RL_SKIP_BRANCH_OK=0 ;;
esac
case "$RL_WARN_LOOP_ONELINE" in
  *"depends-on-skipped"*) : ;;
  *) RL_SKIP_BRANCH_OK=0 ;;
esac
if [ "$RL_SKIP_BRANCH_OK" -eq 1 ]; then
  pass "run-loop.sh: skip 行（伝播スキップ）を issue にコメントしている"
else
  fail "run-loop.sh: skip 行（伝播スキップ）を issue にコメントしている" "$RL_WARN_LOOP"
fi

case "$RL_WARN_LOOP_ONELINE" in
  *"PROPAGATED_CSV"*)
    pass "run-loop.sh: 伝播スキップの重複コメントを防ぐ仕組みがある" ;;
  *)
    fail "run-loop.sh: 伝播スキップの重複コメントを防ぐ仕組みがある" "$RL_WARN_LOOP" ;;
esac

# ---------------------------------------------------------------------------
# adapters/codex/run-loop.sh: watchdog / heartbeat の結線（Task #53）
#
# Epic #42 決定事項4: 両アダプタとも「検知して通知するだけ」に揃える（ハードタイムアウト・
# 自動再投入は実装しない）。--start は run-start より後、--wave は generator 起動前、
# --stop は正常終了・異常終了を問わず必ず通ること（trap ... EXIT）を検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== adapters/codex/run-loop.sh（watchdog結線・回帰防止 #53） =="

RL_FULL_SRC="$(cat "$RUN_LOOP_SCRIPT")"

# --start は notify-slack.sh run-start より後にあること（run マーカーより先に watchdog を
# 起動すると自己終了条件を誤検知しうるため）
RL_RUN_START_LINE="$(grep -n 'notify-slack.sh" run-start' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_WD_START_LINE="$(grep -n 'watchdog.sh" --start' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$RL_RUN_START_LINE" ] && [ -n "$RL_WD_START_LINE" ] && [ "$RL_WD_START_LINE" -gt "$RL_RUN_START_LINE" ]; then
  pass "run-loop.sh: watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#53）"
else
  fail "run-loop.sh: watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#53）" \
    "run-start行=${RL_RUN_START_LINE:-なし} --start行=${RL_WD_START_LINE:-なし}"
fi

# --wave は LANE_BRANCH 確定後・generator 起動（run_agent generator）前にあること
RL_WD_WAVE_LINE="$(grep -n 'watchdog.sh" --wave' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_LANE_BRANCH_LINE="$(grep -n 'LANE_BRANCH="task/' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_RUN_AGENT_GEN_LINE="$(grep -n 'run_agent generator' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$RL_WD_WAVE_LINE" ] && [ -n "$RL_LANE_BRANCH_LINE" ] && [ -n "$RL_RUN_AGENT_GEN_LINE" ] \
   && [ "$RL_WD_WAVE_LINE" -gt "$RL_LANE_BRANCH_LINE" ] && [ "$RL_WD_WAVE_LINE" -lt "$RL_RUN_AGENT_GEN_LINE" ]; then
  pass "run-loop.sh: watchdog.sh --wave の呼び出しが LANE_BRANCH確定後・generator起動前にある（#53）"
else
  fail "run-loop.sh: watchdog.sh --wave の呼び出しが LANE_BRANCH確定後・generator起動前にある（#53）" \
    "--wave行=${RL_WD_WAVE_LINE:-なし} LANE_BRANCH行=${RL_LANE_BRANCH_LINE:-なし} run_agent行=${RL_RUN_AGENT_GEN_LINE:-なし}"
fi

# --stop は trap ... EXIT で結線され、正常終了・異常終了・途中の exit を問わず必ず通ること
case "$RL_FULL_SRC" in
  *"trap '_run_loop_watchdog_stop' EXIT"*)
    pass "run-loop.sh: watchdog.sh --stop が trap ... EXIT で結線されている（#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh --stop が trap ... EXIT で結線されている（#53）" "" ;;
esac

case "$RL_FULL_SRC" in
  *'watchdog.sh" --stop'*)
    pass "run-loop.sh: watchdog.sh --stop の呼び出しが存在する（#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh --stop の呼び出しが存在する（#53）" "" ;;
esac

# trap は最初の `exit` より前（EPIC_NUMBER 未指定エラーより前）に仕掛けられていること
# （引数エラーのような早期終了経路でも --stop が通ることを保証するため）
RL_TRAP_LINE="$(grep -n "trap '_run_loop_watchdog_stop' EXIT" "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_FIRST_EXIT_LINE="$(grep -nE '^[[:space:]]*exit 1$' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$RL_TRAP_LINE" ] && [ -n "$RL_FIRST_EXIT_LINE" ] && [ "$RL_TRAP_LINE" -lt "$RL_FIRST_EXIT_LINE" ]; then
  pass "run-loop.sh: trap は最初の exit より前に仕掛けられている（早期終了経路もカバー・#53）"
else
  fail "run-loop.sh: trap は最初の exit より前に仕掛けられている（早期終了経路もカバー・#53）" \
    "trap行=${RL_TRAP_LINE:-なし} 最初のexit行=${RL_FIRST_EXIT_LINE:-なし}"
fi

# watchdog.sh が無い・失敗する環境でもループを止めないよう、--start / --wave の呼び出しが
# `|| true` で握りつぶされていること（--stop は trap 関数内部で握りつぶし済み）
RL_WD_START_TAIL="$(sed -n "${RL_WD_START_LINE}p" "$RUN_LOOP_SCRIPT")"
case "$RL_WD_START_TAIL" in
  *'|| true'*)
    pass "run-loop.sh: watchdog.sh --start の失敗はループを止めない（|| true・#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh --start の失敗はループを止めない（|| true・#53）" "$RL_WD_START_TAIL" ;;
esac

RL_WD_WAVE_BLOCK="$(sed -n "${RL_WD_WAVE_LINE},$((RL_WD_WAVE_LINE + 1))p" "$RUN_LOOP_SCRIPT")"
case "$RL_WD_WAVE_BLOCK" in
  *'|| true'*)
    pass "run-loop.sh: watchdog.sh --wave の失敗はループを止めない（|| true・#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh --wave の失敗はループを止めない（|| true・#53）" "$RL_WD_WAVE_BLOCK" ;;
esac

# タイムアウトによる kill 経路が存在しないこと（Epic #42 決定事項4:
# ハードタイムアウト・自動再投入は実装しない。両アダプタで機能差を作らない）
for RL_FORBIDDEN in 'kill -TERM' 'kill -9' 'DEV_WORKFLOW_AGENT_TIMEOUT_SEC'; do
  if grep -qF -- "$RL_FORBIDDEN" "$RUN_LOOP_SCRIPT"; then
    fail "run-loop.sh: タイムアウトによる kill 経路が存在しない（${RL_FORBIDDEN} 不在・#53）" \
      "$(grep -nF -- "$RL_FORBIDDEN" "$RUN_LOOP_SCRIPT")"
  else
    pass "run-loop.sh: タイムアウトによる kill 経路が存在しない（${RL_FORBIDDEN} 不在・#53）"
  fi
done

# --- 動的検証: DEV_WORKFLOW_DRY_RUN=1 で --start → --wave → --stop がこの順で呼ばれる。
#     watchdog.sh を差し替え可能なスタブ（呼び出し引数を記録するだけ）に置き換え、
#     実際に run-loop.sh 全体を DRY_RUN で走らせて確認する（Docker・codex には触れない）。
#     `${PLUGIN_ROOT_DIR}/scripts/watchdog.sh` は BASH_SOURCE から解決される絶対パスのため、
#     run-loop.sh・scripts 一式を一時ディレクトリへ複製し、その中の watchdog.sh だけを
#     差し替える（実リポジトリのファイルは一切変更しない）。
rl_build_fixture() {
  # rl_build_fixture <fixture_dir_var_prefix>
  # 呼び出し側の変数 <prefix>_ROOT / <prefix>_PROJECT / <prefix>_GH_DIR / <prefix>_WD_LOG を埋める。
  local prefix="$1"
  local fake_root project origin gh_dir wd_log
  fake_root="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-rl-root.XXXXXX")"
  mkdir -p "${fake_root}/adapters/codex" "${fake_root}/scripts"
  cp "$RUN_LOOP_SCRIPT" "${fake_root}/adapters/codex/run-loop.sh"
  cp -r "${REPO_ROOT}/scripts/." "${fake_root}/scripts/"

  origin="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-rl-origin.XXXXXX")"
  (cd "$origin" && git init -q --bare) >/dev/null 2>&1

  project="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-rl-project.XXXXXX")"
  (
    cd "$project" || exit 1
    git init -q
    git config user.email "dev-workflow-test@example.com"
    git config user.name "dev-workflow test"
    git remote add origin "$origin"
    printf 'test\n' > README.md
    git add README.md
    git commit -q -m init
    git branch "epic/epic999/watchdog-wiring"
    git push -q origin "epic/epic999/watchdog-wiring"
    mkdir -p .codex/agents
    printf 'name = "generator"\n' > .codex/agents/generator.toml
    printf 'name = "evaluator"\n' > .codex/agents/evaluator.toml
  ) >/dev/null 2>&1

  gh_dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-rl-ghfake.XXXXXX")"
  cat > "${gh_dir}/gh" <<'FAKE_GH'
#!/bin/bash
case "$*" in
  "issue view 999 --json body -q .body")
    printf 'ブランチ: epic/epic999/watchdog-wiring\n'
    ;;
  *"issue list --label task --state open"*)
    printf '501\x1f- 前提: なし\x1f- Epic: #999\n'
    ;;
  *)
    exit 0
    ;;
esac
FAKE_GH
  chmod +x "${gh_dir}/gh"

  wd_log="$(mktemp "${TMPDIR:-/tmp}/dw-test-rl-wdlog.XXXXXX")"

  eval "${prefix}_ROOT=\"\$fake_root\""
  eval "${prefix}_PROJECT=\"\$project\""
  eval "${prefix}_GH_DIR=\"\$gh_dir\""
  eval "${prefix}_WD_LOG=\"\$wd_log\""
}

rl_build_fixture RL_FX

# watchdog.sh を「呼び出し引数を1行ずつ記録するだけ」のスタブに差し替える
# （DEV_WORKFLOW_TEST_WATCHDOG_LOG が指す先へ追記。実際の監視は一切行わない）
cat > "${RL_FX_ROOT}/scripts/watchdog.sh" <<'FAKE_WD'
#!/bin/bash
echo "$*" >> "${DEV_WORKFLOW_TEST_WATCHDOG_LOG:?}"
exit 0
FAKE_WD
chmod +x "${RL_FX_ROOT}/scripts/watchdog.sh"

RL_DYN_OUT="$(
  PATH="${RL_FX_GH_DIR}:${PATH}" \
  DEV_WORKFLOW_DRY_RUN=1 \
  DEV_WORKFLOW_TEST_CMD='true' \
  DEV_WORKFLOW_MAX_TASKS=1 \
  DEV_WORKFLOW_TEST_WATCHDOG_LOG="$RL_FX_WD_LOG" \
  bash "${RL_FX_ROOT}/adapters/codex/run-loop.sh" 999 "$RL_FX_PROJECT" 2>&1
)"
RL_DYN_EXIT=$?

assert_exit_code "run-loop.sh: DRY_RUN実行（watchdogスタブあり）は exit 0 で完走する（#53）" 0 "$RL_DYN_EXIT"

RL_WD_CALLS="$(awk '{print $1}' "$RL_FX_WD_LOG" 2>/dev/null)"
assert_eq "run-loop.sh: DRY_RUN実行時、watchdog.shが --start → --wave → --stop の順で呼ばれる（#53）" \
  "$(printf -- '--start\n--wave\n--stop')" "$RL_WD_CALLS"

if [ "$(grep -c '^--wave' "$RL_FX_WD_LOG" 2>/dev/null)" = "1" ]; then
  pass "run-loop.sh: --wave はタスク1件（MAX_TASKS=1）につき1回だけ呼ばれる（#53）"
else
  fail "run-loop.sh: --wave はタスク1件（MAX_TASKS=1）につき1回だけ呼ばれる（#53）" "$(cat "$RL_FX_WD_LOG" 2>/dev/null)"
fi

case "$(grep '^--start' "$RL_FX_WD_LOG" 2>/dev/null)" in
  *'--epic epic999'*'--label Epic #999'*)
    pass "run-loop.sh: --start に --epic / --label が渡っている（#53）" ;;
  *)
    fail "run-loop.sh: --start に --epic / --label が渡っている（#53）" "$(grep '^--start' "$RL_FX_WD_LOG" 2>/dev/null)" ;;
esac

case "$(grep '^--wave' "$RL_FX_WD_LOG" 2>/dev/null)" in
  *'--epic epic999'*'--wave-no 1'*'--tasks 501'*)
    pass "run-loop.sh: --wave に --epic / --wave-no / --tasks が渡っている（#53）" ;;
  *)
    fail "run-loop.sh: --wave に --epic / --wave-no / --tasks が渡っている（#53）" "$(grep '^--wave' "$RL_FX_WD_LOG" 2>/dev/null)" ;;
esac

# --- watchdog.sh が無い環境でも run-loop 自体は継続すること ---
rl_build_fixture RL_FX2
# scripts/watchdog.sh を配置しない（「スクリプトが無い」環境の再現）
rm -f "${RL_FX2_ROOT}/scripts/watchdog.sh"

RL_MISSING_OUT="$(
  PATH="${RL_FX2_GH_DIR}:${PATH}" \
  DEV_WORKFLOW_DRY_RUN=1 \
  DEV_WORKFLOW_TEST_CMD='true' \
  DEV_WORKFLOW_MAX_TASKS=1 \
  bash "${RL_FX2_ROOT}/adapters/codex/run-loop.sh" 999 "$RL_FX2_PROJECT" 2>&1
)"
RL_MISSING_EXIT=$?

assert_exit_code "run-loop.sh: watchdog.sh が無くても run-loop 自体は exit 0 で継続する（#53）" 0 "$RL_MISSING_EXIT"

case "$RL_MISSING_OUT" in
  *"Epic一括レビュー"*)
    pass "run-loop.sh: watchdog.sh が無くてもEpic一括レビューまで到達する（#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh が無くてもEpic一括レビューまで到達する（#53）" "$RL_MISSING_OUT" ;;
esac

# ---------------------------------------------------------------------------
# skills/run/SKILL.md: 統合ゲート失敗時のリカバリと0レーン取り込みの分岐
# （回帰防止 #38, #41）
# ---------------------------------------------------------------------------

echo ""
echo "== skills/run/SKILL.md（統合ゲート失敗リカバリ・0レーン分岐の回帰防止 #38, #41） =="

RUN_SKILL="${REPO_ROOT}/skills/run/SKILL.md"

# #38: Step 8「統合ゲート失敗時の原因特定手順」は、この時点で checkout 中の wave ブランチに対して
# 実行される。`git branch -f` はチェックアウト中のブランチの強制更新を拒否するため使ってはならない。
RS_STEP8_RECOVERY="$(awk '/^#### 統合ゲート失敗時の原因特定手順/{f=1} /^#### スキップの伝播/{f=0} f' "$RUN_SKILL")"

case "$RS_STEP8_RECOVERY" in
  *'git branch -f "wave/'*)
    fail "SKILL.md: 統合ゲート失敗時の原因特定手順がチェックアウト中のwaveブランチに git branch -f を使っていない（#38）" "$RS_STEP8_RECOVERY" ;;
  *)
    pass "SKILL.md: 統合ゲート失敗時の原因特定手順がチェックアウト中のwaveブランチに git branch -f を使っていない（#38）" ;;
esac

case "$RS_STEP8_RECOVERY" in
  *'git checkout -B "wave/'*)
    pass "SKILL.md: 統合ゲート失敗時の原因特定手順が git checkout -B でwaveブランチを作り直す（#38）" ;;
  *)
    fail "SKILL.md: 統合ゲート失敗時の原因特定手順が git checkout -B でwaveブランチを作り直す（#38）" "$RS_STEP8_RECOVERY" ;;
esac

# #41: 取り込めたレーンが0本ならwaveブランチは存在しない。Step 5にその分岐が明記され、
# Step 6の冒頭にブランチ存在確認のガードがあること。
RS_STEP5="$(awk '/^### Step 5:/{f=1} /^### Step 6:/{f=0} f' "$RUN_SKILL")"

case "$RS_STEP5" in
  *"取り込めたレーンが0本"*)
    pass "SKILL.md: Step 5 に「取り込めたレーンが0本」の分岐が明記されている（#41）" ;;
  *)
    fail "SKILL.md: Step 5 に「取り込めたレーンが0本」の分岐が明記されている（#41）" "$RS_STEP5" ;;
esac

RS_STEP6="$(awk '/^### Step 6:/{f=1} /^### Step 7:/{f=0} f' "$RUN_SKILL")"

case "$RS_STEP6" in
  *'git rev-parse --verify'*)
    pass "SKILL.md: Step 6 冒頭に wave ブランチ存在確認のガードがある（#41）" ;;
  *)
    fail "SKILL.md: Step 6 冒頭に wave ブランチ存在確認のガードがある（#41）" "$RS_STEP6" ;;
esac

# ---------------------------------------------------------------------------
# skills/run/SKILL.md: watchdog の結線（--start/--wave/--stop）とハング時の
# 運用手順の記述（回帰防止 #51）
# ---------------------------------------------------------------------------

echo ""
echo "== skills/run/SKILL.md（watchdog結線・ハング時運用手順の回帰防止 #51） =="

# --start の呼び出しが run-start の記述より後にあること（run マーカーが立った後に
# watchdogを起動する契約。マーカーより先に起動すると自己終了条件を誤検知しうる）
RS_RUN_START_LINE="$(grep -n 'notify-slack.sh" run-start' "$RUN_SKILL" | head -1 | cut -d: -f1)"
RS_WATCHDOG_START_LINE="$(grep -n 'watchdog.sh" --start' "$RUN_SKILL" | head -1 | cut -d: -f1)"

if [ -n "$RS_RUN_START_LINE" ] && [ -n "$RS_WATCHDOG_START_LINE" ] && [ "$RS_WATCHDOG_START_LINE" -gt "$RS_RUN_START_LINE" ]; then
  pass "SKILL.md: watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#51）"
else
  fail "SKILL.md: watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#51）" \
    "run-start行=${RS_RUN_START_LINE:-なし} --start行=${RS_WATCHDOG_START_LINE:-なし}"
fi

# --wave の呼び出しが Step 2（WAVE_BASEを記録する節）にあること
RS_STEP2="$(awk '/^### Step 2:/{f=1} /^### Step 3:/{f=0} f' "$RUN_SKILL")"

case "$RS_STEP2" in
  *'watchdog.sh" --wave'*)
    pass "SKILL.md: watchdog.sh --wave の呼び出しが Step 2（WAVE_BASE）の節にある（#51）" ;;
  *)
    fail "SKILL.md: watchdog.sh --wave の呼び出しが Step 2（WAVE_BASE）の節にある（#51）" "$RS_STEP2" ;;
esac

# --stop の呼び出しが「正常終了・異常終了を問わず」と書かれた節の中にあり、
# かつ完了通知（run-complete）より前の位置にあること
RS_CLEANUP="$(awk '/^## サンドボックスの後片付け（正常終了・異常終了を問わず必ず実行）/{f=1} /^## /{if (f && !/サンドボックスの後片付け/) f=0} f' "$RUN_SKILL")"

case "$RS_CLEANUP" in
  *'watchdog.sh" --stop'*)
    pass "SKILL.md: watchdog.sh --stop の呼び出しが「正常終了・異常終了を問わず」の節にある（#51）" ;;
  *)
    fail "SKILL.md: watchdog.sh --stop の呼び出しが「正常終了・異常終了を問わず」の節にある（#51）" "$RS_CLEANUP" ;;
esac

RS_WATCHDOG_STOP_LINE="$(grep -n 'watchdog.sh" --stop' "$RUN_SKILL" | head -1 | cut -d: -f1)"
RS_RUN_COMPLETE_LINE="$(grep -n 'notify-slack.sh" run-complete' "$RUN_SKILL" | head -1 | cut -d: -f1)"

if [ -n "$RS_WATCHDOG_STOP_LINE" ] && [ -n "$RS_RUN_COMPLETE_LINE" ] && [ "$RS_WATCHDOG_STOP_LINE" -lt "$RS_RUN_COMPLETE_LINE" ]; then
  pass "SKILL.md: watchdog.sh --stop の呼び出しが完了通知（run-complete）より前の位置にある（#51）"
else
  fail "SKILL.md: watchdog.sh --stop の呼び出しが完了通知（run-complete）より前の位置にある（#51）" \
    "--stop行=${RS_WATCHDOG_STOP_LINE:-なし} run-complete行=${RS_RUN_COMPLETE_LINE:-なし}"
fi

# 「ハングしたときに人間がすること」の節が存在し、--abort の説明と再実行の手順を含むこと
RS_HANG_SECTION="$(awk '/^## ハングしたときに人間がすること/{f=1} /^## 進捗表示/{f=0} f' "$RUN_SKILL")"

if [ -n "$RS_HANG_SECTION" ]; then
  pass "SKILL.md: 「ハングしたときに人間がすること」の節が存在する（#51）"
else
  fail "SKILL.md: 「ハングしたときに人間がすること」の節が存在する（#51）" "節が見つかりません"
fi

case "$RS_HANG_SECTION" in
  *'watchdog.sh" --abort'*)
    pass "SKILL.md: ハング時の節に watchdog.sh --abort の説明がある（#51）" ;;
  *)
    fail "SKILL.md: ハング時の節に watchdog.sh --abort の説明がある（#51）" "$RS_HANG_SECTION" ;;
esac

case "$RS_HANG_SECTION" in
  *'/dev-workflow:run'*)
    pass "SKILL.md: ハング時の節に再実行（/dev-workflow:run）の手順がある（#51）" ;;
  *)
    fail "SKILL.md: ハング時の節に再実行（/dev-workflow:run）の手順がある（#51）" "$RS_HANG_SECTION" ;;
esac

# 「自動で打ち切って再投入することはできない」旨の記述が存在すること
case "$RS_HANG_SECTION" in
  *'自動で打ち切って再投入する'*'原理的にできない'*)
    pass "SKILL.md: 「自動で打ち切って再投入することはできない」旨の記述がある（#51）" ;;
  *)
    fail "SKILL.md: 「自動で打ち切って再投入することはできない」旨の記述がある（#51）" "$RS_HANG_SECTION" ;;
esac

# セッション中断後は watchdog.sh --stop を実行する旨の記述が存在すること（レビュー#62）。
# セッションをプロセスごと中断するとStopフックが発火せずrunマーカーが残り続け、
# watchdogが打ち切りに気付かないまま無活動検知・エスカレーション通知を出し続けるため。
case "$RS_HANG_SECTION" in
  *'watchdog.sh" --stop'*)
    pass "SKILL.md: ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" ;;
  *)
    fail "SKILL.md: ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" "$RS_HANG_SECTION" ;;
esac

case "$RS_HANG_SECTION" in
  *'Stop フックが走らず'*'run マーカー'*)
    pass "SKILL.md: セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" ;;
  *)
    fail "SKILL.md: セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" "$RS_HANG_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# skills/run/SKILL.md: WAVE_NO の採番ロジックと中断→再開時の挙動の記述（Task #54）
#
# 中断→再開で WAVE_NO がセッションごとに 0 から始まると、前回の残骸 wave ブランチを
# 誤って掴んでしまう事故が起きる（Epic #42 調査結果 7）。自律ループ冒頭で
# 既存の wave ブランチの番号の最大値から数え直すロジックが明記されていること、
# および再開時の挙動（残タスクの再計算・wave ブランチの採番し直し・取り込み済み
# コミットは失われない）が明記されていることを grep ベースで検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== skills/run/SKILL.md（WAVE_NO 採番・中断→再開時の挙動の回帰防止 #54） =="

RS_AUTONOMOUS_LOOP_HEADER="$(awk '/^## 自律ループ（YOLOモード、ウェーブ単位）/{f=1} /^### Step 1:/{f=0} f' "$RUN_SKILL")"

case "$RS_AUTONOMOUS_LOOP_HEADER" in
  *'for-each-ref'*'wave/${EPIC_NUM}/*'*)
    pass "SKILL.md: 自律ループ冒頭に既存 wave ブランチを列挙する WAVE_NO 採番ロジックがある（#54）" ;;
  *)
    fail "SKILL.md: 自律ループ冒頭に既存 wave ブランチを列挙する WAVE_NO 採番ロジックがある（#54）" "$RS_AUTONOMOUS_LOOP_HEADER" ;;
esac

case "$RS_AUTONOMOUS_LOOP_HEADER" in
  *'WAVE_NO="${WAVE_NO:-0}"'*)
    pass "SKILL.md: WAVE_NO 採番ロジックが既存ブランチ無しの場合 0 にフォールバックする（#54）" ;;
  *)
    fail "SKILL.md: WAVE_NO 採番ロジックが既存ブランチ無しの場合 0 にフォールバックする（#54）" "$RS_AUTONOMOUS_LOOP_HEADER" ;;
esac

case "$RS_AUTONOMOUS_LOOP_HEADER" in
  *'0 から始めてはならない'*)
    pass "SKILL.md: WAVE_NO を 0 から始めてはならない旨の説明がある（#54）" ;;
  *)
    fail "SKILL.md: WAVE_NO を 0 から始めてはならない旨の説明がある（#54）" "$RS_AUTONOMOUS_LOOP_HEADER" ;;
esac

RS_RESUME_SECTION="$(awk '/^3\. \*\*再開する場合\*\*/{f=1} /^\*\*Claude Code 側では/{f=0} f' "$RUN_SKILL")"

if [ -n "$RS_RESUME_SECTION" ]; then
  pass "SKILL.md: 「再開する場合」の説明ブロックが存在する（#54）"
else
  fail "SKILL.md: 「再開する場合」の説明ブロックが存在する（#54）" "節が見つかりません"
fi

case "$RS_RESUME_SECTION" in
  *'残タスクは open な Task issue'*'再計算される'*)
    pass "SKILL.md: 再開時に残タスクが open な Task issue から再計算される旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md: 再開時に残タスクが open な Task issue から再計算される旨の記述がある（#54）" "$RS_RESUME_SECTION" ;;
esac

case "$RS_RESUME_SECTION" in
  *'wave ブランチは採番し直される'*)
    pass "SKILL.md: 再開時に wave ブランチが採番し直される旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md: 再開時に wave ブランチが採番し直される旨の記述がある（#54）" "$RS_RESUME_SECTION" ;;
esac

case "$RS_RESUME_SECTION" in
  *'取り込み済みのコミットは失われない'*)
    pass "SKILL.md: 再開時に取り込み済みのコミットが失われない旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md: 再開時に取り込み済みのコミットが失われない旨の記述がある（#54）" "$RS_RESUME_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# skills-codex/dev-workflow-run/SKILL.md: 統合ゲートの記述が Claude 版と揃っていること
# （回帰防止 #37）
# ---------------------------------------------------------------------------

echo ""
echo "== skills-codex/dev-workflow-run/SKILL.md（統合ゲートの記述・回帰防止 #37） =="

CODEX_RUN_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"

CRS_STEP5="$(awk '/^### Step 5:/{f=1} /^### Step 6:/{f=0} f' "$CODEX_RUN_SKILL")"

case "$CRS_STEP5" in
  *"sandbox-exec.sh"*)
    pass "SKILL.md(codex): Step 5 が sandbox-exec.sh で全テストを実行する記述を含む" ;;
  *)
    fail "SKILL.md(codex): Step 5 が sandbox-exec.sh で全テストを実行する記述を含む" "$CRS_STEP5" ;;
esac

case "$CRS_STEP5" in
  *"check-readability.sh"*)
    pass "SKILL.md(codex): Step 5 が check-readability.sh の記述を含む" ;;
  *)
    fail "SKILL.md(codex): Step 5 が check-readability.sh の記述を含む" "$CRS_STEP5" ;;
esac

case "$CRS_STEP5" in
  *"対象の選択を"*"generator に委ねない"*)
    pass "SKILL.md(codex): Step 5 が「対象の選択をgeneratorに委ねない」を含む" ;;
  *)
    fail "SKILL.md(codex): Step 5 が「対象の選択をgeneratorに委ねない」を含む" "$CRS_STEP5" ;;
esac

case "$CRS_STEP5" in
  *"SKIP を通過扱いにしない"*)
    pass "SKILL.md(codex): Step 5 が「SKIPを通過扱いにしない」を含む" ;;
  *)
    fail "SKILL.md(codex): Step 5 が「SKIPを通過扱いにしない」を含む" "$CRS_STEP5" ;;
esac

if grep -q '^EPIC_NUMBER' "$CODEX_RUN_SKILL"; then
  fail "SKILL.md(codex): 未定義変数 \$EPIC_NUMBER を新たに導入していない" "EPIC_NUMBER の代入が見つかりました"
else
  if grep -q '\$EPIC_NUMBER' "$CODEX_RUN_SKILL"; then
    fail "SKILL.md(codex): 未定義変数 \$EPIC_NUMBER を参照していない" "$(grep -n '\$EPIC_NUMBER' "$CODEX_RUN_SKILL")"
  else
    pass "SKILL.md(codex): 未定義変数 \$EPIC_NUMBER を参照していない"
  fi
fi

# ---------------------------------------------------------------------------
# skills-codex/dev-workflow-run/SKILL.md: watchdog の結線（--start/--wave/--stop）と
# ハング時の運用手順の記述（回帰防止 #53。skills/run/SKILL.md #51 の Codex 側対応物）
# ---------------------------------------------------------------------------

echo ""
echo "== skills-codex/dev-workflow-run/SKILL.md（watchdog結線・ハング時運用手順の回帰防止 #53） =="

# --start の呼び出しが run-start の記述より後にあること
CRS_RUN_START_LINE="$(grep -n 'notify-slack.sh" run-start' "$CODEX_RUN_SKILL" | head -1 | cut -d: -f1)"
CRS_WATCHDOG_START_LINE="$(grep -n 'watchdog.sh" --start' "$CODEX_RUN_SKILL" | head -1 | cut -d: -f1)"

if [ -n "$CRS_RUN_START_LINE" ] && [ -n "$CRS_WATCHDOG_START_LINE" ] && [ "$CRS_WATCHDOG_START_LINE" -gt "$CRS_RUN_START_LINE" ]; then
  pass "SKILL.md(codex): watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#53）"
else
  fail "SKILL.md(codex): watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#53）" \
    "run-start行=${CRS_RUN_START_LINE:-なし} --start行=${CRS_WATCHDOG_START_LINE:-なし}"
fi

# --wave の呼び出しが Step 2（WAVE_BASEを記録し、レーンを作る節）にあること
CRS_STEP2="$(awk '/^### Step 2:/{f=1} /^### Step 3:/{f=0} f' "$CODEX_RUN_SKILL")"

case "$CRS_STEP2" in
  *'watchdog.sh" --wave'*)
    pass "SKILL.md(codex): watchdog.sh --wave の呼び出しが Step 2（WAVE_BASE）の節にある（#53）" ;;
  *)
    fail "SKILL.md(codex): watchdog.sh --wave の呼び出しが Step 2（WAVE_BASE）の節にある（#53）" "$CRS_STEP2" ;;
esac

# --stop の呼び出しが「正常終了・異常終了を問わず」と書かれた節の中にあり、
# かつ完了通知（run-complete）より前の位置にあること
CRS_CLEANUP="$(awk '/^## サンドボックスの後片付け（正常終了・異常終了を問わず必ず実行）/{f=1} /^## /{if (f && !/サンドボックスの後片付け/) f=0} f' "$CODEX_RUN_SKILL")"

case "$CRS_CLEANUP" in
  *'watchdog.sh" --stop'*)
    pass "SKILL.md(codex): watchdog.sh --stop の呼び出しが「正常終了・異常終了を問わず」の節にある（#53）" ;;
  *)
    fail "SKILL.md(codex): watchdog.sh --stop の呼び出しが「正常終了・異常終了を問わず」の節にある（#53）" "$CRS_CLEANUP" ;;
esac

CRS_WATCHDOG_STOP_LINE="$(grep -n 'watchdog.sh" --stop' "$CODEX_RUN_SKILL" | head -1 | cut -d: -f1)"
CRS_RUN_COMPLETE_LINE="$(grep -n 'notify-slack.sh" run-complete' "$CODEX_RUN_SKILL" | head -1 | cut -d: -f1)"

if [ -n "$CRS_WATCHDOG_STOP_LINE" ] && [ -n "$CRS_RUN_COMPLETE_LINE" ] && [ "$CRS_WATCHDOG_STOP_LINE" -lt "$CRS_RUN_COMPLETE_LINE" ]; then
  pass "SKILL.md(codex): watchdog.sh --stop の呼び出しが完了通知（run-complete）より前の位置にある（#53）"
else
  fail "SKILL.md(codex): watchdog.sh --stop の呼び出しが完了通知（run-complete）より前の位置にある（#53）" \
    "--stop行=${CRS_WATCHDOG_STOP_LINE:-なし} run-complete行=${CRS_RUN_COMPLETE_LINE:-なし}"
fi

# 「ハングしたときに人間がすること」の節が存在し、--abort の説明と再実行の手順を含むこと
CRS_HANG_SECTION="$(awk '/^## ハングしたときに人間がすること/{f=1} /^## Epic一括レビュー/{f=0} f' "$CODEX_RUN_SKILL")"

if [ -n "$CRS_HANG_SECTION" ]; then
  pass "SKILL.md(codex): 「ハングしたときに人間がすること」の節が存在する（#53）"
else
  fail "SKILL.md(codex): 「ハングしたときに人間がすること」の節が存在する（#53）" "節が見つかりません"
fi

case "$CRS_HANG_SECTION" in
  *'watchdog.sh" --abort'*)
    pass "SKILL.md(codex): ハング時の節に watchdog.sh --abort の説明がある（#53）" ;;
  *)
    fail "SKILL.md(codex): ハング時の節に watchdog.sh --abort の説明がある（#53）" "$CRS_HANG_SECTION" ;;
esac

# --abort はCodexではツール呼び出しを強制ブロックしない（ソフトな打ち切り依頼にとどまる）
# ことが明記されていること（レビュー#59。以前はClaude版と同一文面で「次のツール呼び出しで
# 効く」と誤って書かれていた）
case "$CRS_HANG_SECTION" in
  *'ブロックしない'*'ソフトな打ち切り依頼'*)
    pass "SKILL.md(codex): --abort がハードブロックではなくソフトな打ち切り依頼である旨が明記されている（#59）" ;;
  *)
    fail "SKILL.md(codex): --abort がハードブロックではなくソフトな打ち切り依頼である旨が明記されている（#59）" \
      "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'dev-workflow-run'*)
    pass "SKILL.md(codex): ハング時の節に再実行（dev-workflow-run スキル）の手順がある（#53）" ;;
  *)
    fail "SKILL.md(codex): ハング時の節に再実行（dev-workflow-run スキル）の手順がある（#53）" "$CRS_HANG_SECTION" ;;
esac

# 「自動で打ち切って再投入することはできない」旨の記述が存在すること（Claude版と同一方針）
case "$CRS_HANG_SECTION" in
  *'自動で打ち切って再投入する'*'実装しない'*)
    pass "SKILL.md(codex): 「自動で打ち切って再投入することは実装しない」旨の記述がある（#53）" ;;
  *)
    fail "SKILL.md(codex): 「自動で打ち切って再投入することは実装しない」旨の記述がある（#53）" "$CRS_HANG_SECTION" ;;
esac

# セッション中断後は watchdog.sh --stop を実行する旨の記述が存在すること（レビュー#62）。
# セッションをプロセスごと中断するとStopフックが発火せずrunマーカーが残り続け、
# watchdogが打ち切りに気付かないまま無活動検知・エスカレーション通知を出し続けるため。
case "$CRS_HANG_SECTION" in
  *'watchdog.sh" --stop'*)
    pass "SKILL.md(codex): ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" ;;
  *)
    fail "SKILL.md(codex): ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'Stop フックが走らず'*'run マーカー'*)
    pass "SKILL.md(codex): セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" ;;
  *)
    fail "SKILL.md(codex): セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" "$CRS_HANG_SECTION" ;;
esac

# --abort が届く保証は run-loop.sh 経由の generator/evaluator セッションに限られ、
# このスキルをセッション内で直接回す経路では依存できない旨が明記されていること（レビュー#63）
case "$CRS_HANG_SECTION" in
  *'run-loop.sh'*'に限られる'*)
    pass "SKILL.md(codex): --abort が届く保証はrun-loop.sh経由のセッションに限られる旨の記述がある（#63）" ;;
  *)
    fail "SKILL.md(codex): --abort が届く保証はrun-loop.sh経由のセッションに限られる旨の記述がある（#63）" \
      "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'このスキル'*'セッション内で直接回している場合は'*'--abort'*'依存できない'*)
    pass "SKILL.md(codex): スキルをセッション内で直接回す経路では--abortに依存できない旨の記述がある（#63）" ;;
  *)
    fail "SKILL.md(codex): スキルをセッション内で直接回す経路では--abortに依存できない旨の記述がある（#63）" \
      "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'cwd で'*'区別できず'*)
    pass "SKILL.md(codex): メインループとサブエージェントをcwdで区別できない旨の記述がある（#63）" ;;
  *)
    fail "SKILL.md(codex): メインループとサブエージェントをcwdで区別できない旨の記述がある（#63）" \
      "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'確実に止められる唯一の手段は'*'セッションそのものを中断し'*'watchdog.sh --stop'*)
    pass "SKILL.md(codex): スキル直接実行時の唯一の確実な打ち切り手段がセッション中断+watchdog.sh --stopである旨の記述がある（#63）" ;;
  *)
    fail "SKILL.md(codex): スキル直接実行時の唯一の確実な打ち切り手段がセッション中断+watchdog.sh --stopである旨の記述がある（#63）" \
      "$CRS_HANG_SECTION" ;;
esac

# Claude Code版と挙動が同じ（アダプタ間に機能差を作らない）旨の記述が
# ハング節・自律実行開始節のいずれかに存在すること
CRS_FULL_SRC="$(cat "$CODEX_RUN_SKILL")"
case "$CRS_FULL_SRC" in
  *'アダプタ間に機能差を'*'作らない'*)
    pass "SKILL.md(codex): 「アダプタ間に機能差を作らない」旨の記述がある（#53）" ;;
  *)
    fail "SKILL.md(codex): 「アダプタ間に機能差を作らない」旨の記述がある（#53）" "" ;;
esac

# ---------------------------------------------------------------------------
# skills-codex/dev-workflow-run/SKILL.md, adapters/codex/run-loop.sh:
# WAVE_NO の採番ロジックと中断→再開時の挙動の記述（Task #54。skills/run/SKILL.md #54 の
# Codex 側対応物。Codex は `--lanes 1` 固定で毎タスク --create を呼ぶため、この不具合の
# 影響を Claude Code 版よりも強く受ける）
# ---------------------------------------------------------------------------

echo ""
echo "== skills-codex/dev-workflow-run/SKILL.md・run-loop.sh（WAVE_NO 採番・中断→再開時の挙動の回帰防止 #54） =="

CRS_AUTONOMOUS_LOOP_HEADER="$(awk '/^## 自律ループ（`lanes=1` 固定のウェーブ実行）/{f=1} /^### Step 1:/{f=0} f' "$CODEX_RUN_SKILL")"

case "$CRS_AUTONOMOUS_LOOP_HEADER" in
  *'for-each-ref'*'wave/${EPIC_NUM}/*'*)
    pass "SKILL.md(codex): 自律ループ冒頭に既存 wave ブランチを列挙する WAVE_NO 採番ロジックがある（#54）" ;;
  *)
    fail "SKILL.md(codex): 自律ループ冒頭に既存 wave ブランチを列挙する WAVE_NO 採番ロジックがある（#54）" "$CRS_AUTONOMOUS_LOOP_HEADER" ;;
esac

case "$CRS_AUTONOMOUS_LOOP_HEADER" in
  *'0 から始めてはならない'*)
    pass "SKILL.md(codex): WAVE_NO を 0 から始めてはならない旨の説明がある（#54）" ;;
  *)
    fail "SKILL.md(codex): WAVE_NO を 0 から始めてはならない旨の説明がある（#54）" "$CRS_AUTONOMOUS_LOOP_HEADER" ;;
esac

CRS_RESUME_SECTION="$(awk '/^3\. \*\*再開する場合\*\*/{f=1} /^\*\*Codex 側でも/{f=0} f' "$CODEX_RUN_SKILL")"

if [ -n "$CRS_RESUME_SECTION" ]; then
  pass "SKILL.md(codex): 「再開する場合」の説明ブロックが存在する（#54）"
else
  fail "SKILL.md(codex): 「再開する場合」の説明ブロックが存在する（#54）" "節が見つかりません"
fi

case "$CRS_RESUME_SECTION" in
  *'wave ブランチは採番し直される'*)
    pass "SKILL.md(codex): 再開時に wave ブランチが採番し直される旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md(codex): 再開時に wave ブランチが採番し直される旨の記述がある（#54）" "$CRS_RESUME_SECTION" ;;
esac

case "$CRS_RESUME_SECTION" in
  *'取り込み済みのコミットは失われない'*)
    pass "SKILL.md(codex): 再開時に取り込み済みのコミットが失われない旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md(codex): 再開時に取り込み済みのコミットが失われない旨の記述がある（#54）" "$CRS_RESUME_SECTION" ;;
esac

# run-loop.sh 本体（実際に再実行されるスクリプト）でも同じ採番ロジックになっていること
RUN_LOOP_WAVE_NO_BLOCK="$(awk '/^WAVE_NO=\$\(git -C "\$EPIC_WT" for-each-ref/{p=1} p{print} p && /WAVE_NO="\$\{WAVE_NO:-0\}"/{exit}' "$RUN_LOOP_SCRIPT")"

if [ -n "$RUN_LOOP_WAVE_NO_BLOCK" ]; then
  pass "run-loop.sh: WAVE_NO が既存 wave ブランチの番号の最大値から採番される（#54）"
else
  fail "run-loop.sh: WAVE_NO が既存 wave ブランチの番号の最大値から採番される（#54）" "ブロックが見つかりません"
fi

if grep -qE '^WAVE_NO=0$' "$RUN_LOOP_SCRIPT"; then
  fail "run-loop.sh: WAVE_NO を 0 固定で初期化していない（残骸 wave ブランチを掴む回帰の再発防止 #54）" \
    "$(grep -nE '^WAVE_NO=0$' "$RUN_LOOP_SCRIPT")"
else
  pass "run-loop.sh: WAVE_NO を 0 固定で初期化していない（残骸 wave ブランチを掴む回帰の再発防止 #54）"
fi

# ---------------------------------------------------------------------------
# notify-slack.sh: watchdog イベント（stall / stall-recovered / sleep-gap / budget、Task #46）
#
# 実送信（curl）は使わず、DEV_WORKFLOW_NOTIFY_SINK にファイルパスを渡して
# 組み立てた本文（JSON）をそのファイルへ書き出させて検証する。加えて PATH に
# 偽 curl を差し込み、sink 経由では実際の curl が一度も呼ばれないことも確認する
# （Slack へは実送信しない・Epic #42 完了条件）。
# ---------------------------------------------------------------------------

echo ""
echo "== notify-slack.sh: watchdog イベント（Task #46） =="

NS_SCRIPT="${REPO_ROOT}/scripts/notify-slack.sh"
NS_REPO="$(make_temp_repo)"
NS_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-notify-work.XXXXXX")"

# 偽curl。sink経路では呼ばれてはならない（呼ばれたら呼び出し内容をログへ残す）
NS_FAKE_BIN="${NS_WORK}/bin"
mkdir -p "$NS_FAKE_BIN"
NS_CURL_LOG="${NS_WORK}/curl-calls.log"
printf '#!/bin/bash\necho "called: $*" >> "%s"\nexit 0\n' "$NS_CURL_LOG" > "${NS_FAKE_BIN}/curl"
chmod +x "${NS_FAKE_BIN}/curl"

run_notify() {
  # run_notify <event> <arg> <sink_file>
  # Webhookはダミーの https URL・sinkはファイルパスを渡し、curlを呼ばせずに検証する。
  (
    cd "$NS_REPO" || exit 1
    PATH="${NS_FAKE_BIN}:${PATH}" \
    SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
    DEV_WORKFLOW_PROJECT_NAME="dwtest" \
    DEV_WORKFLOW_NOTIFY_SINK="$3" \
    bash "$NS_SCRIPT" "$1" "$2" < /dev/null
  )
}

read_sink() {
  [ -f "$1" ] && cat "$1" || printf ''
}

# --- stall: state=pre（ツール実行中に停止） ---
NS_STALL_PRE_SINK="${NS_WORK}/stall-pre.json"
run_notify "stall" "無活動920秒 / レーンA / 最後のツール: Bash（state=pre: ツール実行中に停止）" "$NS_STALL_PRE_SINK"
NS_STALL_PRE_EXIT=$?
NS_STALL_PRE_BODY="$(read_sink "$NS_STALL_PRE_SINK")"

assert_exit_code "stall(state=pre): exit 0" 0 "$NS_STALL_PRE_EXIT"
case "$NS_STALL_PRE_BODY" in
  *"応答なし"*) pass "stall: 見出し «応答なし» を含む" ;;
  *) fail "stall: 見出し «応答なし» を含む" "$NS_STALL_PRE_BODY" ;;
esac
case "$NS_STALL_PRE_BODY" in
  *"ツール実行中に停止"*) pass "stall(state=pre): 本文に «ツール実行中に停止» を含む（受け入れ条件2）" ;;
  *) fail "stall(state=pre): 本文に «ツール実行中に停止» を含む（受け入れ条件2）" "$NS_STALL_PRE_BODY" ;;
esac
case "$NS_STALL_PRE_BODY" in
  *"モデルの応答待ちで停止"*) fail "stall(state=pre): «モデルの応答待ちで停止» を誤って含まない" "$NS_STALL_PRE_BODY" ;;
  *) pass "stall(state=pre): «モデルの応答待ちで停止» を誤って含まない" ;;
esac
case "$NS_STALL_PRE_BODY" in
  *"<!channel>"*) pass "stall: 既定のメンション <!channel> を含む" ;;
  *) fail "stall: 既定のメンション <!channel> を含む" "$NS_STALL_PRE_BODY" ;;
esac

# --- stall: state=post（モデルの応答待ちで停止） ---
NS_STALL_POST_SINK="${NS_WORK}/stall-post.json"
run_notify "stall" "無活動920秒 / レーンB / 最後のツール: (なし)（state=post: モデルの応答待ちで停止）" "$NS_STALL_POST_SINK"
NS_STALL_POST_EXIT=$?
NS_STALL_POST_BODY="$(read_sink "$NS_STALL_POST_SINK")"

assert_exit_code "stall(state=post): exit 0" 0 "$NS_STALL_POST_EXIT"
case "$NS_STALL_POST_BODY" in
  *"モデルの応答待ちで停止"*) pass "stall(state=post): 本文に «モデルの応答待ちで停止» を含む（受け入れ条件2）" ;;
  *) fail "stall(state=post): 本文に «モデルの応答待ちで停止» を含む（受け入れ条件2）" "$NS_STALL_POST_BODY" ;;
esac
case "$NS_STALL_POST_BODY" in
  *"ツール実行中に停止"*) fail "stall(state=post): «ツール実行中に停止» を誤って含まない" "$NS_STALL_POST_BODY" ;;
  *) pass "stall(state=post): «ツール実行中に停止» を誤って含まない" ;;
esac

# --- stall-recovered ---
NS_RECOVERED_SINK="${NS_WORK}/stall-recovered.json"
run_notify "stall-recovered" "無活動980秒から復帰 / レーンA" "$NS_RECOVERED_SINK"
NS_RECOVERED_EXIT=$?
NS_RECOVERED_BODY="$(read_sink "$NS_RECOVERED_SINK")"

assert_exit_code "stall-recovered: exit 0" 0 "$NS_RECOVERED_EXIT"
case "$NS_RECOVERED_BODY" in
  *"応答が再開"*"無活動980秒から復帰 / レーンA"*) pass "stall-recovered: 見出しと詳細を含む" ;;
  *) fail "stall-recovered: 見出しと詳細を含む" "$NS_RECOVERED_BODY" ;;
esac

# --- sleep-gap: stallとは別イベントとして区別できる（受け入れ条件3） ---
NS_SLEEPGAP_SINK="${NS_WORK}/sleep-gap.json"
run_notify "sleep-gap" "tick間隔60秒に対し実経過620秒（スリープ復帰と判定・無活動時間から差し引き済み）" "$NS_SLEEPGAP_SINK"
NS_SLEEPGAP_EXIT=$?
NS_SLEEPGAP_BODY="$(read_sink "$NS_SLEEPGAP_SINK")"

assert_exit_code "sleep-gap: exit 0" 0 "$NS_SLEEPGAP_EXIT"
case "$NS_SLEEPGAP_BODY" in
  *"スリープ痕跡"*"tick間隔60秒に対し実経過620秒"*) pass "sleep-gap: 見出しと詳細を含む" ;;
  *) fail "sleep-gap: 見出しと詳細を含む" "$NS_SLEEPGAP_BODY" ;;
esac
case "$NS_SLEEPGAP_BODY" in
  *"応答なし"*) fail "sleep-gap: stallの見出し «応答なし» を誤って含まない（受け入れ条件3）" "$NS_SLEEPGAP_BODY" ;;
  *) pass "sleep-gap: stallの見出し «応答なし» を誤って含まない（受け入れ条件3）" ;;
esac
case "$NS_STALL_PRE_BODY" in
  *"スリープ痕跡"*) fail "stall: sleep-gapの見出し «スリープ痕跡» を誤って含まない（受け入れ条件3）" "$NS_STALL_PRE_BODY" ;;
  *) pass "stall: sleep-gapの見出し «スリープ痕跡» を誤って含まない（受け入れ条件3）" ;;
esac

# --- budget ---
NS_BUDGET_SINK="${NS_WORK}/budget.json"
run_notify "budget" "ウェーブ2 / 経過98分 / 予算90分" "$NS_BUDGET_SINK"
NS_BUDGET_EXIT=$?
NS_BUDGET_BODY="$(read_sink "$NS_BUDGET_SINK")"

assert_exit_code "budget: exit 0" 0 "$NS_BUDGET_EXIT"
case "$NS_BUDGET_BODY" in
  *"想定時間超過"*"ウェーブ2 / 経過98分 / 予算90分"*) pass "budget: 見出しと詳細を含む" ;;
  *) fail "budget: 見出しと詳細を含む" "$NS_BUDGET_BODY" ;;
esac
case "$NS_BUDGET_BODY" in
  *"<!channel>"*) pass "budget: 既定のメンション <!channel> を含む" ;;
  *) fail "budget: 既定のメンション <!channel> を含む" "$NS_BUDGET_BODY" ;;
esac

# --- curlが一度も実行されていないこと（sink経路でネットワークに出ない） ---
if [ -s "$NS_CURL_LOG" ]; then
  fail "notify-slack.sh: sink使用時にcurlが呼ばれない（実送信しない）" "$(read_sink "$NS_CURL_LOG")"
else
  pass "notify-slack.sh: sink使用時にcurlが呼ばれない（実送信しない）"
fi

# --- Webhook未設定: 何もせずexit 0、標準出力・標準エラーも空、sinkにも書かれない ---
NS_NOWEBHOOK_SINK="${NS_WORK}/nowebhook.json"
NS_NOWEBHOOK_OUT="$(
  cd "$NS_REPO" || exit 1
  unset SLACK_WEBHOOK_URL
  PATH="${NS_FAKE_BIN}:${PATH}" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_NOWEBHOOK_SINK" \
  bash "$NS_SCRIPT" stall "無活動920秒" < /dev/null 2>&1
)"
NS_NOWEBHOOK_EXIT=$?

assert_exit_code "Webhook未設定: stallイベントはexit 0（既存の挙動を維持）" 0 "$NS_NOWEBHOOK_EXIT"
assert_eq "Webhook未設定: 標準出力・標準エラーが空" "" "$NS_NOWEBHOOK_OUT"
if [ -f "$NS_NOWEBHOOK_SINK" ]; then
  fail "Webhook未設定: sinkファイルが作られない" "sinkファイルが作成されました"
else
  pass "Webhook未設定: sinkファイルが作られない"
fi

# ---------------------------------------------------------------------------
# notify-slack.sh: 既存イベント（run-start / run-complete / stop / notification）の
# 挙動が変わっていないこと（Task #46 の回帰確認）
# ---------------------------------------------------------------------------

echo ""
echo "== notify-slack.sh: 既存イベントの回帰確認（Task #46） =="

# --- run-start: マーカーを作るだけで通知はしない ---
NS_RUNSTART_SINK="${NS_WORK}/run-start.json"
NS_RUNSTART_OUT="$(
  cd "$NS_REPO" || exit 1
  PATH="${NS_FAKE_BIN}:${PATH}" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_RUNSTART_SINK" \
  bash "$NS_SCRIPT" run-start "回帰テスト用ラベル" < /dev/null 2>&1
)"
NS_RUNSTART_EXIT=$?

assert_exit_code "run-start: exit 0（既存挙動）" 0 "$NS_RUNSTART_EXIT"
assert_eq "run-start: 標準出力・標準エラーが空（既存挙動）" "" "$NS_RUNSTART_OUT"
if [ -f "$NS_RUNSTART_SINK" ]; then
  fail "run-start: 通知しない（既存挙動）" "sinkに書き込みがありました"
else
  pass "run-start: 通知しない（既存挙動）"
fi
NS_RUNSTART_MARKER_FILE="${NS_REPO}/.claude/.dev-workflow-run"
if [ -f "$NS_RUNSTART_MARKER_FILE" ]; then
  assert_eq "run-start: マーカーにラベルを書く（既存挙動）" "回帰テスト用ラベル" "$(read_sink "$NS_RUNSTART_MARKER_FILE")"
else
  fail "run-start: マーカーが作られる（既存挙動）" "マーカーファイルがありません"
fi

# --- run-complete: マーカーを消し、ラベル入りの見出しで通知する ---
NS_RUNCOMPLETE_SINK="${NS_WORK}/run-complete.json"
NS_RUNCOMPLETE_OUT="$(
  cd "$NS_REPO" || exit 1
  PATH="${NS_FAKE_BIN}:${PATH}" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_RUNCOMPLETE_SINK" \
  bash "$NS_SCRIPT" run-complete "全タスク完了" < /dev/null 2>&1
)"
NS_RUNCOMPLETE_EXIT=$?
NS_RUNCOMPLETE_BODY="$(read_sink "$NS_RUNCOMPLETE_SINK")"

assert_exit_code "run-complete: exit 0（既存挙動）" 0 "$NS_RUNCOMPLETE_EXIT"
case "$NS_RUNCOMPLETE_BODY" in
  *"完了 — 回帰テスト用ラベル"*) pass "run-complete: 見出しにラベルを含む（既存挙動）" ;;
  *) fail "run-complete: 見出しにラベルを含む（既存挙動）" "$NS_RUNCOMPLETE_BODY" ;;
esac
case "$NS_RUNCOMPLETE_BODY" in
  *"全タスク完了"*) pass "run-complete: サマリーを本文に含む（既存挙動）" ;;
  *) fail "run-complete: サマリーを本文に含む（既存挙動）" "$NS_RUNCOMPLETE_BODY" ;;
esac
if [ -f "$NS_RUNSTART_MARKER_FILE" ]; then
  fail "run-complete: マーカーを消す（既存挙動）" "マーカーが残っています"
else
  pass "run-complete: マーカーを消す（既存挙動）"
fi

# --- stop: マーカーがある状態は「自律実行が停止」として通知しマーカーを消す ---
(
  cd "$NS_REPO" || exit 1
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="${NS_WORK}/run-start-2.json" \
  bash "$NS_SCRIPT" run-start "中断テスト用ラベル" < /dev/null
) >/dev/null 2>&1

NS_STOP_SINK="${NS_WORK}/stop.json"
NS_STOP_OUT="$(
  cd "$NS_REPO" || exit 1
  PATH="${NS_FAKE_BIN}:${PATH}" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_STOP_SINK" \
  bash "$NS_SCRIPT" stop <<< '{}' 2>&1
)"
NS_STOP_EXIT=$?
NS_STOP_BODY="$(read_sink "$NS_STOP_SINK")"

assert_exit_code "stop（マーカーあり）: exit 0（既存挙動）" 0 "$NS_STOP_EXIT"
case "$NS_STOP_BODY" in
  *"自律実行が停止 — 中断テスト用ラベル"*) pass "stop（マーカーあり）: 「自律実行が停止」の見出しを含む（既存挙動）" ;;
  *) fail "stop（マーカーあり）: 「自律実行が停止」の見出しを含む（既存挙動）" "$NS_STOP_BODY" ;;
esac
if [ -f "$NS_RUNSTART_MARKER_FILE" ]; then
  fail "stop（マーカーあり）: マーカーを消す（既存挙動）" "マーカーが残っています"
else
  pass "stop（マーカーあり）: マーカーを消す（既存挙動）"
fi

# --- notification: 承認待ちは既定でも通知される ---
NS_NOTIF_SINK="${NS_WORK}/notification.json"
NS_NOTIF_OUT="$(
  cd "$NS_REPO" || exit 1
  PATH="${NS_FAKE_BIN}:${PATH}" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_NOTIF_SINK" \
  DEV_WORKFLOW_NOTIFY_COOLDOWN=0 \
  bash "$NS_SCRIPT" notification <<< '{"message":"Claude needs your permission to use Bash"}' 2>&1
)"
NS_NOTIF_EXIT=$?
NS_NOTIF_BODY="$(read_sink "$NS_NOTIF_SINK")"

assert_exit_code "notification（承認待ち）: exit 0（既存挙動）" 0 "$NS_NOTIF_EXIT"
case "$NS_NOTIF_BODY" in
  *"承認待ち"*) pass "notification（承認待ち）: 見出しを含む（既存挙動）" ;;
  *) fail "notification（承認待ち）: 見出しを含む（既存挙動）" "$NS_NOTIF_BODY" ;;
esac

# --- 回帰確認の全呼び出しを通じてもcurlは一度も呼ばれていない ---
if [ -s "$NS_CURL_LOG" ]; then
  fail "notify-slack.sh: 既存イベントの検証中もcurlが呼ばれない" "$(read_sink "$NS_CURL_LOG")"
else
  pass "notify-slack.sh: 既存イベントの検証中もcurlが呼ばれない"
fi

# ---------------------------------------------------------------------------
# ケース: scripts/heartbeat.sh（フックから生存信号を記録・外部プロセス0、Task #44）
#
# PreToolUse / PostToolUse フックから高頻度に呼ばれるため、内部で date / jq / sed / grep
# を一切呼ばない（唯一の例外は原子的な置き換えに使う mv）。マーカールートの解決は
# scripts/lib/marker-root.sh（#43）に委譲する（Epic #42 仕様書「3. ファイルと責務」）。
# ---------------------------------------------------------------------------

echo "== scripts/heartbeat.sh（フックから生存信号を記録・外部プロセス0・Task #44） =="

HEARTBEAT_SCRIPT="${REPO_ROOT}/scripts/heartbeat.sh"

bash -n "$HEARTBEAT_SCRIPT" >/dev/null 2>&1
assert_exit_code "heartbeat.sh: bash -n が通る（構文エラーなし）" 0 $?

HB_MARKER_FILE=".dev-workflow-heartbeat"

# --- 書式: pre 呼び出しは <epoch>\t<pre>\t<ツール名> の1行だけを書く ---
HB_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HB_REPO}/.claude"
HB_TARGET="${HB_REPO}/.claude/${HB_MARKER_FILE}"

HB_JSON_PRE=$'{\n  "session_id": "abc",\n  "cwd": "'"${HB_REPO}"'",\n  "tool_name": "Bash",\n  "tool_input": {\n    "command": "echo hi"\n  }\n}'

HB_PRE_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" pre <<< "$HB_JSON_PRE" 2>&1)"
assert_exit_code "heartbeat.sh pre: exit 0 で終わる" 0 $?
assert_eq "heartbeat.sh pre: 無出力" "" "$HB_PRE_OUT"

if [ -f "$HB_TARGET" ]; then
  HB_EPOCH="" HB_STATE="" HB_TOOL=""
  IFS=$'\t' read -r HB_EPOCH HB_STATE HB_TOOL < "$HB_TARGET"
  case "$HB_EPOCH" in
    ''|*[!0-9]*) fail "heartbeat.sh pre: 1列目が epoch 秒（数字のみ）" "実際=[${HB_EPOCH}]" ;;
    *)           pass "heartbeat.sh pre: 1列目が epoch 秒（数字のみ）" ;;
  esac
  assert_eq "heartbeat.sh pre: 2列目が pre（ツール実行中を示す）" "pre" "$HB_STATE"
  assert_eq "heartbeat.sh pre: 3列目が複数行JSONからツール名を正しく抽出" "Bash" "$HB_TOOL"
  HB_LINE_COUNT="$(wc -l < "$HB_TARGET" | tr -d ' ')"
  assert_eq "heartbeat.sh pre: マーカーファイルは1行だけ" "1" "$HB_LINE_COUNT"
else
  fail "heartbeat.sh pre: マーカーファイルが書かれる" "存在しません: ${HB_TARGET}"
fi

# --- post 呼び出し: 別の state・別のツール名で上書き（追記ではなく置き換え） ---
HB_JSON_POST=$'{\n  "cwd": "'"${HB_REPO}"'",\n  "tool_name": "mcp__foo__bar"\n}'
HB_POST_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" post <<< "$HB_JSON_POST" 2>&1)"
assert_exit_code "heartbeat.sh post: exit 0 で終わる" 0 $?
assert_eq "heartbeat.sh post: 無出力" "" "$HB_POST_OUT"

IFS=$'\t' read -r HB_EPOCH2 HB_STATE2 HB_TOOL2 < "$HB_TARGET"
assert_eq "heartbeat.sh post: 2列目が post（モデル応答待ちを示す）" "post" "$HB_STATE2"
assert_eq "heartbeat.sh post: 3列目がツール名(mcp形式)を正しく抽出" "mcp__foo__bar" "$HB_TOOL2"
HB_LINE_COUNT2="$(wc -l < "$HB_TARGET" | tr -d ' ')"
assert_eq "heartbeat.sh post: 上書き後もマーカーファイルは1行だけ（追記でない）" "1" "$HB_LINE_COUNT2"

# --- ツール名が取れない入力でも "-" として記録し exit 0 ---
HB_JSON_NOTOOL=$'{\n  "cwd": "'"${HB_REPO}"'"\n}'
HB_NOTOOL_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" pre <<< "$HB_JSON_NOTOOL" 2>&1)"
assert_exit_code "heartbeat.sh: tool_name が無いJSONでも exit 0" 0 $?
IFS=$'\t' read -r HB_EPOCH3 HB_STATE3 HB_TOOL3 < "$HB_TARGET"
assert_eq "heartbeat.sh: tool_name が無ければ '-' として記録" "-" "$HB_TOOL3"

# --- 壊れたJSON（想定外の入力）でも exit 0、"-" として記録 ---
HB_GARBAGE='not even json { [ garbage without any structure'
HB_GARBAGE_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" post <<< "$HB_GARBAGE" 2>&1)"
assert_exit_code "heartbeat.sh: 壊れたJSONでも exit 0" 0 $?
assert_eq "heartbeat.sh: 壊れたJSONでも無出力" "" "$HB_GARBAGE_OUT"
IFS=$'\t' read -r HB_EPOCH4 HB_STATE4 HB_TOOL4 < "$HB_TARGET"
assert_eq "heartbeat.sh: 壊れたJSONでは '-' として記録" "-" "$HB_TOOL4"

# --- 空のstdinでも exit 0（記録は続ける。マーカールート自体は解決できているため） ---
HB_EMPTY_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" pre < /dev/null 2>&1)"
assert_exit_code "heartbeat.sh: 空のstdinでも exit 0" 0 $?
assert_eq "heartbeat.sh: 空のstdinでも無出力" "" "$HB_EMPTY_OUT"

# --- 不正な引数（pre/post以外）は無出力・exit 0 ---
HB_BADARG_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" bogus < /dev/null 2>&1)"
assert_exit_code "heartbeat.sh: 不正な引数でも exit 0" 0 $?
assert_eq "heartbeat.sh: 不正な引数では無出力" "" "$HB_BADARG_OUT"

# --- git管理外のディレクトリでは exit 0 かつ無出力（マーカーは書かない） ---
HB_NONGIT="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hb-nongit.XXXXXX")"
HB_NONGIT_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-hb-nongit-out.XXXXXX")"
(
  cd "$HB_NONGIT" || exit 1
  unset DEV_WORKFLOW_MARKER_ROOT CLAUDE_PROJECT_DIR
  bash "$HEARTBEAT_SCRIPT" pre < /dev/null > "$HB_NONGIT_OUT_FILE" 2>&1
)
HB_NONGIT_EXIT=$?
HB_NONGIT_OUT="$(cat "$HB_NONGIT_OUT_FILE")"
assert_exit_code "heartbeat.sh: git管理外のディレクトリでは exit 0" 0 "$HB_NONGIT_EXIT"
assert_eq "heartbeat.sh: git管理外のディレクトリでは無出力" "" "$HB_NONGIT_OUT"

# --- .claude が無いリポジトリでは exit 0 かつ無出力・マーカーは作られない ---
HB_NOCLAUDE_REPO="$(canon_root "$(make_temp_repo)")"
HB_NOCLAUDE_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-hb-noclaude-out.XXXXXX")"
DEV_WORKFLOW_MARKER_ROOT="$HB_NOCLAUDE_REPO" bash "$HEARTBEAT_SCRIPT" pre < /dev/null \
  > "$HB_NOCLAUDE_OUT_FILE" 2>&1
HB_NOCLAUDE_EXIT=$?
HB_NOCLAUDE_OUT="$(cat "$HB_NOCLAUDE_OUT_FILE")"
assert_exit_code "heartbeat.sh: .claude が無ければ exit 0" 0 "$HB_NOCLAUDE_EXIT"
assert_eq "heartbeat.sh: .claude が無ければ無出力" "" "$HB_NOCLAUDE_OUT"
if [ -e "${HB_NOCLAUDE_REPO}/.claude" ]; then
  fail "heartbeat.sh: .claude が無ければ作成もマーカー書き込みもしない" ".claude が作られました"
else
  pass "heartbeat.sh: .claude が無ければ作成もマーカー書き込みもしない"
fi

# --- worktreeから呼んでもメインリポのルートに書かれる ---
HB_WT_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HB_WT_REPO}/.claude"
HB_WT_DIR="${HB_WT_REPO}/.claude/worktrees/agent-hbtest"
make_worktree "$HB_WT_REPO" "$HB_WT_DIR" "hb-agent-branch"
HB_WT_JSON=$'{\n  "cwd": "'"${HB_WT_DIR}"'",\n  "tool_name": "Write"\n}'
(
  cd "$HB_WT_DIR" || exit 1
  unset DEV_WORKFLOW_MARKER_ROOT CLAUDE_PROJECT_DIR
  bash "$HEARTBEAT_SCRIPT" post <<< "$HB_WT_JSON" > /dev/null 2>&1
)
HB_WT_TARGET="${HB_WT_REPO}/.claude/${HB_MARKER_FILE}"
if [ -f "$HB_WT_TARGET" ]; then
  IFS=$'\t' read -r HB_WT_EPOCH HB_WT_STATE HB_WT_TOOL < "$HB_WT_TARGET"
  assert_eq "heartbeat.sh: worktreeから呼んでもメインリポのルートに書かれる" "Write" "$HB_WT_TOOL"
else
  fail "heartbeat.sh: worktreeから呼んでもメインリポのルートに書かれる" "存在しません: ${HB_WT_TARGET}"
fi

# --- 同時に複数プロセスから呼ばれても、常に「正しい1行」である（行の混在・破損が無い） ---
HB_CONC_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HB_CONC_REPO}/.claude"
HB_CONC_TARGET="${HB_CONC_REPO}/.claude/${HB_MARKER_FILE}"
HB_CONC_JSON_A=$'{\n  "cwd": "'"${HB_CONC_REPO}"'",\n  "tool_name": "ToolA"\n}'
HB_CONC_JSON_B=$'{\n  "cwd": "'"${HB_CONC_REPO}"'",\n  "tool_name": "ToolB"\n}'
HB_CONC_JSON_C=$'{\n  "cwd": "'"${HB_CONC_REPO}"'",\n  "tool_name": "ToolC"\n}'
(
  DEV_WORKFLOW_MARKER_ROOT="$HB_CONC_REPO" bash "$HEARTBEAT_SCRIPT" pre  <<< "$HB_CONC_JSON_A" >/dev/null 2>&1 &
  DEV_WORKFLOW_MARKER_ROOT="$HB_CONC_REPO" bash "$HEARTBEAT_SCRIPT" post <<< "$HB_CONC_JSON_B" >/dev/null 2>&1 &
  DEV_WORKFLOW_MARKER_ROOT="$HB_CONC_REPO" bash "$HEARTBEAT_SCRIPT" pre  <<< "$HB_CONC_JSON_C" >/dev/null 2>&1 &
  wait
)
HB_CONC_LINES="$(wc -l < "$HB_CONC_TARGET" | tr -d ' ')"
assert_eq "heartbeat.sh: 並行3プロセスから呼ばれてもファイルは常に1行" "1" "$HB_CONC_LINES"
IFS=$'\t' read -r HB_CONC_EPOCH HB_CONC_STATE HB_CONC_TOOL < "$HB_CONC_TARGET"
case "$HB_CONC_STATE" in
  pre|post) : ;;
  *) HB_CONC_STATE="invalid" ;;
esac
case "$HB_CONC_TOOL" in
  ToolA|ToolB|ToolC) : ;;
  *) HB_CONC_TOOL="invalid" ;;
esac
if [ "$HB_CONC_STATE" != "invalid" ] && [ "$HB_CONC_TOOL" != "invalid" ]; then
  pass "heartbeat.sh: 並行書き込みの結果は3者のいずれか1つの完全な行（破損・混在なし）"
else
  fail "heartbeat.sh: 並行書き込みの結果は3者のいずれか1つの完全な行（破損・混在なし）" \
    "実際の内容: $(cat "$HB_CONC_TARGET" 2>/dev/null)"
fi

# --- stdinがttyのときは読まない設計になっていることの静的確認 ---
if grep -qE '\[ ! -t 0 \]' "$HEARTBEAT_SCRIPT"; then
  pass "heartbeat.sh: stdinがtty（対話実行）のときは読まないガードがある"
else
  fail "heartbeat.sh: stdinがtty（対話実行）のときは読まないガードがある" "[ ! -t 0 ] が見つかりません"
fi

# --- スクリプト本体が date / jq を呼んでいないことの静的確認（受け入れ条件10の前提） ---
# コメント行は対象外にし、単語境界での一致だけを見る
HB_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$HEARTBEAT_SCRIPT" \
  | grep -E '(^|[^A-Za-z0-9_])(date|jq)[[:space:]]' || true)"
if [ -z "$HB_FORBIDDEN_HITS" ]; then
  pass "heartbeat.sh: スクリプト本体が date / jq を呼んでいない"
else
  fail "heartbeat.sh: スクリプト本体が date / jq を呼んでいない" "$HB_FORBIDDEN_HITS"
fi

# --- 性能: 100回連続実行が「素のプロセス起動コスト」に対して過大でないこと（受け入れ条件10） ---
# heartbeat.sh は毎回 bash プロセスとして spawn される（フック呼び出しの実態）ため、
# 絶対時間には bind mount 越しのファイル open や git worktree 越しのサンドボックスなど
# 実行環境固有のプロセス起動オーバーヘッドが乗る（実測: Docker Desktop on Windows の
# bind mount 環境では、素の `bash -c 'exit 0'` を100回起動するだけで数秒かかることがある）。
# 絶対時間を固定の秒数で決め打つと環境差でフレーキーになるため、同一環境で素のプロセス起動を
# 100回行った基準時間（FLOOR）を測り、heartbeat.sh 自身のロジック（marker-root.sh の
# source・stdin読み取り・tmp書き込み+mv）に許される予算をその上乗せ分として評価する。
# 外部プロセス（date/jq等）を呼ぶ regression が入れば、その分だけ FLOOR に対して余分な
# プロセス起動が積み増しされるため、この相対評価でも十分検出できる。
HB_PERF_FLOOR_START=""
printf -v HB_PERF_FLOOR_START '%(%s)T' -1
HB_PERF_FLOOR_I=0
while [ "$HB_PERF_FLOOR_I" -lt 100 ]; do
  bash -c 'exit 0' >/dev/null 2>&1
  HB_PERF_FLOOR_I=$((HB_PERF_FLOOR_I + 1))
done
HB_PERF_FLOOR_END=""
printf -v HB_PERF_FLOOR_END '%(%s)T' -1
HB_PERF_FLOOR=$((HB_PERF_FLOOR_END - HB_PERF_FLOOR_START))

HB_PERF_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HB_PERF_REPO}/.claude"
HB_PERF_JSON=$'{\n  "cwd": "'"${HB_PERF_REPO}"'",\n  "tool_name": "Bash"\n}'
HB_PERF_START=""
printf -v HB_PERF_START '%(%s)T' -1
HB_PERF_I=0
while [ "$HB_PERF_I" -lt 100 ]; do
  DEV_WORKFLOW_MARKER_ROOT="$HB_PERF_REPO" bash "$HEARTBEAT_SCRIPT" pre <<< "$HB_PERF_JSON" >/dev/null 2>&1
  HB_PERF_I=$((HB_PERF_I + 1))
done
HB_PERF_END=""
printf -v HB_PERF_END '%(%s)T' -1
HB_PERF_ELAPSED=$((HB_PERF_END - HB_PERF_START))

# FLOOR + 5秒: heartbeat.sh 自身の純粋なbashロジック（外部プロセス無し）に許される予算。
HB_PERF_BUDGET=$((HB_PERF_FLOOR + 5))
if [ "$HB_PERF_ELAPSED" -le "$HB_PERF_BUDGET" ]; then
  pass "heartbeat.sh: 100回連続実行がプロセス起動コストに対して過大でない（実測 ${HB_PERF_ELAPSED}s / floor ${HB_PERF_FLOOR}s+5s予算・受け入れ条件10）"
else
  fail "heartbeat.sh: 100回連続実行がプロセス起動コストに対して過大でない" \
    "実測 ${HB_PERF_ELAPSED}s > floor ${HB_PERF_FLOOR}s + 5s予算"
fi

# ---------------------------------------------------------------------------
# scripts/heartbeat.sh: 打ち切り（--abort）判定（Task #50、Epic #42。cwd拡張はレビュー#59, #61）
#
# .dev-workflow-abort は人間が watchdog.sh --abort を明示的に叩いたときだけ作られる
# （Epic #42 仕様書「5. 打ち切りの仕様」）。heartbeat.sh pre はこのフラグと、フック入力
# JSON の cwd が Claude のisolation worktree（.claude/worktrees/agent-）または
# Codex のEpic共有worktree（.codex/worktrees/。Codexにはタスクごとのisolation worktreeが
# 無いため代わりにこちらを対象にする）を含む場合にのみツール呼び出しを拒否する。
# run のメインループ（Claude: epic worktree・リポジトリルート／Codex: run-loop.sh自体は
# codexセッションではなくフックが発火しない）は絶対に拒否しない。
# Codexのブロック契約はsystemMessageのみでcontinue非対応（後述）のため、実際にはハード
# ブロックにならないソフトな打ち切り依頼になる点に注意（詳細はheartbeat.sh本体を参照）。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/heartbeat.sh: 打ち切り（--abort）判定（Task #50） =="

HBA_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HBA_REPO}/.claude"
HBA_ABORT_FLAG="${HBA_REPO}/.claude/.dev-workflow-abort"
HBA_AGENT_CWD="${HBA_REPO}/.claude/worktrees/agent-hba-test"
HBA_EPIC_CWD="${HBA_REPO}/.claude/worktrees/epic99"
HBA_ROOT_CWD="${HBA_REPO}"

printf 'テスト用の打ち切り理由\n' > "$HBA_ABORT_FLAG"

# --- フラグあり + cwdがagent worktree → 拒否される（Claude契約: exit 2 + stderr） ---
HBA_JSON_AGENT=$'{\n  "cwd": "'"${HBA_AGENT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_AGENT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_AGENT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・agent worktreeのcwd → exit 2で拒否" 2 $?
case "$HBA_AGENT_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: 拒否メッセージに--abortの理由が含まれる" ;;
  *)                          fail "heartbeat.sh: 拒否メッセージに--abortの理由が含まれる" "$HBA_AGENT_OUT" ;;
esac
case "$HBA_AGENT_OUT" in
  *"打ち切りが指示されました"*) pass "heartbeat.sh: 拒否メッセージに中止・報告の指示が含まれる" ;;
  *)                            fail "heartbeat.sh: 拒否メッセージに中止・報告の指示が含まれる" "$HBA_AGENT_OUT" ;;
esac

# 拒否されても生存信号自体は記録される（打ち切り判定は書き込みの後に行う設計）
if [ -f "${HBA_REPO}/.claude/.dev-workflow-heartbeat" ]; then
  pass "heartbeat.sh: 拒否時も生存信号（heartbeatマーカー）は記録される"
else
  fail "heartbeat.sh: 拒否時も生存信号（heartbeatマーカー）は記録される" "マーカーファイルが無い"
fi

# --- フラグあり + cwdがepic worktree → 拒否されない（run本体を絶対に殺さない） ---
HBA_JSON_EPIC=$'{\n  "cwd": "'"${HBA_EPIC_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_EPIC_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_EPIC" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・epic worktreeのcwd → 拒否されない（exit 0）" 0 $?
assert_eq "heartbeat.sh: abortフラグあり・epic worktreeのcwd → 無出力" "" "$HBA_EPIC_OUT"

# --- フラグあり + cwdがリポジトリルート → 拒否されない ---
HBA_JSON_ROOT=$'{\n  "cwd": "'"${HBA_ROOT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_ROOT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_ROOT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・リポジトリルートのcwd → 拒否されない（exit 0）" 0 $?
assert_eq "heartbeat.sh: abortフラグあり・リポジトリルートのcwd → 無出力" "" "$HBA_ROOT_OUT"

# --- フラグが無ければ、cwdがagent worktreeでも拒否されない ---
HBA_NOFLAG_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HBA_NOFLAG_REPO}/.claude"
HBA_NOFLAG_AGENT_CWD="${HBA_NOFLAG_REPO}/.claude/worktrees/agent-hba-noflag"
HBA_JSON_NOFLAG=$'{\n  "cwd": "'"${HBA_NOFLAG_AGENT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_NOFLAG_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_NOFLAG_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_NOFLAG" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグが無ければagent worktreeでも拒否されない" 0 $?

# --- Codex契約: exit 0 + stdoutに {"continue":false, ...} のJSON ---
HBA_CODEX_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=codex \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_AGENT" 2>&1)"
assert_exit_code "heartbeat.sh: Codex契約はexit 0で終わる" 0 $?
case "$HBA_CODEX_OUT" in
  *'"continue":false'*) pass "heartbeat.sh: Codex契約はstdoutに\"continue\":falseを含むJSONを出す" ;;
  *)                     fail "heartbeat.sh: Codex契約はstdoutに\"continue\":falseを含むJSONを出す" "$HBA_CODEX_OUT" ;;
esac
case "$HBA_CODEX_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: Codex契約のJSONにも--abortの理由が含まれる" ;;
  *)                          fail "heartbeat.sh: Codex契約のJSONにも--abortの理由が含まれる" "$HBA_CODEX_OUT" ;;
esac

# --- フラグあり + cwdがCodexのEpic共有worktree（.codex/worktrees/<epic>）→ 打ち切り判定の
#     対象になる（レビュー#59, #61）。Codexにはタスクごとのisolation worktreeという概念自体が
#     無く、generator/evaluatorは常にこの共有worktreeで動くため、Claudeの
#     `.claude/worktrees/agent-` と同じ役割をこのパターンが担う ---
HBA_CODEX_WT_CWD="${HBA_REPO}/.codex/worktrees/42"
HBA_JSON_CODEX_WT=$'{\n  "cwd": "'"${HBA_CODEX_WT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_CODEX_WT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=codex \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_CODEX_WT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・Codex共有worktree(.codex/worktrees/)のcwd → exit 0で終わる（Codex契約。#59, #61）" \
  0 $?
case "$HBA_CODEX_WT_OUT" in
  *'"continue":false'*) pass "heartbeat.sh: Codex共有worktreeのcwdでもstdoutに\"continue\":falseを含むJSONを出す（#59, #61）" ;;
  *)                     fail "heartbeat.sh: Codex共有worktreeのcwdでもstdoutに\"continue\":falseを含むJSONを出す（#59, #61）" \
    "$HBA_CODEX_WT_OUT" ;;
esac
case "$HBA_CODEX_WT_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: Codex共有worktreeのcwdでも--abortの理由がJSONに含まれる（#59, #61）" ;;
  *)                          fail "heartbeat.sh: Codex共有worktreeのcwdでも--abortの理由がJSONに含まれる（#59, #61）" \
    "$HBA_CODEX_WT_OUT" ;;
esac

# --- フラグが無ければ、cwdがCodex共有worktreeでも拒否されない ---
HBA_CODEX_WT_NOFLAG_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_NOFLAG_REPO" DEV_WORKFLOW_HOOK_VENDOR=codex \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$(printf '{\n  "cwd": "%s/.codex/worktrees/42",\n  "tool_name": "Bash"\n}' "$HBA_NOFLAG_REPO")" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグが無ければCodex共有worktreeでも拒否されない" 0 $?

# --- postでは拒否しない（フラグあり・agent worktreeのcwdでも） ---
HBA_POST_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" post <<< "$HBA_JSON_AGENT" 2>&1)"
assert_exit_code "heartbeat.sh: postでは拒否しない（フラグ・agent cwdがあってもexit 0）" 0 $?
assert_eq "heartbeat.sh: postでは無出力" "" "$HBA_POST_OUT"

# --- Windowsネイティブパス表現（バックスラッシュ、JSONでは二重エスケープ）のcwd正規化
#     （レビュー#60）。scripts/check-readability.sh:220-221 と同じ「JSONエスケープ解除
#     （\\ → \）+ Windowsパス正規化（\ → /）」がheartbeat.shにも入っていることを、
#     cwdがバックスラッシュ表現で来た場合に確認する。 ---

# フラグあり + cwdがWindows表現のagent worktree(.claude\worktrees\agent-) → 拒否される
HBA_WIN_AGENT_CWD='C:\\Users\\hba-win\\.claude\\worktrees\\agent-hba-winpath'
HBA_JSON_WIN_AGENT=$'{\n  "cwd": "'"${HBA_WIN_AGENT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_WIN_AGENT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_WIN_AGENT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・Windows表現(バックスラッシュ)のagent worktreeのcwd → exit 2で拒否（#60）" \
  2 $?
case "$HBA_WIN_AGENT_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: Windows表現のcwdでも拒否メッセージに--abortの理由が含まれる（#60）" ;;
  *) fail "heartbeat.sh: Windows表現のcwdでも拒否メッセージに--abortの理由が含まれる（#60）" "$HBA_WIN_AGENT_OUT" ;;
esac

# フラグあり + cwdがWindows表現のCodex共有worktree(.codex\worktrees\) → 拒否される（Codex契約）
HBA_WIN_CODEX_WT_CWD='C:\\Users\\hba-win\\.codex\\worktrees\\epic42'
HBA_JSON_WIN_CODEX_WT=$'{\n  "cwd": "'"${HBA_WIN_CODEX_WT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_WIN_CODEX_WT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=codex \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_WIN_CODEX_WT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・Windows表現(バックスラッシュ)のCodex共有worktreeのcwd → exit 0で終わる（Codex契約。#60）" \
  0 $?
case "$HBA_WIN_CODEX_WT_OUT" in
  *'"continue":false'*) pass "heartbeat.sh: Windows表現のCodex共有worktreeのcwdでもstdoutに\"continue\":falseを含むJSONを出す（#60）" ;;
  *) fail "heartbeat.sh: Windows表現のCodex共有worktreeのcwdでもstdoutに\"continue\":falseを含むJSONを出す（#60）" \
    "$HBA_WIN_CODEX_WT_OUT" ;;
esac
case "$HBA_WIN_CODEX_WT_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: Windows表現のCodex共有worktreeのcwdでも--abortの理由がJSONに含まれる（#60）" ;;
  *) fail "heartbeat.sh: Windows表現のCodex共有worktreeのcwdでも--abortの理由がJSONに含まれる（#60）" \
    "$HBA_WIN_CODEX_WT_OUT" ;;
esac

# フラグあり + cwdがWindows表現のepic worktree(agent-プレフィックスなし) → 拒否されない
# （正規化してもagent-パターン・.codex/worktrees/パターンいずれにも一致しないこと）
HBA_WIN_EPIC_CWD='C:\\Users\\hba-win\\.claude\\worktrees\\epic99'
HBA_JSON_WIN_EPIC=$'{\n  "cwd": "'"${HBA_WIN_EPIC_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_WIN_EPIC_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_WIN_EPIC" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・Windows表現のepic worktreeのcwd → 拒否されない（exit 0。#60）" \
  0 $?
assert_eq "heartbeat.sh: abortフラグあり・Windows表現のepic worktreeのcwd → 無出力（#60）" "" "$HBA_WIN_EPIC_OUT"

# --- heartbeat.sh冒頭コメント: Codexのrun経路2つ（run-loop.sh経由 / スキルをセッション内で
#     直接回す経路）を区別した記述になっていること（レビュー#63）。以前は「Codexではrun-loop.sh
#     自体がbashスクリプトでフックの発火源ではないため、そもそもこのフックが呼ばれない」という
#     包括的な主張をしていたが、スキル`dev-workflow-run`をセッション内で直接回す経路では
#     メインループ自身がcodexセッションであり、この主張が成立しない。 ---
HB_COMMENT="$(cat "$HEARTBEAT_SCRIPT")"

case "$HB_COMMENT" in
  *'codex exec -C "$EPIC_WT"'*'generator/evaluator'*)
    pass "heartbeat.sh: .codex/worktrees/パターンがrun-loop.shのcodex exec -Cで起動するgenerator/evaluatorセッションを対象にする旨の記述がある（#63）" ;;
  *)
    fail "heartbeat.sh: .codex/worktrees/パターンがrun-loop.shのcodex exec -Cで起動するgenerator/evaluatorセッションを対象にする旨の記述がある（#63）" \
      "$HB_COMMENT" ;;
esac

case "$HB_COMMENT" in
  *'dev-workflow-run'*'セッション内で直接回す経路'*'同一セッション内'*)
    pass "heartbeat.sh: スキルをセッション内で直接回す経路ではメインループとサブエージェントが同一セッションである旨の記述がある（#63）" ;;
  *)
    fail "heartbeat.sh: スキルをセッション内で直接回す経路ではメインループとサブエージェントが同一セッションである旨の記述がある（#63）" \
      "$HB_COMMENT" ;;
esac

case "$HB_COMMENT" in
  *'区別できるcwdの差を持たず'*)
    pass "heartbeat.sh: スキル直接実行経路ではメインループとサブエージェントをcwdで区別できない旨の記述がある（#63）" ;;
  *)
    fail "heartbeat.sh: スキル直接実行経路ではメインループとサブエージェントをcwdで区別できない旨の記述がある（#63）" \
      "$HB_COMMENT" ;;
esac

# レビュー#63以前の「Codexではフックがそもそも呼ばれない」という無限定の主張のまま
# 放置されていないこと（スキル直接実行経路への言及なしにこの一文だけが単独で成立していると
# 誤りになる。#63の指摘そのものの再発防止）
if printf '%s' "$HB_COMMENT" | grep -q 'セッション内で直接回す経路'; then
  pass "heartbeat.sh: 「Codexではフックが呼ばれない」という主張がスキル直接実行経路の言及なしに単独で残っていない（#63）"
else
  fail "heartbeat.sh: 「Codexではフックが呼ばれない」という主張がスキル直接実行経路の言及なしに単独で残っていない（#63）" \
    "$HB_COMMENT"
fi

# --- watchdog.sh --abort / --clear との結合: 実際にwatchdog.shで作った/消したフラグで動く ---
HBA_WD_SCRIPT="${REPO_ROOT}/scripts/watchdog.sh"
HBA_INT_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HBA_INT_REPO}/.claude"
HBA_INT_AGENT_CWD="${HBA_INT_REPO}/.claude/worktrees/agent-hba-integ"
HBA_JSON_INT=$'{\n  "cwd": "'"${HBA_INT_AGENT_CWD}"'",\n  "tool_name": "Bash"\n}'

DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" bash "$HBA_WD_SCRIPT" --abort "結合テストの理由" >/dev/null 2>&1
HBA_INT_OUT1="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_INT" 2>&1)"
assert_exit_code "heartbeat.sh: watchdog.sh --abortで作ったフラグにより拒否される" 2 $?
case "$HBA_INT_OUT1" in
  *"結合テストの理由"*) pass "heartbeat.sh: watchdog.sh --abortの理由がそのまま拒否メッセージに載る" ;;
  *)                     fail "heartbeat.sh: watchdog.sh --abortの理由がそのまま拒否メッセージに載る" "$HBA_INT_OUT1" ;;
esac

DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" bash "$HBA_WD_SCRIPT" --abort --clear >/dev/null 2>&1
if [ -f "${HBA_INT_REPO}/.claude/.dev-workflow-abort" ]; then
  fail "watchdog.sh --abort --clear: フラグファイルが削除される"
else
  pass "watchdog.sh --abort --clear: フラグファイルが削除される"
fi
HBA_INT_OUT2="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_INT" 2>&1)"
assert_exit_code "heartbeat.sh: --abort --clear の後は拒否されない" 0 $?
assert_eq "heartbeat.sh: --abort --clear の後は無出力" "" "$HBA_INT_OUT2"

# watchdog.sh --abort / --abort --clear のログ記録
HBA_WD_LOG="${HBA_INT_REPO}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tabort\t')" "$HBA_WD_LOG" 2>/dev/null; then
  pass "watchdog.sh --abort: ログに記録される"
else
  fail "watchdog.sh --abort: ログに記録される" "$(cat "$HBA_WD_LOG" 2>&1)"
fi
if grep -q "$(printf '\tabort-clear\t')" "$HBA_WD_LOG" 2>/dev/null; then
  pass "watchdog.sh --abort --clear: ログに記録される"
else
  fail "watchdog.sh --abort --clear: ログに記録される" "$(cat "$HBA_WD_LOG" 2>&1)"
fi

# watchdog.sh --abort: 理由もclearも指定しないとエラー（exit 64）
DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" bash "$HBA_WD_SCRIPT" --abort >/dev/null 2>&1
assert_exit_code "watchdog.sh --abort: 理由未指定はエラー（exit 64）" 64 $?

# ---------------------------------------------------------------------------
# scripts/watchdog.sh（常駐監視の骨格とライフサイクル。Task #45、Epic #42）
#
# run のメインループはサブエージェント実行中に別処理を回せないため、監視は
# nohup で自己デタッチする常駐プロセスとして実装している（Epic #42 仕様書「2. 全体像」
# 「5. デタッチした常駐プロセス」）。ここでは検知ロジック（#47〜#49）ではなく、
# 起動・停止・状態確認・自己終了・二重起動防止・stale PID 検出のライフサイクルだけを
# 検証する。実プロセスを扱うケースは合計10秒以内に収め、終了後にプロセスを残さない。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh（常駐監視の骨格とライフサイクル。Task #45） =="

WD_SCRIPT="${REPO_ROOT}/scripts/watchdog.sh"

# wd_new_root  一時マーカールート（.claude/ 付き）を作って絶対パスを返す
wd_new_root() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-watchdog.XXXXXX")"
  mkdir -p "${dir}/.claude"
  printf '%s' "$dir"
}

# wd_pid_of <root>  PIDファイルに書かれたPID部分だけを返す（無ければ空文字）
wd_pid_of() {
  local root="$1" line=""
  [ -f "${root}/.claude/.dev-workflow-watchdog.pid" ] || return 0
  IFS= read -r line < "${root}/.claude/.dev-workflow-watchdog.pid" || true
  printf '%s' "${line%% *}"
}

# wd_pid_alive <pid>  そのPIDが実際に稼働していれば0を返す
#
# `kill -0` だけではゾンビ（終了済みだが未回収のプロセス）にも成功してしまう
# （POSIXの仕様どおり）。init を持たないこのサンドボックスコンテナでは孤児プロセスが
# 永久にゾンビのまま残ることが実測で判明したため、watchdog.sh の
# _watchdog_pid_alive と同じロジック（/proc の State 行でゾンビを除外する）を
# テスト側でも使う。
wd_pid_alive() {
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

# テストが途中で失敗しても、起動した監視デーモンを必ず後始末する
# （ホストには他の作業が動いているため、無関係なプロセスには触れない。
#   ここで kill するのはこのテストが自分で起動したPIDだけ）
WD_CLEANUP_PIDS=()
wd_cleanup_all() {
  local p
  for p in "${WD_CLEANUP_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    wd_pid_alive "$p" && kill "$p" 2>/dev/null
  done
}
trap wd_cleanup_all EXIT

# --- ライフサイクル: start（即時に返る・生存）→ status（running）→ 二重start（1プロセスのまま）
#     → stop（確実に停止）→ status（stopped・PIDファイル消滅） ---

WD_ROOT1="$(wd_new_root)"
: > "${WD_ROOT1}/.claude/.dev-workflow-run"

WD_T0=""
printf -v WD_T0 '%(%s)T' -1
WD_START_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" DEV_WORKFLOW_WATCHDOG_TICK_SEC=30 \
  bash "$WD_SCRIPT" --start --epic 45 --label "Epic #45 test" 2>&1)"
WD_T1=""
printf -v WD_T1 '%(%s)T' -1
WD_ELAPSED=$((WD_T1 - WD_T0))

if [ "$WD_ELAPSED" -le 1 ]; then
  pass "watchdog.sh --start: 呼び出しが1秒以内に返る（実測 ${WD_ELAPSED}s）"
else
  fail "watchdog.sh --start: 呼び出しが1秒以内に返る" "実測 ${WD_ELAPSED}s / 出力: ${WD_START_OUT}"
fi

WD_PID1="$(wd_pid_of "$WD_ROOT1")"
WD_CLEANUP_PIDS+=("$WD_PID1")

if [ -n "$WD_PID1" ] && wd_pid_alive "$WD_PID1"; then
  pass "watchdog.sh --start: 起動したプロセスが親の呼び出し終了後も生存している（pid=${WD_PID1}）"
else
  fail "watchdog.sh --start: 起動したプロセスが親の呼び出し終了後も生存している" "pid=[${WD_PID1}]"
fi

WD_STATUS_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" bash "$WD_SCRIPT" --status)"
WD_STATUS_EXIT=$?
case "$WD_STATUS_OUT" in
  running*) pass "watchdog.sh --status: running を返す（${WD_STATUS_OUT}）" ;;
  *)        fail "watchdog.sh --status: running を返す" "$WD_STATUS_OUT" ;;
esac
assert_exit_code "watchdog.sh --status: running のときexit 0" 0 "$WD_STATUS_EXIT"

case "$WD_STATUS_OUT" in
  *"pid=${WD_PID1}"*) pass "watchdog.sh --status: PIDファイルのPIDと一致する" ;;
  *)                  fail "watchdog.sh --status: PIDファイルのPIDと一致する" "$WD_STATUS_OUT" ;;
esac

# 二重に --start しても新しいプロセスは作らず、既存PIDのまま（監視プロセスは1つ）
WD_START2_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" bash "$WD_SCRIPT" --start 2>&1)"
WD_PID1_AFTER="$(wd_pid_of "$WD_ROOT1")"
assert_eq "watchdog.sh --start: 二重起動してもPIDが変わらない（監視プロセスは1つ）" \
  "$WD_PID1" "$WD_PID1_AFTER"
case "$WD_START2_OUT" in
  *"already running"*) pass "watchdog.sh --start: 二重起動時にその旨を出力する" ;;
  *)                    fail "watchdog.sh --start: 二重起動時にその旨を出力する" "$WD_START2_OUT" ;;
esac

# --stop で確実に停止する
WD_STOP_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" bash "$WD_SCRIPT" --stop 2>&1)"
case "$WD_STOP_OUT" in
  *"stopped"*) pass "watchdog.sh --stop: 停止メッセージを出す" ;;
  *)           fail "watchdog.sh --stop: 停止メッセージを出す" "$WD_STOP_OUT" ;;
esac

if wd_pid_alive "$WD_PID1"; then
  fail "watchdog.sh --stop: プロセスが実際に終了している" "pid=${WD_PID1} がまだ生存"
else
  pass "watchdog.sh --stop: プロセスが実際に終了している（pid=${WD_PID1}）"
fi

WD_STATUS_AFTER_STOP="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" bash "$WD_SCRIPT" --status)"
WD_STATUS_AFTER_STOP_EXIT=$?
assert_eq "watchdog.sh --status: --stop後はstoppedを返す" "stopped" "$WD_STATUS_AFTER_STOP"
assert_exit_code "watchdog.sh --status: stoppedのときexit 1" 1 "$WD_STATUS_AFTER_STOP_EXIT"

if [ -f "${WD_ROOT1}/.claude/.dev-workflow-watchdog.pid" ]; then
  fail "watchdog.sh --stop: PIDファイルが残っていない（受け入れ条件8）"
else
  pass "watchdog.sh --stop: PIDファイルが残っていない（受け入れ条件8）"
fi

# --- stale PID: プロセスが存在しないPIDファイルが残っていても --start できる ---

WD_ROOT2="$(wd_new_root)"
: > "${WD_ROOT2}/.claude/.dev-workflow-run"

# 確実に生存していないPIDを用意する（起動して即終了させ、waitで回収済みにする）
bash -c 'exit 0' &
WD_DEAD_PID=$!
wait "$WD_DEAD_PID" 2>/dev/null
printf '%s %s\n' "$WD_DEAD_PID" "1700000000" > "${WD_ROOT2}/.claude/.dev-workflow-watchdog.pid"

DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT2" DEV_WORKFLOW_WATCHDOG_TICK_SEC=30 \
  bash "$WD_SCRIPT" --start > /dev/null 2>&1
WD_PID2="$(wd_pid_of "$WD_ROOT2")"
WD_CLEANUP_PIDS+=("$WD_PID2")

if [ -n "$WD_PID2" ] && [ "$WD_PID2" != "$WD_DEAD_PID" ] && wd_pid_alive "$WD_PID2"; then
  pass "watchdog.sh --start: 残骸PIDファイル（存在しないPID）があっても起動できる（新pid=${WD_PID2}）"
else
  fail "watchdog.sh --start: 残骸PIDファイル（存在しないPID）があっても起動できる" "pid=[${WD_PID2}] dead_pid=[${WD_DEAD_PID}]"
fi

if grep -q "stale-pid" "${WD_ROOT2}/.claude/.dev-workflow-watchdog.log" 2>/dev/null; then
  pass "watchdog.sh --start: stale PID検出をログに記録する"
else
  fail "watchdog.sh --start: stale PID検出をログに記録する" "$(cat "${WD_ROOT2}/.claude/.dev-workflow-watchdog.log" 2>&1)"
fi

DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT2" bash "$WD_SCRIPT" --stop > /dev/null 2>&1

# --- --tick-once: 常駐せず1周だけ回してexit 0で返る ---

WD_ROOT3="$(wd_new_root)"

WD_TICK_T0=""
printf -v WD_TICK_T0 '%(%s)T' -1
DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT3" bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WD_TICK_EXIT=$?
WD_TICK_T1=""
printf -v WD_TICK_T1 '%(%s)T' -1

assert_exit_code "watchdog.sh --tick-once: exit 0で返る" 0 "$WD_TICK_EXIT"

if [ $((WD_TICK_T1 - WD_TICK_T0)) -le 2 ]; then
  pass "watchdog.sh --tick-once: 常駐せずすぐに返る"
else
  fail "watchdog.sh --tick-once: 常駐せずすぐに返る" "実測 $((WD_TICK_T1 - WD_TICK_T0))s"
fi

WD_TICK_LOG="${WD_ROOT3}/.claude/.dev-workflow-watchdog.log"
if [ -f "$WD_TICK_LOG" ] && grep -q "$(printf '\ttick\t')" "$WD_TICK_LOG"; then
  pass "watchdog.sh --tick-once: ログにtickイベントが1行追記される"
else
  fail "watchdog.sh --tick-once: ログにtickイベントが1行追記される" "$(cat "$WD_TICK_LOG" 2>&1)"
fi

if [ -f "${WD_ROOT3}/.claude/.dev-workflow-watchdog.pid" ]; then
  fail "watchdog.sh --tick-once: 常駐しない（PIDファイルを作らない）"
else
  pass "watchdog.sh --tick-once: 常駐しない（PIDファイルを作らない）"
fi

# --- DEV_WORKFLOW_WATCHDOG_NOW を与えるとログの時刻がその値になる ---

WD_ROOT4="$(wd_new_root)"
WD_FIXED_NOW=1700000000
WD_EXPECTED_TS=""
printf -v WD_EXPECTED_TS '%(%Y-%m-%d %H:%M:%S)T' "$WD_FIXED_NOW"
DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT4" DEV_WORKFLOW_WATCHDOG_NOW="$WD_FIXED_NOW" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WD_LOGGED_LINE="$(tail -1 "${WD_ROOT4}/.claude/.dev-workflow-watchdog.log" 2>/dev/null)"
WD_LOGGED_TS="${WD_LOGGED_LINE%%$'\t'*}"
assert_eq "watchdog.sh: DEV_WORKFLOW_WATCHDOG_NOW を与えるとログの時刻がその値になる" \
  "$WD_EXPECTED_TS" "$WD_LOGGED_TS"

# --- run マーカーを消すと（短いtick間隔で）自己終了する。受け入れ条件8 ---

WD_ROOT5="$(wd_new_root)"
: > "${WD_ROOT5}/.claude/.dev-workflow-run"

DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT5" DEV_WORKFLOW_WATCHDOG_TICK_SEC=1 \
  bash "$WD_SCRIPT" --start > /dev/null 2>&1
WD_PID5="$(wd_pid_of "$WD_ROOT5")"
WD_CLEANUP_PIDS+=("$WD_PID5")

rm -f "${WD_ROOT5}/.claude/.dev-workflow-run"

WD_SELF_TERM_OK=0
WD_WAIT_I=0
while [ "$WD_WAIT_I" -lt 25 ]; do
  if [ -n "$WD_PID5" ] && ! wd_pid_alive "$WD_PID5"; then
    WD_SELF_TERM_OK=1
    break
  fi
  sleep 0.2
  WD_WAIT_I=$((WD_WAIT_I + 1))
done

if [ "$WD_SELF_TERM_OK" -eq 1 ]; then
  pass "watchdog.sh: run マーカー消失で自己終了する（受け入れ条件8）"
else
  fail "watchdog.sh: run マーカー消失で自己終了する" "pid=${WD_PID5} が終了しなかった"
fi

if [ -f "${WD_ROOT5}/.claude/.dev-workflow-watchdog.pid" ]; then
  fail "watchdog.sh: 自己終了後にPIDファイルが残っていない（受け入れ条件8）"
else
  pass "watchdog.sh: 自己終了後にPIDファイルが残っていない（受け入れ条件8）"
fi

if grep -q "exit-reason" "${WD_ROOT5}/.claude/.dev-workflow-watchdog.log" 2>/dev/null \
  && grep -q "run marker missing" "${WD_ROOT5}/.claude/.dev-workflow-watchdog.log" 2>/dev/null; then
  pass "watchdog.sh: 自己終了の理由がログに記録される"
else
  fail "watchdog.sh: 自己終了の理由がログに記録される" "$(cat "${WD_ROOT5}/.claude/.dev-workflow-watchdog.log" 2>&1)"
fi

# ---------------------------------------------------------------------------
# scripts/watchdog.sh: エージェントを自動で打ち切る経路が存在しない（受け入れ条件6）
#
# 決定事項（Epic #42）: watchdog は検知して通知するだけであり、しきい値超過で
# 自動的にツール呼び出しの拒否やプロセスkillを仕込む経路を持たない。
# ここでは kill の使用箇所が watchdog_stop（人間が --stop を明示的に実行したときだけ
# 通る経路）の1箇所に限られ、対象が監視デーモン自身のPIDであること、tick/検知フック
# （自動発火の起点になり得る箇所）に kill が存在しないことを grep で証明する。
#
# `kill -0`（シグナル0=何も起こさない存在確認クエリ。POSIXの標準的なイディオム）は
# ここでの「kill」から除外する。実際にプロセスを終了させないため、受け入れ条件6が
# 問題にしている「自動打ち切り」には当たらない（_watchdog_pid_alive が
# start/stop/status の生存確認に使っており、tick処理・検知フックからは呼ばれない）。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh: エージェントを自動で打ち切る経路が存在しない（受け入れ条件6） =="

# コメント行を除いた実コード上で「実際に終了させる」kill（kill -0 は除く）が
# 使われている箇所を数える
WD_KILL_LINES="$(grep -v '^[[:space:]]*#' "$WD_SCRIPT" | grep -E '(^|[^A-Za-z0-9_])kill[[:space:]]' | grep -v -- '-0' || true)"
WD_KILL_COUNT="$(printf '%s\n' "$WD_KILL_LINES" | grep -c . || true)"
[ -z "$WD_KILL_LINES" ] && WD_KILL_COUNT=0

assert_eq "watchdog.sh: 終了シグナルとしてのkillは1箇所だけ（--stop のみ・kill -0の存在確認は除く）" "1" "$WD_KILL_COUNT"

case "$WD_KILL_LINES" in
  *'kill "$pid"'*)
    pass "watchdog.sh: kill は監視デーモン自身のPID（\$pid）だけを対象にする" ;;
  *)
    fail "watchdog.sh: kill は監視デーモン自身のPID（\$pid）だけを対象にする" "$WD_KILL_LINES" ;;
esac

# その1箇所が watchdog_stop（--stop の処理）の中に閉じていること
WD_STOP_FN_BODY="$(awk '/^watchdog_stop\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$WD_SCRIPT")"
case "$WD_STOP_FN_BODY" in
  *'kill "$pid"'*)
    pass "watchdog.sh: kill は watchdog_stop（人間が --stop を叩いたときだけ）に閉じている" ;;
  *)
    fail "watchdog.sh: kill は watchdog_stop（人間が --stop を叩いたときだけ）に閉じている" "$WD_STOP_FN_BODY" ;;
esac

# tick処理・検知フック（監視ループが自動的に回す経路）に kill が存在しないこと
WD_HOOK_BLOCK="$(awk '/^# 監視ループのフック点/{f=1} f&&/^# --start$/{exit} f' "$WD_SCRIPT")"
if printf '%s' "$WD_HOOK_BLOCK" | grep -q 'kill'; then
  fail "watchdog.sh: tick処理・検知フック（自動発火経路）にkillが存在しない（受け入れ条件6）" "$WD_HOOK_BLOCK"
else
  pass "watchdog.sh: tick処理・検知フック（自動発火経路）にkillが存在しない（受け入れ条件6）"
fi

# エージェント（Claude Code / Codex のCLIプロセスやサブエージェント）のPIDを扱う
# 変数・識別子が存在しないこと（watchdogは監視デーモン自身のPIDしか知らない）
if grep -qiE 'claude[_-]?pid|codex[_-]?pid|agent[_-]?pid|cli[_-]?pid' "$WD_SCRIPT"; then
  fail "watchdog.sh: エージェント/CLIプロセスのPIDを扱う変数が存在しない（受け入れ条件6）" \
    "$(grep -inE 'claude[_-]?pid|codex[_-]?pid|agent[_-]?pid|cli[_-]?pid' "$WD_SCRIPT")"
else
  pass "watchdog.sh: エージェント/CLIプロセスのPIDを扱う変数が存在しない（受け入れ条件6）"
fi

# --abort（人間が明示的に叩く打ち切り。#50）は実装されているが、tick処理・検知フック
# （監視ループが自動的に回す経路。WD_HOOK_BLOCKは上でkillチェック用に抽出済み）からは
# 一切参照されないこと（自動発火経路がここにも無いことの担保）
if printf '%s' "$WD_HOOK_BLOCK" | grep -q 'dev-workflow-abort\|ABORT_FLAG_FILE'; then
  fail "watchdog.sh: tick処理・検知フック（自動発火経路）に abort フラグの参照が存在しない（受け入れ条件6・#50）" \
    "$WD_HOOK_BLOCK"
else
  pass "watchdog.sh: tick処理・検知フック（自動発火経路）に abort フラグの参照が存在しない（受け入れ条件6・#50）"
fi

# watchdog_abort関数が存在すること（人間が明示的に叩く経路。#50）
WD_ABORT_FN_BODY="$(awk '/^watchdog_abort\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$WD_SCRIPT")"
if [ -z "$WD_ABORT_FN_BODY" ]; then
  fail "watchdog.sh: watchdog_abort関数が存在する（#50）" "見つかりません"
else
  pass "watchdog.sh: watchdog_abort関数が存在する（#50）"
fi

# ABORT_FLAG_FILE（.dev-workflow-abort）を書き込む・削除するコードが、定義行・コメント行
# を除いて watchdog_abort 関数の外に存在しないこと。これにより「自動でabortフラグを作る
# 経路が存在しない」ことを、tick/検知フックだけでなくスクリプト全体で担保する。
WD_ABORT_REF_LINES="$(grep -n 'ABORT_FLAG_FILE' "$WD_SCRIPT" \
  | grep -vE '^[0-9]+:ABORT_FLAG_FILE=' \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
WD_ABORT_REF_OUTSIDE=""
while IFS=: read -r wd_lno wd_rest; do
  [ -n "$wd_lno" ] || continue
  printf '%s\n' "$WD_ABORT_FN_BODY" | grep -qF -- "$wd_rest" \
    || WD_ABORT_REF_OUTSIDE="${WD_ABORT_REF_OUTSIDE}${wd_lno}:${wd_rest}"$'\n'
done <<< "$WD_ABORT_REF_LINES"
if [ -n "$WD_ABORT_REF_OUTSIDE" ]; then
  fail "watchdog.sh: ABORT_FLAG_FILEを扱うコードはwatchdog_abort関数の内側だけにある（自動発火経路が無いことの担保・#50）" \
    "$WD_ABORT_REF_OUTSIDE"
else
  pass "watchdog.sh: ABORT_FLAG_FILEを扱うコードはwatchdog_abort関数の内側だけにある（自動発火経路が無いことの担保・#50）"
fi

# AUTO_ABORT等、自動発火用の環境変数・分岐が存在しないこと（#50: 環境変数による自動abortも設けない）
if grep -qiE 'auto[_-]?abort' "$WD_SCRIPT"; then
  fail "watchdog.sh: 自動発火用の環境変数・分岐（AUTO_ABORT等）が存在しない（#50）" \
    "$(grep -inE 'auto[_-]?abort' "$WD_SCRIPT")"
else
  pass "watchdog.sh: 自動発火用の環境変数・分岐（AUTO_ABORT等）が存在しない（#50）"
fi

# --- テスト後始末: 生き残っているデーモンがあれば停止する ---
wd_cleanup_all
trap - EXIT

# ---------------------------------------------------------------------------
# scripts/watchdog.sh: ストール判定・エスカレーション・スリープギャップ補正（Task #47、Epic #42）
#
# DEV_WORKFLOW_WATCHDOG_NOW で時刻を注入し --tick-once を連続で叩くことで、実時間を
# 一切待たずに「未検知→初回→エスカレーション→打ち止め→復帰→再ストール」の遷移を検証する。
# 通知は notify-slack.sh の DEV_WORKFLOW_NOTIFY_SINK 経由で検証し、ネットワークには
# 一切出ない（既存の notify-slack.sh テストと同じsink機構。PATHへ偽curlを差し込み、
# 万一sink機構をバイパスしても実curlが呼ばれないことも確認する）。
#
# tick_sec は意図的に大きく（3600秒）取り、テストで注入する時刻ジャンプ（最大でも
# 数千秒）がスリープギャップ（tick間隔の3倍超）として誤検知されないようにしている
# （スリープギャップそのものの検証は専用のケース群で tick_sec=60 を使って別途行う）。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh: ストール判定・エスカレーション・スリープギャップ補正（Task #47） =="

WDS_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-watchdog-stall.XXXXXX")"
WDS_FAKE_BIN="${WDS_WORK}/bin"
mkdir -p "$WDS_FAKE_BIN"
WDS_CURL_LOG="${WDS_WORK}/curl-calls.log"
printf '#!/bin/bash\necho "called: $*" >> "%s"\nexit 0\n' "$WDS_CURL_LOG" > "${WDS_FAKE_BIN}/curl"
chmod +x "${WDS_FAKE_BIN}/curl"

# wds_write_heartbeat <root> <epoch> <state> <tool>
wds_write_heartbeat() {
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "${1}/.claude/.dev-workflow-heartbeat"
}

# wds_tick <root> <now> <tick_sec> [sink_file]
# --tick-once を1回叩く。SLACK_WEBHOOK_URL は常にダミーを設定し、sink未指定時は
# 使い捨てのsinkへ書かせる（そのtickで通知が発火したかどうかをsinkファイルの
# 有無だけで判定するため、ケースごとに新しいsinkパスを渡す）。
wds_tick() {
  local root="$1" now="$2" tick_sec="$3" sink="${4:-${WDS_WORK}/unused-sink.json}"
  DEV_WORKFLOW_MARKER_ROOT="$root" \
  DEV_WORKFLOW_WATCHDOG_NOW="$now" \
  DEV_WORKFLOW_WATCHDOG_TICK_SEC="$tick_sec" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$sink" \
  DEV_WORKFLOW_NO_SLEEP_INHIBIT=1 \
  PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once --epic 47 --label "Epic #47 test" > /dev/null 2>&1
}

wds_read_sink() {
  [ -f "$1" ] && cat "$1" || printf ''
}

# --- ストール検知・エスカレーション・打ち止め・復帰（既定値 idle=900秒・escalate=1800秒） ---

WDS_ROOT1="$(wd_new_root)"
WDS_T0=1700000000
wds_write_heartbeat "$WDS_ROOT1" "$WDS_T0" "post" "Bash"
WDS_LOG1="${WDS_ROOT1}/.claude/.dev-workflow-watchdog.log"

# 初回tick: 基準時刻を記録するだけ（通知は起きない）
wds_tick "$WDS_ROOT1" "$WDS_T0" 3600
if grep -q "$(printf '\tstall\t')" "$WDS_LOG1" 2>/dev/null; then
  fail "watchdog.sh: 初回tickでは通知しない（基準時刻の記録のみ）" "$(cat "$WDS_LOG1" 2>&1)"
else
  pass "watchdog.sh: 初回tickでは通知しない（基準時刻の記録のみ）"
fi

# 無活動14分: 通知されない
WDS_SINK_14M="${WDS_WORK}/14m.json"
wds_tick "$WDS_ROOT1" "$((WDS_T0 + 14 * 60))" 3600 "$WDS_SINK_14M"
if [ -f "$WDS_SINK_14M" ]; then
  fail "watchdog.sh: 無活動14分では通知されない" "$(wds_read_sink "$WDS_SINK_14M")"
else
  pass "watchdog.sh: 無活動14分では通知されない"
fi

# 無活動16分: 初回通知される（state=post → モデルの応答待ちで停止）
WDS_NOTIFY1_AT=$((WDS_T0 + 16 * 60))
WDS_SINK_16M="${WDS_WORK}/16m.json"
wds_tick "$WDS_ROOT1" "$WDS_NOTIFY1_AT" 3600 "$WDS_SINK_16M"
WDS_BODY_16M="$(wds_read_sink "$WDS_SINK_16M")"
case "$WDS_BODY_16M" in
  *"応答なし"*) pass "watchdog.sh: 無活動16分で初回通知される" ;;
  *)            fail "watchdog.sh: 無活動16分で初回通知される" "$WDS_BODY_16M" ;;
esac
case "$WDS_BODY_16M" in
  *"モデルの応答待ちで停止"*)
    pass "watchdog.sh: state=postの通知本文に «モデルの応答待ちで停止» を含む（受け入れ条件2）" ;;
  *)
    fail "watchdog.sh: state=postの通知本文に «モデルの応答待ちで停止» を含む" "$WDS_BODY_16M" ;;
esac
case "$WDS_BODY_16M" in
  *"ツール実行中に停止"*)
    fail "watchdog.sh: state=postの通知本文に «ツール実行中に停止» を誤って含まない" "$WDS_BODY_16M" ;;
  *)
    pass "watchdog.sh: state=postの通知本文に «ツール実行中に停止» を誤って含まない" ;;
esac
case "$WDS_BODY_16M" in
  *"Epic #47"*) pass "watchdog.sh: 通知本文にEpic番号（--tick-onceで受け取ったもの）を含む" ;;
  *)            fail "watchdog.sh: 通知本文にEpic番号を含む" "$WDS_BODY_16M" ;;
esac
case "$WDS_BODY_16M" in
  *0h16m*) pass "watchdog.sh: 通知本文に無活動の継続時間（Nh Mm形式）を含む" ;;
  *)       fail "watchdog.sh: 通知本文に無活動の継続時間（Nh Mm形式）を含む" "$WDS_BODY_16M" ;;
esac

# 初回通知の29分後: 再通知されない
WDS_SINK_29M="${WDS_WORK}/29m.json"
wds_tick "$WDS_ROOT1" "$((WDS_NOTIFY1_AT + 29 * 60))" 3600 "$WDS_SINK_29M"
if [ -f "$WDS_SINK_29M" ]; then
  fail "watchdog.sh: 初回通知後29分では再通知されない" "$(wds_read_sink "$WDS_SINK_29M")"
else
  pass "watchdog.sh: 初回通知後29分では再通知されない"
fi

# 初回通知の30分後: 2回目が通知される
WDS_NOTIFY2_AT=$((WDS_NOTIFY1_AT + 30 * 60))
WDS_SINK_30M="${WDS_WORK}/30m.json"
wds_tick "$WDS_ROOT1" "$WDS_NOTIFY2_AT" 3600 "$WDS_SINK_30M"
if [ -f "$WDS_SINK_30M" ]; then
  pass "watchdog.sh: 初回通知後30分経過で2回目が通知される"
else
  fail "watchdog.sh: 初回通知後30分経過で2回目が通知される" "sinkが作られなかった"
fi

# 2回目通知の30分後: 3回目が通知される
WDS_NOTIFY3_AT=$((WDS_NOTIFY2_AT + 30 * 60))
WDS_SINK_3RD="${WDS_WORK}/3rd.json"
wds_tick "$WDS_ROOT1" "$WDS_NOTIFY3_AT" 3600 "$WDS_SINK_3RD"
if [ -f "$WDS_SINK_3RD" ]; then
  pass "watchdog.sh: 3回目の通知がされる"
else
  fail "watchdog.sh: 3回目の通知がされる" "sinkが作られなかった"
fi

# 3回目通知の30分後（本来なら4回目のタイミング）: 最大3回で打ち止め、通知されない
WDS_AFTER_3RD=$((WDS_NOTIFY3_AT + 30 * 60))
WDS_SINK_4TH="${WDS_WORK}/4th.json"
wds_tick "$WDS_ROOT1" "$WDS_AFTER_3RD" 3600 "$WDS_SINK_4TH"
if [ -f "$WDS_SINK_4TH" ]; then
  fail "watchdog.sh: 3回通知した後は再通知されない（最大3回で打ち止め）" "$(wds_read_sink "$WDS_SINK_4TH")"
else
  pass "watchdog.sh: 3回通知した後は再通知されない（最大3回で打ち止め）"
fi

# さらに先の時刻でtickしても通知されない（打ち止めが続くことの確認）
WDS_SINK_FAR="${WDS_WORK}/far.json"
wds_tick "$WDS_ROOT1" "$((WDS_AFTER_3RD + 3000))" 3600 "$WDS_SINK_FAR"
if [ -f "$WDS_SINK_FAR" ]; then
  fail "watchdog.sh: 3回打ち止め後はどれだけtickしても通知されない" "$(wds_read_sink "$WDS_SINK_FAR")"
else
  pass "watchdog.sh: 3回打ち止め後はどれだけtickしても通知されない"
fi

WDS_STALL_COUNT_LOG="$(grep -c "$(printf '\tstall\t')" "$WDS_LOG1" 2>/dev/null || true)"
assert_eq "watchdog.sh: ログに記録されたstall通知は3件（打ち止めの上限どおり）" "3" "${WDS_STALL_COUNT_LOG:-0}"

if [ -f "${WDS_ROOT1}/.claude/.dev-workflow-abort" ]; then
  fail "watchdog.sh: ストールを3回検知しても .dev-workflow-abort が作られない（自動打ち切りをしない）"
else
  pass "watchdog.sh: ストールを3回検知しても .dev-workflow-abort が作られない（自動打ち切りをしない）"
fi

# --- heartbeat更新による復帰: stall-recoveredが1回だけ通知され、カウンタがリセットされる ---

WDS_RECOVER_AT=$((WDS_AFTER_3RD + 3000 + 10))
wds_write_heartbeat "$WDS_ROOT1" "$WDS_RECOVER_AT" "pre" "Read"

WDS_SINK_RECOVER="${WDS_WORK}/recovered.json"
wds_tick "$WDS_ROOT1" "$WDS_RECOVER_AT" 3600 "$WDS_SINK_RECOVER"
WDS_BODY_RECOVER="$(wds_read_sink "$WDS_SINK_RECOVER")"
case "$WDS_BODY_RECOVER" in
  *"応答が再開"*) pass "watchdog.sh: heartbeat更新でstall-recoveredが通知される" ;;
  *)              fail "watchdog.sh: heartbeat更新でstall-recoveredが通知される" "$WDS_BODY_RECOVER" ;;
esac

WDS_RECOVERED_COUNT_LOG="$(grep -c "$(printf '\tstall-recovered\t')" "$WDS_LOG1" 2>/dev/null || true)"
assert_eq "watchdog.sh: stall-recovered通知は1回だけ記録される" "1" "${WDS_RECOVERED_COUNT_LOG:-0}"

# 復帰直後（heartbeatが変わらない間）に再tickしても、stall-recoveredは再通知されない
WDS_SINK_RECOVER_AGAIN="${WDS_WORK}/recovered-again.json"
wds_tick "$WDS_ROOT1" "$((WDS_RECOVER_AT + 60))" 3600 "$WDS_SINK_RECOVER_AGAIN"
if [ -f "$WDS_SINK_RECOVER_AGAIN" ]; then
  fail "watchdog.sh: 復帰後、heartbeatが変わらない間はstall-recoveredが再通知されない" \
    "$(wds_read_sink "$WDS_SINK_RECOVER_AGAIN")"
else
  pass "watchdog.sh: 復帰後、heartbeatが変わらない間はstall-recoveredが再通知されない"
fi

# 復帰後に再びストールすると、通知カウンタがリセットされ初回から数え直す
# （4600秒超まで待たず、復帰後わずか16分の無活動で初回通知が来ることを確認する）
WDS_SINK_RESTALL="${WDS_WORK}/restall.json"
wds_tick "$WDS_ROOT1" "$((WDS_RECOVER_AT + 16 * 60))" 3600 "$WDS_SINK_RESTALL"
if [ -f "$WDS_SINK_RESTALL" ]; then
  pass "watchdog.sh: 復帰後に再びストールすると初回から数え直して通知される（16分で初回）"
else
  fail "watchdog.sh: 復帰後に再びストールすると初回から数え直して通知される" "sinkが作られなかった"
fi

WDS_STALL_COUNT_LOG2="$(grep -c "$(printf '\tstall\t')" "$WDS_LOG1" 2>/dev/null || true)"
assert_eq "watchdog.sh: 復帰後の再ストールでstall通知が合計4件になる（打ち止め3件＋復帰後1件）" \
  "4" "${WDS_STALL_COUNT_LOG2:-0}"

# --- state=pre: 通知本文が «ツール実行中に停止» になる（受け入れ条件2） ---

WDS_ROOT2="$(wd_new_root)"
WDS_T0_PRE=1700100000
wds_write_heartbeat "$WDS_ROOT2" "$WDS_T0_PRE" "pre" "Bash"
wds_tick "$WDS_ROOT2" "$WDS_T0_PRE" 3600
WDS_SINK_PRE="${WDS_WORK}/pre.json"
wds_tick "$WDS_ROOT2" "$((WDS_T0_PRE + 16 * 60))" 3600 "$WDS_SINK_PRE"
WDS_BODY_PRE="$(wds_read_sink "$WDS_SINK_PRE")"
case "$WDS_BODY_PRE" in
  *"ツール実行中に停止"*)
    pass "watchdog.sh: state=preの通知本文に «ツール実行中に停止» を含む（受け入れ条件2）" ;;
  *)
    fail "watchdog.sh: state=preの通知本文に «ツール実行中に停止» を含む" "$WDS_BODY_PRE" ;;
esac
case "$WDS_BODY_PRE" in
  *"モデルの応答待ちで停止"*)
    fail "watchdog.sh: state=preの通知本文に «モデルの応答待ちで停止» を誤って含まない" "$WDS_BODY_PRE" ;;
  *)
    pass "watchdog.sh: state=preの通知本文に «モデルの応答待ちで停止» を誤って含まない" ;;
esac

# --- heartbeatファイルが無い場合はストール判定を行わない（run開始直後の誤報防止） ---

WDS_ROOT3="$(wd_new_root)"
WDS_TICK3_OK=1
DEV_WORKFLOW_MARKER_ROOT="$WDS_ROOT3" DEV_WORKFLOW_WATCHDOG_NOW=1700200000 \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1 || WDS_TICK3_OK=0
assert_eq "watchdog.sh: heartbeatが無くてもtick-onceはexit 0で返る" "1" "$WDS_TICK3_OK"

WDS_LOG3="${WDS_ROOT3}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tstall\t')" "$WDS_LOG3" 2>/dev/null; then
  fail "watchdog.sh: heartbeatファイルが無い場合はストール判定を行わない" "$(cat "$WDS_LOG3" 2>&1)"
else
  pass "watchdog.sh: heartbeatファイルが無い場合はストール判定を行わない"
fi

# --- スリープギャップ: 実経過がtick間隔の3倍を超えたら記録・通知され、無活動時間から差し引かれる ---

WDS_ROOT4="$(wd_new_root)"
WDS_T0_GAP=1700300000
wds_write_heartbeat "$WDS_ROOT4" "$WDS_T0_GAP" "post" "Bash"
WDS_LOG4="${WDS_ROOT4}/.claude/.dev-workflow-watchdog.log"

# 初回tick（前回tickの記録が無いので判定なし）+ 通常のtick間隔（60秒に対し実経過50秒）
wds_tick "$WDS_ROOT4" "$WDS_T0_GAP" 60
wds_tick "$WDS_ROOT4" "$((WDS_T0_GAP + 50))" 60
if grep -q "$(printf '\tsleep-gap\t')" "$WDS_LOG4" 2>/dev/null; then
  fail "watchdog.sh: 通常のtick間隔ではsleep-gapを検知しない" "$(cat "$WDS_LOG4" 2>&1)"
else
  pass "watchdog.sh: 通常のtick間隔ではsleep-gapを検知しない"
fi

# 大きくジャンプ（tick間隔60秒に対し実経過3700秒 > 60*3）→ スリープと判定
WDS_GAP_NOW=$((WDS_T0_GAP + 50 + 3700))
WDS_SINK_GAP="${WDS_WORK}/sleep-gap.json"
wds_tick "$WDS_ROOT4" "$WDS_GAP_NOW" 60 "$WDS_SINK_GAP"
WDS_BODY_GAP="$(wds_read_sink "$WDS_SINK_GAP")"
case "$WDS_BODY_GAP" in
  *"スリープ痕跡"*) pass "watchdog.sh: tick間隔の3倍を超える実経過でsleep-gapが通知される" ;;
  *)                fail "watchdog.sh: tick間隔の3倍を超える実経過でsleep-gapが通知される" "$WDS_BODY_GAP" ;;
esac
case "$WDS_BODY_GAP" in
  *"応答なし"*)
    fail "watchdog.sh: sleep-gap通知にstallの見出し «応答なし» が誤って混ざらない" "$WDS_BODY_GAP" ;;
  *)
    pass "watchdog.sh: sleep-gap通知にstallの見出し «応答なし» が誤って混ざらない" ;;
esac

if grep -q "$(printf '\tsleep-gap\t')" "$WDS_LOG4" 2>/dev/null; then
  pass "watchdog.sh: sleep-gapイベントがログに記録される（差し引き累計を含め後から読める）"
else
  fail "watchdog.sh: sleep-gapイベントがログに記録される" "$(cat "$WDS_LOG4" 2>&1)"
fi

# スリープギャップ直後: 差し引きが効いて誤ってstallとして通知されない
# （素の経過なら now - heartbeat_epoch = 3750秒 > 900秒でストール誤報になるはずだが、
#   ギャップ分3640秒（実経過3700秒からtick_sec 60秒を引いた分）を差し引いた110秒は
#   900秒未満なので通知されない）
if grep -q "$(printf '\tstall\t')" "$WDS_LOG4" 2>/dev/null; then
  fail "watchdog.sh: スリープギャップ直後のtickでストール誤報が出ない（差し引きが効いている）" \
    "$(cat "$WDS_LOG4" 2>&1)"
else
  pass "watchdog.sh: スリープギャップ直後のtickでストール誤報が出ない（差し引きが効いている）"
fi

# --- curlが一度も実行されていないこと（通知はsink経由でのみ検証し、ネットワークに出ない） ---
if [ -s "$WDS_CURL_LOG" ]; then
  fail "watchdog.sh: 通知でsink使用時にcurlが呼ばれない（実送信しない）" "$(wds_read_sink "$WDS_CURL_LOG")"
else
  pass "watchdog.sh: 通知でsink使用時にcurlが呼ばれない（実送信しない）"
fi

# ---------------------------------------------------------------------------
# scripts/watchdog.sh: ウェーブ予算の監視と `- 想定時間:` 宣言（Task #48、Epic #42）
#
# DEV_WORKFLOW_WATCHDOG_NOW で時刻を注入し --wave / --tick-once を組み合わせて、実時間を
# 一切待たずに「run-state書き込み → 予算内は無通知 → 超過で1回だけ通知 → 次のwaveでリセット」
# を検証する。`- 想定時間:` の解析は、実際の `gh issue view` を呼ばず、PATHに差し込んだ
# 偽ghスクリプト（環境変数で指定したディレクトリのファイルを本文として返すだけ）を使い、
# ネットワーク・GitHub 認証に一切依存しない（完了条件: 「gh に依存しないよう、issue本文の
# 入力を差し替えられるようにする」）。通知はTask #47と同じくnotify-slack.shのsink機構で検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh: ウェーブ予算の監視と - 想定時間: 宣言（Task #48） =="

WB_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-watchdog-budget.XXXXXX")"

# --- --wave: run-stateを期待どおりの形式で書く ---

WB_ROOT1="$(wd_new_root)"
WB_T0=1700400000
DEV_WORKFLOW_MARKER_ROOT="$WB_ROOT1" DEV_WORKFLOW_WATCHDOG_NOW="$WB_T0" \
  bash "$WD_SCRIPT" --wave --epic 48 --wave-no 2 --tasks "44,45,46" --budget-sec 5000 \
  > /dev/null 2>&1
WB_STATE_FILE1="${WB_ROOT1}/.claude/.dev-workflow-run-state"
WB_EXPECTED1=$'epic=48\nwave=2\ntasks=44,45,46\nwave_started=1700400000\nbudget_sec=5000'
WB_ACTUAL1="$(cat "$WB_STATE_FILE1" 2>/dev/null)"
assert_eq "watchdog.sh --wave: run-stateを期待どおりの形式(key=value)で書く" \
  "$WB_EXPECTED1" "$WB_ACTUAL1"

# --- 予算監視: 予算内は無通知・超過で1回だけ通知される・次の --wave でリセットされる ---

WB_ROOT2="$(wd_new_root)"
WB_LOG2="${WB_ROOT2}/.claude/.dev-workflow-watchdog.log"

# wb_tick <root> <now> <tick_sec> [sink_file]  （wds_tickと同じ作法。偽curlはWDS_FAKE_BINを再利用する）
wb_tick() {
  local root="$1" now="$2" tick_sec="$3" sink="${4:-${WB_WORK}/unused-sink.json}"
  DEV_WORKFLOW_MARKER_ROOT="$root" \
  DEV_WORKFLOW_WATCHDOG_NOW="$now" \
  DEV_WORKFLOW_WATCHDOG_TICK_SEC="$tick_sec" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$sink" \
  DEV_WORKFLOW_NO_SLEEP_INHIBIT=1 \
  PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once --epic 48 --label "Epic #48 test" > /dev/null 2>&1
}

WB_T0_BUDGET=1700500000
WB_BUDGET=3600
DEV_WORKFLOW_MARKER_ROOT="$WB_ROOT2" DEV_WORKFLOW_WATCHDOG_NOW="$WB_T0_BUDGET" \
  bash "$WD_SCRIPT" --wave --epic 48 --wave-no 1 --tasks "44" --budget-sec "$WB_BUDGET" \
  > /dev/null 2>&1

# 予算内（30分 < 60分）: 無通知
WB_SINK_WITHIN="${WB_WORK}/within-budget.json"
wb_tick "$WB_ROOT2" "$((WB_T0_BUDGET + 1800))" 3600 "$WB_SINK_WITHIN"
if [ -f "$WB_SINK_WITHIN" ]; then
  fail "watchdog.sh: ウェーブ予算内では通知されない" "$(wds_read_sink "$WB_SINK_WITHIN")"
else
  pass "watchdog.sh: ウェーブ予算内では通知されない"
fi

# 予算超過（61分 > 60分）: 1回通知される
WB_OVER_AT=$((WB_T0_BUDGET + 3700))
WB_SINK_OVER="${WB_WORK}/over-budget.json"
wb_tick "$WB_ROOT2" "$WB_OVER_AT" 3600 "$WB_SINK_OVER"
WB_BODY_OVER="$(wds_read_sink "$WB_SINK_OVER")"
case "$WB_BODY_OVER" in
  *"想定時間超過"*) pass "watchdog.sh: ウェーブ予算超過で通知される" ;;
  *)                fail "watchdog.sh: ウェーブ予算超過で通知される" "$WB_BODY_OVER" ;;
esac
case "$WB_BODY_OVER" in
  *"ウェーブ1"*) pass "watchdog.sh: 予算超過の通知本文にウェーブ番号を含む" ;;
  *)             fail "watchdog.sh: 予算超過の通知本文にウェーブ番号を含む" "$WB_BODY_OVER" ;;
esac

# 超過後さらにtickしても再通知されない（1回だけ）
WB_SINK_OVER_AGAIN="${WB_WORK}/over-budget-again.json"
wb_tick "$WB_ROOT2" "$((WB_OVER_AT + 100))" 3600 "$WB_SINK_OVER_AGAIN"
if [ -f "$WB_SINK_OVER_AGAIN" ]; then
  fail "watchdog.sh: ウェーブ予算超過の通知は1回だけ（再通知されない）" \
    "$(wds_read_sink "$WB_SINK_OVER_AGAIN")"
else
  pass "watchdog.sh: ウェーブ予算超過の通知は1回だけ（再通知されない）"
fi

WB_BUDGET_LOG_COUNT1="$(grep -c "$(printf '\tbudget\t')" "$WB_LOG2" 2>/dev/null || true)"
assert_eq "watchdog.sh: 予算超過ログはウェーブ1で1件" "1" "${WB_BUDGET_LOG_COUNT1:-0}"

# 次の --wave の後に再び超過すると、また1回通知される（通知済みフラグがリセットされる）
WB_T1=$((WB_OVER_AT + 200))
DEV_WORKFLOW_MARKER_ROOT="$WB_ROOT2" DEV_WORKFLOW_WATCHDOG_NOW="$WB_T1" \
  bash "$WD_SCRIPT" --wave --epic 48 --wave-no 2 --tasks "44" --budget-sec 1800 > /dev/null 2>&1

WB_SINK_WAVE2_WITHIN="${WB_WORK}/wave2-within.json"
wb_tick "$WB_ROOT2" "$((WB_T1 + 100))" 3600 "$WB_SINK_WAVE2_WITHIN"
if [ -f "$WB_SINK_WAVE2_WITHIN" ]; then
  fail "watchdog.sh: 新しいウェーブの予算内では通知されない" "$(wds_read_sink "$WB_SINK_WAVE2_WITHIN")"
else
  pass "watchdog.sh: 新しいウェーブの予算内では通知されない"
fi

WB_WAVE2_OVER_AT=$((WB_T1 + 1900))
WB_SINK_WAVE2_OVER="${WB_WORK}/wave2-over.json"
wb_tick "$WB_ROOT2" "$WB_WAVE2_OVER_AT" 3600 "$WB_SINK_WAVE2_OVER"
WB_BODY_WAVE2_OVER="$(wds_read_sink "$WB_SINK_WAVE2_OVER")"
case "$WB_BODY_WAVE2_OVER" in
  *"想定時間超過"*"ウェーブ2"*)
    pass "watchdog.sh: 次の--waveの後に再び超過すると、また1回通知される" ;;
  *)
    fail "watchdog.sh: 次の--waveの後に再び超過すると、また1回通知される" "$WB_BODY_WAVE2_OVER" ;;
esac

WB_BUDGET_LOG_COUNT2="$(grep -c "$(printf '\tbudget\t')" "$WB_LOG2" 2>/dev/null || true)"
assert_eq "watchdog.sh: 予算超過ログは合計2件（ウェーブ1で1件・ウェーブ2で1件）" \
  "2" "${WB_BUDGET_LOG_COUNT2:-0}"

# --- run-stateが無い場合: 予算監視をスキップし、他の監視（ストール検知）は動き続ける ---

WB_ROOT3="$(wd_new_root)"
WB_T0_NOSTATE=1700600000
wds_write_heartbeat "$WB_ROOT3" "$WB_T0_NOSTATE" "post" "Bash"

WB_TICK3_OK=1
wb_tick "$WB_ROOT3" "$WB_T0_NOSTATE" 3600 || WB_TICK3_OK=0
assert_eq "watchdog.sh: run-stateが無くてもtick-onceはexit 0で返る" "1" "$WB_TICK3_OK"

WB_SINK_STALL_NOSTATE="${WB_WORK}/stall-no-run-state.json"
wb_tick "$WB_ROOT3" "$((WB_T0_NOSTATE + 16 * 60))" 3600 "$WB_SINK_STALL_NOSTATE"
WB_BODY_STALL_NOSTATE="$(wds_read_sink "$WB_SINK_STALL_NOSTATE")"
case "$WB_BODY_STALL_NOSTATE" in
  *"応答なし"*) pass "watchdog.sh: run-stateが無くてもストール監視は動き続ける" ;;
  *)            fail "watchdog.sh: run-stateが無くてもストール監視は動き続ける" "$WB_BODY_STALL_NOSTATE" ;;
esac

WB_LOG3="${WB_ROOT3}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tbudget\t')" "$WB_LOG3" 2>/dev/null; then
  fail "watchdog.sh: run-stateが無い場合に予算監視をスキップする" "$(cat "$WB_LOG3" 2>&1)"
else
  pass "watchdog.sh: run-stateが無い場合に予算監視をスキップする"
fi

# --- `- 想定時間:` の解析: 30m / 2h / 90 / 不正値 / 宣言なし / 複数タスクの最大値 ---
#
# gh には一切依存しない。PATHに差し込む偽ghは `gh issue view <番号> --json body -q .body`
# だけを模倣し、WB_GH_BODY_DIR/<番号>.txt の中身をそのまま本文として返す（無ければ失敗する）。

WB_GH_BODY_DIR="${WB_WORK}/gh-bodies"
mkdir -p "$WB_GH_BODY_DIR"
WB_FAKE_GH_BIN="${WB_WORK}/gh-bin"
mkdir -p "$WB_FAKE_GH_BIN"
cat > "${WB_FAKE_GH_BIN}/gh" <<'FAKE_GH_EOF'
#!/bin/bash
# テスト用の偽gh。`gh issue view <番号> --json body -q .body` だけを模倣する。
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  num="$3"
  file="${WB_GH_BODY_DIR}/${num}.txt"
  if [ -f "$file" ]; then
    cat "$file"
    exit 0
  fi
  exit 1
fi
exit 1
FAKE_GH_EOF
chmod +x "${WB_FAKE_GH_BIN}/gh"

# wb_set_gh_body <issue番号> <本文>
wb_set_gh_body() {
  printf '%s\n' "$2" > "${WB_GH_BODY_DIR}/$1.txt"
}

# wb_wave_budget_sec <root> <tasks_csv>
# --budget-sec なしで --wave を呼び、書かれたrun-stateのbudget_secを返す
wb_wave_budget_sec() {
  local root="$1" tasks="$2"
  DEV_WORKFLOW_MARKER_ROOT="$root" DEV_WORKFLOW_WATCHDOG_NOW=1700700000 \
  WB_GH_BODY_DIR="$WB_GH_BODY_DIR" PATH="${WB_FAKE_GH_BIN}:${PATH}" \
    bash "$WD_SCRIPT" --wave --epic 48 --wave-no 1 --tasks "$tasks" > /dev/null 2>&1
  grep '^budget_sec=' "${root}/.claude/.dev-workflow-run-state" | cut -d= -f2
}

WB_ROOT_EST="$(wd_new_root)"

wb_set_gh_body 201 '- 想定時間: 30m'
assert_eq "watchdog.sh: - 想定時間: 30m → 予算=(30分*2+900秒)=4500秒" \
  "4500" "$(wb_wave_budget_sec "$WB_ROOT_EST" "201")"

wb_set_gh_body 202 '- 想定時間: 2h'
assert_eq "watchdog.sh: - 想定時間: 2h → 予算=(120分*2+900秒)=15300秒" \
  "15300" "$(wb_wave_budget_sec "$WB_ROOT_EST" "202")"

wb_set_gh_body 203 '- 想定時間: 90'
assert_eq "watchdog.sh: - 想定時間: 90（単位なし=分）→ 予算=(90分*2+900秒)=11700秒" \
  "11700" "$(wb_wave_budget_sec "$WB_ROOT_EST" "203")"

wb_set_gh_body 204 '- 想定時間: abc'
assert_eq "watchdog.sh: - 想定時間: 不正値は無視され既定5400秒になる" \
  "5400" "$(wb_wave_budget_sec "$WB_ROOT_EST" "204")"

# タスク205は本文ファイルを作らない（宣言なし）
assert_eq "watchdog.sh: - 想定時間: 宣言が無いタスクは既定5400秒になる" \
  "5400" "$(wb_wave_budget_sec "$WB_ROOT_EST" "205")"

wb_set_gh_body 206 '- 想定時間: 30m'
wb_set_gh_body 207 '- 想定時間: 2h'
assert_eq "watchdog.sh: 複数タスクの - 想定時間: は最大値を使う（2hが優先）→ 15300秒" \
  "15300" "$(wb_wave_budget_sec "$WB_ROOT_EST" "206,207")"

# ghが使えない場合（常に失敗する偽gh）も既定5400秒になる
WB_FAKE_GH_FAIL_BIN="${WB_WORK}/gh-fail-bin"
mkdir -p "$WB_FAKE_GH_FAIL_BIN"
printf '#!/bin/bash\nexit 1\n' > "${WB_FAKE_GH_FAIL_BIN}/gh"
chmod +x "${WB_FAKE_GH_FAIL_BIN}/gh"
WB_ROOT_NOGH="$(wd_new_root)"
DEV_WORKFLOW_MARKER_ROOT="$WB_ROOT_NOGH" DEV_WORKFLOW_WATCHDOG_NOW=1700700000 \
  PATH="${WB_FAKE_GH_FAIL_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --wave --epic 48 --wave-no 1 --tasks "999" > /dev/null 2>&1
WB_BUDGET_NOGH="$(grep '^budget_sec=' "${WB_ROOT_NOGH}/.claude/.dev-workflow-run-state" \
  | cut -d= -f2)"
assert_eq "watchdog.sh --wave: ghが使えない場合は既定5400秒になる" "5400" "$WB_BUDGET_NOGH"

# ---------------------------------------------------------------------------
# scripts/watchdog.sh: スリープ抑止（Task #49、Epic #42）
#
# このサンドボックス（Alpine）には powershell / caffeinate / systemd-inhibit のいずれも
# 存在しないため、OS判定は DEV_WORKFLOW_WATCHDOG_OS で注入し、実行はしない
# （DEV_WORKFLOW_INHIBIT_SINK に組み立てたコマンド文字列だけを書かせて検証する。
# 既存の notify-slack.sh sink・PATH注入の偽コマンド方式に倣う）。
# 「抑止コマンドが失敗する状況」は、Alpineに実在しないpowershellを注入無しでそのまま
# windowsとして実行させることで自然に再現する（フェイクを追加で用意する必要が無い）。
# Windowsの実際の呼び出し成否は、powershellが存在するWindows実機上で --tick-once を
# 直接叩いて別途確認する（テストでは検証しない。issueへ実出力を記録する）。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh: スリープ抑止（Task #49） =="

WI_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-watchdog-inhibit.XXXXXX")"

# --- windows: SetThreadExecutionState を含むコマンドが組み立てられる ---

WI_ROOT_WIN="$(wd_new_root)"
WI_SINK_WIN="${WI_WORK}/windows.cmd"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_WIN" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=windows DEV_WORKFLOW_WATCHDOG_TICK_SEC=60 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_WIN" PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_WIN=$?
assert_exit_code "watchdog.sh --tick-once: windows のスリープ抑止 tick は exit 0" 0 "$WI_EXIT_WIN"
WI_CMD_WIN="$(cat "$WI_SINK_WIN" 2>/dev/null)"
case "$WI_CMD_WIN" in
  windows*"SetThreadExecutionState"*"0x00000001"*)
    pass "watchdog.sh: windowsでSetThreadExecutionStateを含むコマンドが組み立てられる" ;;
  *)
    fail "watchdog.sh: windowsでSetThreadExecutionStateを含むコマンドが組み立てられる" "$WI_CMD_WIN" ;;
esac
case "$WI_CMD_WIN" in
  *powershell*-NoProfile*) pass "watchdog.sh: windowsのコマンドはpowershell -NoProfileで組み立てられる" ;;
  *)                       fail "watchdog.sh: windowsのコマンドはpowershell -NoProfileで組み立てられる" "$WI_CMD_WIN" ;;
esac

# --- macos: caffeinate -u -t <tick+30> を含むコマンドが組み立てられる ---

WI_ROOT_MAC="$(wd_new_root)"
WI_SINK_MAC="${WI_WORK}/macos.cmd"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_MAC" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=macos DEV_WORKFLOW_WATCHDOG_TICK_SEC=60 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_MAC" PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_CMD_MAC="$(cat "$WI_SINK_MAC" 2>/dev/null)"
case "$WI_CMD_MAC" in
  macos*"caffeinate -u -t 90"*)
    pass "watchdog.sh: macosでcaffeinate -u -t <tick+30>を含むコマンドが組み立てられる" ;;
  *)
    fail "watchdog.sh: macosでcaffeinate -u -t <tick+30>を含むコマンドが組み立てられる" "$WI_CMD_MAC" ;;
esac

# --- linux（systemd-inhibitあり）: systemd-inhibit --what=idle --mode=block を含むコマンドが組み立てられる ---

WI_FAKE_BIN="${WI_WORK}/bin"
mkdir -p "$WI_FAKE_BIN"
printf '#!/bin/bash\nexit 0\n' > "${WI_FAKE_BIN}/systemd-inhibit"
chmod +x "${WI_FAKE_BIN}/systemd-inhibit"

WI_ROOT_LINUX="$(wd_new_root)"
WI_SINK_LINUX="${WI_WORK}/linux.cmd"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_LINUX" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=linux DEV_WORKFLOW_WATCHDOG_TICK_SEC=60 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_LINUX" PATH="${WI_FAKE_BIN}:${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_CMD_LINUX="$(cat "$WI_SINK_LINUX" 2>/dev/null)"
case "$WI_CMD_LINUX" in
  linux*"systemd-inhibit --what=idle --mode=block sleep 90"*)
    pass "watchdog.sh: linux（systemd-inhibitあり）でsystemd-inhibitを含むコマンドが組み立てられる" ;;
  *)
    fail "watchdog.sh: linux（systemd-inhibitあり）でsystemd-inhibitを含むコマンドが組み立てられる" "$WI_CMD_LINUX" ;;
esac

# --- linux（systemd-inhibitなし）: コマンドは組み立てられず、警告のみ記録される ---

WI_ROOT_LINUX_NO="$(wd_new_root)"
WI_SINK_LINUX_NO="${WI_WORK}/linux-no.cmd"
WI_NOTIFY_LINUX_NO="${WI_WORK}/linux-no-notify.json"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_LINUX_NO" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=linux DEV_WORKFLOW_WATCHDOG_TICK_SEC=60 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_LINUX_NO" \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_LINUX_NO" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_LINUX_NO=$?
assert_exit_code "watchdog.sh: linux（systemd-inhibitなし）でも--tick-onceはexit 0" 0 "$WI_EXIT_LINUX_NO"
if [ -f "$WI_SINK_LINUX_NO" ]; then
  fail "watchdog.sh: linux（systemd-inhibitなし）ではコマンドを組み立てない" "$(cat "$WI_SINK_LINUX_NO")"
else
  pass "watchdog.sh: linux（systemd-inhibitなし）ではコマンドを組み立てない"
fi
WI_LOG_LINUX_NO="${WI_ROOT_LINUX_NO}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tsleep-inhibit-warn\t')" "$WI_LOG_LINUX_NO" 2>/dev/null; then
  pass "watchdog.sh: linux（systemd-inhibitなし）は警告としてログに記録される"
else
  fail "watchdog.sh: linux（systemd-inhibitなし）は警告としてログに記録される" "$(cat "$WI_LOG_LINUX_NO" 2>&1)"
fi
WI_NOTIFY_BODY_LINUX_NO="$(cat "$WI_NOTIFY_LINUX_NO" 2>/dev/null)"
case "$WI_NOTIFY_BODY_LINUX_NO" in
  *"スリープ抑止に失敗"*) pass "watchdog.sh: 抑止手段が無い場合もSlackへ警告が通知される" ;;
  *)                      fail "watchdog.sh: 抑止手段が無い場合もSlackへ警告が通知される" "$WI_NOTIFY_BODY_LINUX_NO" ;;
esac

# --- unknown: 警告を1行出しつつ tick が正常終了する ---

WI_ROOT_UNKNOWN="$(wd_new_root)"
WI_NOTIFY_UNKNOWN="${WI_WORK}/unknown-notify.json"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_UNKNOWN" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=unknown \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_UNKNOWN" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_UNKNOWN=$?
assert_exit_code "watchdog.sh: OS=unknownでも--tick-onceはexit 0で正常終了する" 0 "$WI_EXIT_UNKNOWN"
WI_LOG_UNKNOWN="${WI_ROOT_UNKNOWN}/.claude/.dev-workflow-watchdog.log"
WI_UNKNOWN_WARN_COUNT="$(grep -c "$(printf '\tsleep-inhibit-warn\t')" "$WI_LOG_UNKNOWN" 2>/dev/null || true)"
assert_eq "watchdog.sh: OS=unknownでは警告が1行ログに出る" "1" "${WI_UNKNOWN_WARN_COUNT:-0}"

# --- DEV_WORKFLOW_NO_SLEEP_INHIBIT=1: コマンドが一切組み立てられない ---

WI_ROOT_NOINHIBIT="$(wd_new_root)"
WI_SINK_NOINHIBIT="${WI_WORK}/noinhibit.cmd"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_NOINHIBIT" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=windows DEV_WORKFLOW_NO_SLEEP_INHIBIT=1 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_NOINHIBIT" PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_NOINHIBIT=$?
assert_exit_code "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1でも--tick-onceはexit 0" 0 "$WI_EXIT_NOINHIBIT"
if [ -f "$WI_SINK_NOINHIBIT" ]; then
  fail "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1ではコマンドが一切組み立てられない" \
    "$(cat "$WI_SINK_NOINHIBIT")"
else
  pass "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1ではコマンドが一切組み立てられない"
fi
WI_LOG_NOINHIBIT="${WI_ROOT_NOINHIBIT}/.claude/.dev-workflow-watchdog.log"
if grep -q "sleep-inhibit" "$WI_LOG_NOINHIBIT" 2>/dev/null; then
  fail "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1では抑止関連のログも一切残らない" \
    "$(cat "$WI_LOG_NOINHIBIT" 2>&1)"
else
  pass "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1では抑止関連のログも一切残らない"
fi

# --- 抑止コマンドが失敗する状況（Alpineに実在しないpowershellをそのまま呼ぶ）でも exit 0 ---

WI_ROOT_FAIL="$(wd_new_root)"
WI_NOTIFY_FAIL="${WI_WORK}/fail-notify.json"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_FAIL" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=windows \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_FAIL" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_FAIL=$?
assert_exit_code "watchdog.sh: 抑止コマンドが失敗する状況（powershellが存在しない）でも--tick-onceはexit 0" \
  0 "$WI_EXIT_FAIL"
WI_LOG_FAIL="${WI_ROOT_FAIL}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tsleep-inhibit-warn\t')" "$WI_LOG_FAIL" 2>/dev/null; then
  pass "watchdog.sh: 抑止コマンドの実行失敗が警告としてログに記録される"
else
  fail "watchdog.sh: 抑止コマンドの実行失敗が警告としてログに記録される" "$(cat "$WI_LOG_FAIL" 2>&1)"
fi

# --- 同じ警告は毎tick Slackへ通知されない（初回のみ・以降はログのみ） ---

WI_ROOT_WARNONCE="$(wd_new_root)"
WI_NOTIFY_WARNONCE_1="${WI_WORK}/warnonce-1.json"
WI_NOTIFY_WARNONCE_2="${WI_WORK}/warnonce-2.json"

DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_WARNONCE" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=unknown \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_WARNONCE_1" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
if [ -f "$WI_NOTIFY_WARNONCE_1" ]; then
  pass "watchdog.sh: 抑止警告は初回tickでSlackへ通知される"
else
  fail "watchdog.sh: 抑止警告は初回tickでSlackへ通知される" "sinkが作られませんでした"
fi

DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_WARNONCE" DEV_WORKFLOW_WATCHDOG_NOW=1700800100 \
DEV_WORKFLOW_WATCHDOG_OS=unknown \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_WARNONCE_2" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
if [ -f "$WI_NOTIFY_WARNONCE_2" ]; then
  fail "watchdog.sh: 同じ抑止警告は2回目以降Slackへ通知されない（初回のみ）" \
    "$(cat "$WI_NOTIFY_WARNONCE_2")"
else
  pass "watchdog.sh: 同じ抑止警告は2回目以降Slackへ通知されない（初回のみ）"
fi

WI_LOG_WARNONCE="${WI_ROOT_WARNONCE}/.claude/.dev-workflow-watchdog.log"
WI_WARNONCE_LOG_COUNT="$(grep -c "$(printf '\tsleep-inhibit-warn\t')" "$WI_LOG_WARNONCE" 2>/dev/null || true)"
assert_eq "watchdog.sh: ログには通知の有無に関わらず毎tick記録される（2回）" "2" "${WI_WARNONCE_LOG_COUNT:-0}"

# --- 受け入れ条件6の再確認: スリープ抑止のフックにもkill/自動打ち切り経路が無いこと ---

WI_INHIBIT_BLOCK="$(awk '
  /^_watchdog_detect_os\(\) \{/ {f=1}
  f {print}
  /^_watchdog_sleep_inhibit_tick\(\) \{/ {g=1}
  g && /^}/ {print; exit}
' "$WD_SCRIPT")"
if printf '%s' "$WI_INHIBIT_BLOCK" | grep -qE '\bkill\b'; then
  fail "watchdog.sh: スリープ抑止のコードにkillが存在しない（受け入れ条件6）" "$WI_INHIBIT_BLOCK"
else
  pass "watchdog.sh: スリープ抑止のコードにkillが存在しない（受け入れ条件6）"
fi

# --- curlが一度も実行されていないこと（本セクションの通知もsink経由でのみ検証する） ---
if [ -s "$WDS_CURL_LOG" ]; then
  fail "watchdog.sh: ウェーブ予算・スリープ抑止の通知でもcurlが呼ばれない（実送信しない）" \
    "$(wds_read_sink "$WDS_CURL_LOG")"
else
  pass "watchdog.sh: ウェーブ予算・スリープ抑止の通知でもcurlが呼ばれない（実送信しない）"
fi

# ---------------------------------------------------------------------------
# hooks.json / hooks.codex.json: heartbeat結線（Task #52）
# ---------------------------------------------------------------------------

echo "== hooks.json / hooks.codex.json: heartbeat結線（Task #52） =="

HJ_HOOKS_JSON="${REPO_ROOT}/hooks/hooks.json"
HJ_HOOKS_CODEX_JSON="${REPO_ROOT}/hooks/hooks.codex.json"
HJ_HEARTBEAT_SCRIPT="${REPO_ROOT}/scripts/heartbeat.sh"

# JSONとしての構文妥当性を、jq/pythonを新たに足さず括弧の対応だけで確認する
# （文字列リテラル内の括弧は無視する）。完全なJSONパーサではないが、
# このタスクで書き換える範囲の妥当性を検証するには十分（issue #52 の指示どおり
# 「既存に検証手段が無ければ grep で必要なキー・文字列の存在を確認する」方針に沿う）。
_hj_json_syntax_ok() {
  local file="$1"
  local content
  content="$(cat "$file" 2>/dev/null)" || return 1
  local len=${#content}
  local i char depth_curly=0 depth_square=0 in_string=0 escape=0
  for ((i = 0; i < len; i++)); do
    char="${content:i:1}"
    if [ "$escape" -eq 1 ]; then
      escape=0
      continue
    fi
    if [ "$in_string" -eq 1 ]; then
      case "$char" in
        '\') escape=1 ;;
        '"') in_string=0 ;;
      esac
      continue
    fi
    case "$char" in
      '"') in_string=1 ;;
      '{') depth_curly=$((depth_curly + 1)) ;;
      '}') depth_curly=$((depth_curly - 1)); [ "$depth_curly" -lt 0 ] && return 1 ;;
      '[') depth_square=$((depth_square + 1)) ;;
      ']') depth_square=$((depth_square - 1)); [ "$depth_square" -lt 0 ] && return 1 ;;
    esac
  done
  [ "$depth_curly" -eq 0 ] && [ "$depth_square" -eq 0 ] && [ "$in_string" -eq 0 ]
}

# トップレベルキー（4スペースインデント。例: `    "PostToolUse": [`）から、
# 対応する閉じ `],` または `]` までを抜き出す。結線の取り違え（pre/postの混同など）を
# セクション単位で検出するために使う。
_hj_extract_section() {
  local file="$1" key="$2"
  awk -v line="    \"${key}\": [" '
    $0 == line {f = 1}
    f {print}
    f && /^    \],?$/ {exit}
  ' "$file"
}

if _hj_json_syntax_ok "$HJ_HOOKS_JSON"; then
  pass "hooks.json: 構文として妥当（括弧の対応が取れている）"
else
  fail "hooks.json: 構文として妥当（括弧の対応が取れている）" "$(cat "$HJ_HOOKS_JSON" 2>&1)"
fi

if _hj_json_syntax_ok "$HJ_HOOKS_CODEX_JSON"; then
  pass "hooks.codex.json: 構文として妥当（括弧の対応が取れている）"
else
  fail "hooks.codex.json: 構文として妥当（括弧の対応が取れている）" "$(cat "$HJ_HOOKS_CODEX_JSON" 2>&1)"
fi

# --- heartbeat.sh の実契約（pre|postのみを受理する）を確認してから、結線がそれに沿っているか検証する ---

HJ_HB_ACCEPTED_LINE="$(grep -E '^\s*pre\|post\)' "$HJ_HEARTBEAT_SCRIPT")"
if printf '%s' "$HJ_HB_ACCEPTED_LINE" | grep -q 'pre' \
  && printf '%s' "$HJ_HB_ACCEPTED_LINE" | grep -q 'post'; then
  pass "heartbeat.sh: 受理する引数がpre/postであることを確認できる（結線テストの前提）"
else
  fail "heartbeat.sh: 受理する引数がpre/postであることを確認できる（結線テストの前提）" \
    "case文にpre|postが見つかりません: ${HJ_HB_ACCEPTED_LINE}"
fi

# --- hooks.json: PreToolUse(matcher=*)にheartbeat.sh preが結線されている ---

# JSON文字列内の `"` はエスケープされて `\"` になっているため、grep -Fq の照合パターンにも
# バックスラッシュを含める（例: `"command": "bash \"${CLAUDE_PLUGIN_ROOT}/...\" pre"`）。
# ここを素の `"` のまま書くと、実ファイルの内容と1文字も一致せず必ず不一致になる。
HJ_PRETOOLUSE="$(_hj_extract_section "$HJ_HOOKS_JSON" "PreToolUse")"
if printf '%s' "$HJ_PRETOOLUSE" | grep -Fq '"matcher": "*"' \
  && printf '%s' "$HJ_PRETOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh\" pre'; then
  pass "hooks.json: PreToolUse(matcher=*)にheartbeat.sh preが結線されている"
else
  fail "hooks.json: PreToolUse(matcher=*)にheartbeat.sh preが結線されている" "$HJ_PRETOOLUSE"
fi

# pre/postの取り違えはabort判定（#50）を機能させなくする致命的なバグになるため、
# 混入していないことを個別に確認する
if printf '%s' "$HJ_PRETOOLUSE" | grep -Fq 'heartbeat.sh\" post'; then
  fail "hooks.json: PreToolUseにheartbeat.sh postが紛れ込んでいない" "$HJ_PRETOOLUSE"
else
  pass "hooks.json: PreToolUseにheartbeat.sh postが紛れ込んでいない"
fi

# --- hooks.json: PostToolUse(matcher=*)にheartbeat.sh postが結線され、既存の可読性ガードも残っている ---

HJ_POSTTOOLUSE="$(_hj_extract_section "$HJ_HOOKS_JSON" "PostToolUse")"
if printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq '"matcher": "*"' \
  && printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh\" post'; then
  pass "hooks.json: PostToolUse(matcher=*)にheartbeat.sh postが結線されている"
else
  fail "hooks.json: PostToolUse(matcher=*)にheartbeat.sh postが結線されている" "$HJ_POSTTOOLUSE"
fi

if printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq 'heartbeat.sh\" pre'; then
  fail "hooks.json: PostToolUseにheartbeat.sh preが紛れ込んでいない" "$HJ_POSTTOOLUSE"
else
  pass "hooks.json: PostToolUseにheartbeat.sh preが紛れ込んでいない"
fi

if printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq '"matcher": "Write|Edit|MultiEdit"' \
  && printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh\"'; then
  pass "hooks.json: PostToolUseの既存check-readability.sh（matcher=Write|Edit|MultiEdit）が残っている"
else
  fail "hooks.json: PostToolUseの既存check-readability.sh（matcher=Write|Edit|MultiEdit）が残っている" \
    "$HJ_POSTTOOLUSE"
fi

# --- hooks.codex.json: PreToolUse(matcher=*)にheartbeat.sh preが結線されている ---
#
# CodexのイベントにPreToolUseは実在する（docs/dev-workflow-multi-vendor-guide.md §3.5.1）。
# 当初（#52）はこれを「Codexに存在しない」と誤認して縮退させていたが、レビュー#59で
# タスク間の不整合として指摘され、レビュー#61（state=postしか記録されず原因切り分けが
# 成立しない）と合わせて結線することにした（詳細はheartbeat.shの打ち切り判定コメントを参照）。
# ブロック契約自体はClaude Codeと異なり`continue`非対応でsystemMessageのみ（§3.5.2）だが、
# state=preの記録（pre/postの切り分け）自体はブロック契約と独立して機能するため、
# 結線するだけで#61の実害（stateが常にpostになる問題）は解消する。

HJ_CODEX_PRETOOLUSE="$(_hj_extract_section "$HJ_HOOKS_CODEX_JSON" "PreToolUse")"
if printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Fq '"matcher": "*"' \
  && printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh\" pre'; then
  pass "hooks.codex.json: PreToolUse(matcher=*)にheartbeat.sh preが結線されている（#59, #61）"
else
  fail "hooks.codex.json: PreToolUse(matcher=*)にheartbeat.sh preが結線されている（#59, #61）" \
    "$HJ_CODEX_PRETOOLUSE"
fi

if printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Fq 'heartbeat.sh\" post'; then
  fail "hooks.codex.json: PreToolUseにheartbeat.sh postが紛れ込んでいない" "$HJ_CODEX_PRETOOLUSE"
else
  pass "hooks.codex.json: PreToolUseにheartbeat.sh postが紛れ込んでいない"
fi

HJ_CODEX_POSTTOOLUSE="$(_hj_extract_section "$HJ_HOOKS_CODEX_JSON" "PostToolUse")"
if printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq '"matcher": "*"' \
  && printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh\" post'; then
  pass "hooks.codex.json: PostToolUse(matcher=*)にheartbeat.sh postが結線されている"
else
  fail "hooks.codex.json: PostToolUse(matcher=*)にheartbeat.sh postが結線されている" "$HJ_CODEX_POSTTOOLUSE"
fi

if printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq 'heartbeat.sh\" pre'; then
  fail "hooks.codex.json: PostToolUseにheartbeat.sh preが紛れ込んでいない" "$HJ_CODEX_POSTTOOLUSE"
else
  pass "hooks.codex.json: PostToolUseにheartbeat.sh preが紛れ込んでいない"
fi

if printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq '"matcher": "Write|Edit|MultiEdit|apply_patch"' \
  && printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh\"'; then
  pass "hooks.codex.json: PostToolUseの既存check-readability.sh（matcher=Write|Edit|MultiEdit|apply_patch）が残っている"
else
  fail "hooks.codex.json: PostToolUseの既存check-readability.sh（matcher=Write|Edit|MultiEdit|apply_patch）が残っている" \
    "$HJ_CODEX_POSTTOOLUSE"
fi

# --- hooks.codex.json: 既存のStop3フック（通知・可読性ガード・変更チェック）が残っている ---

HJ_CODEX_STOP="$(_hj_extract_section "$HJ_HOOKS_CODEX_JSON" "Stop")"
if printf '%s' "$HJ_CODEX_STOP" | grep -Fq 'notify-slack.sh\" stop' \
  && printf '%s' "$HJ_CODEX_STOP" | grep -Fq 'check-readability.sh\" --git' \
  && printf '%s' "$HJ_CODEX_STOP" | grep -Fq 'check-stop-review.sh\"'; then
  pass "hooks.codex.json: 既存のStop3フック（通知・可読性ガード・変更チェック）が残っている"
else
  fail "hooks.codex.json: 既存のStop3フック（通知・可読性ガード・変更チェック）が残っている" "$HJ_CODEX_STOP"
fi

# --- 両JSONとも heartbeat.sh の結線が ${CLAUDE_PLUGIN_ROOT} を使ったパス指定になっている ---

if grep -Fq '${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh' "$HJ_HOOKS_JSON"; then
  pass "hooks.json: heartbeat.shの結線が\${CLAUDE_PLUGIN_ROOT}を使ったパス指定になっている"
else
  fail "hooks.json: heartbeat.shの結線が\${CLAUDE_PLUGIN_ROOT}を使ったパス指定になっている" \
    "$(cat "$HJ_HOOKS_JSON")"
fi

if grep -Fq '${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh' "$HJ_HOOKS_CODEX_JSON"; then
  pass "hooks.codex.json: heartbeat.shの結線が\${CLAUDE_PLUGIN_ROOT}を使ったパス指定になっている"
else
  fail "hooks.codex.json: heartbeat.shの結線が\${CLAUDE_PLUGIN_ROOT}を使ったパス指定になっている" \
    "$(cat "$HJ_HOOKS_CODEX_JSON")"
fi

# --- フックが参照しているscripts/heartbeat.shが実在する（参照切れの防止） ---

if [ -f "$HJ_HEARTBEAT_SCRIPT" ]; then
  pass "hooks.json/hooks.codex.json: 参照しているscripts/heartbeat.shが実在する"
else
  fail "hooks.json/hooks.codex.json: 参照しているscripts/heartbeat.shが実在する" \
    "見つかりません: ${HJ_HEARTBEAT_SCRIPT}"
fi

# ---------------------------------------------------------------------------
# ドキュメント（共通ルール・generator・README）とアダプタ再生成・v0.13.0（#55）
# ---------------------------------------------------------------------------

echo "== ドキュメント（共通ルール・generator・README）とアダプタ再生成・v0.13.0（#55） =="

DOC55_CLAUDE_PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
DOC55_CODEX_PLUGIN_JSON="${REPO_ROOT}/.codex-plugin/plugin.json"
DOC55_INSTRUCTIONS="${REPO_ROOT}/core/instructions.md"
DOC55_GENERATOR_ROLE="${REPO_ROOT}/core/roles/generator.md"
DOC55_README="${REPO_ROOT}/README.md"
DOC55_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC55_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"

# --- 両 plugin.json のバージョンが 0.14.0 で一致している（#77でv0.13.0から更新） ---

DOC55_CLAUDE_VERSION="$(grep -m1 '"version"' "$DOC55_CLAUDE_PLUGIN_JSON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
DOC55_CODEX_VERSION="$(grep -m1 '"version"' "$DOC55_CODEX_PLUGIN_JSON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

assert_eq ".claude-plugin/plugin.json のバージョンが0.14.0である" "0.14.0" "$DOC55_CLAUDE_VERSION"
assert_eq ".codex-plugin/plugin.json のバージョンが0.14.0である" "0.14.0" "$DOC55_CODEX_VERSION"
assert_eq "両plugin.jsonのバージョンが一致している" "$DOC55_CLAUDE_VERSION" "$DOC55_CODEX_VERSION"

# --- core/instructions.md に watchdog の3点の記述がある ---

if grep -Fq 'watchdog は検知して通知するだけであり' "$DOC55_INSTRUCTIONS"; then
  pass "core/instructions.md: 「watchdogは検知して通知するだけ」の記述がある"
else
  fail "core/instructions.md: 「watchdogは検知して通知するだけ」の記述がある"
fi

if grep -Fq '自動打ち切りは原理的に実装できない' "$DOC55_INSTRUCTIONS" \
  && grep -Fq 'Claude Code ではサブエージェントを外部から中断できない' "$DOC55_INSTRUCTIONS"; then
  pass "core/instructions.md: 「Claude Codeでは自動打ち切りが原理的に不可能」の記述がある"
else
  fail "core/instructions.md: 「Claude Codeでは自動打ち切りが原理的に不可能」の記述がある"
fi

if grep -Fq 'アダプタ間に' "$DOC55_INSTRUCTIONS" && grep -Fq '機能差を作らないため採用していない' "$DOC55_INSTRUCTIONS"; then
  pass "core/instructions.md: 「Codexでも採用していない（機能差を作らない）」の記述がある"
else
  fail "core/instructions.md: 「Codexでも採用していない（機能差を作らない）」の記述がある"
fi

# --- core/roles/generator.md に拒否メッセージを受けたときの振る舞いの記述がある ---

if grep -Fq '打ち切りが指示されました' "$DOC55_GENERATOR_ROLE" \
  && grep -Fq '別のツールで迂回・回避を試みない' "$DOC55_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 拒否メッセージを受けたときの振る舞い（別のツールで回避しない）の記述がある"
else
  fail "core/roles/generator.md: 拒否メッセージを受けたときの振る舞い（別のツールで回避しない）の記述がある"
fi

if grep -Fq '実施済みの変更・' "$DOC55_GENERATOR_ROLE" && grep -Fq '未コミットの有無' "$DOC55_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 拒否メッセージを受けたときに現状（変更・未コミット）を報告する記述がある"
else
  fail "core/roles/generator.md: 拒否メッセージを受けたときに現状（変更・未コミット）を報告する記述がある"
fi

# --- README に運用手順の節と「抑止できないもの」の記述がある ---

if grep -Fq '## 運用手順（watchdog）' "$DOC55_README"; then
  pass "README.md: 「運用手順（watchdog）」の節がある"
else
  fail "README.md: 「運用手順（watchdog）」の節がある"
fi

if grep -Fq '抑止できないもの' "$DOC55_README" \
  && grep -Fq 'ふたを閉じる操作' "$DOC55_README" \
  && grep -Fq 'バッテリー切れ' "$DOC55_README"; then
  pass "README.md: 「抑止できないもの」（ふたを閉じる操作・バッテリー切れ等）の記述がある"
else
  fail "README.md: 「抑止できないもの」（ふたを閉じる操作・バッテリー切れ等）の記述がある"
fi

if grep -Fq 'DEV_WORKFLOW_WATCHDOG_IDLE_SEC' "$DOC55_README" \
  && grep -Fq 'DEV_WORKFLOW_NO_SLEEP_INHIBIT' "$DOC55_README"; then
  pass "README.md: watchdogの環境変数一覧がある"
else
  fail "README.md: watchdogの環境変数一覧がある"
fi

# セッション中断後は watchdog.sh --stop を実行する旨の記述が存在すること（レビュー#62）。
# セッションをプロセスごと中断するとStopフックが発火せずrunマーカーが残り続け、
# watchdogが打ち切りに気付かないまま無活動検知・エスカレーション通知を出し続けるため。
DOC62_README_HANG_SECTION="$(awk '/^### ハングしたときの対処/{f=1} /^### スリープ抑止/{f=0} f' "$DOC55_README")"

if [ -n "$DOC62_README_HANG_SECTION" ]; then
  pass "README.md: 「ハングしたときの対処」の節が存在する（#62）"
else
  fail "README.md: 「ハングしたときの対処」の節が存在する（#62）" "節が見つかりません"
fi

case "$DOC62_README_HANG_SECTION" in
  *'watchdog.sh" --stop'*)
    pass "README.md: ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" ;;
  *)
    fail "README.md: ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" \
      "$DOC62_README_HANG_SECTION" ;;
esac

case "$DOC62_README_HANG_SECTION" in
  *'Stop フックが走らず'*'run マーカー'*)
    pass "README.md: セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" ;;
  *)
    fail "README.md: セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" \
      "$DOC62_README_HANG_SECTION" ;;
esac

# --- 生成物（agents/generator.md 等）に正本の追記内容が反映されている ---

if [ -f "$DOC55_AGENT_GENERATOR" ] \
  && grep -Fq '打ち切りが指示されました' "$DOC55_AGENT_GENERATOR" \
  && grep -Fq 'watchdog は検知して通知するだけであり' "$DOC55_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本（core/roles/generator.md・core/instructions.md）の追記内容が反映されている"
else
  fail "agents/generator.md: 正本（core/roles/generator.md・core/instructions.md）の追記内容が反映されている" \
    "見つかりません: ${DOC55_AGENT_GENERATOR}"
fi

if [ -f "$DOC55_CODEX_AGENT_GENERATOR" ] \
  && grep -Fq '打ち切りが指示されました' "$DOC55_CODEX_AGENT_GENERATOR" \
  && grep -Fq 'watchdog は検知して通知するだけであり' "$DOC55_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: 正本の追記内容が反映されている"
else
  fail "codex-agents/generator.toml: 正本の追記内容が反映されている" \
    "見つかりません: ${DOC55_CODEX_AGENT_GENERATOR}"
fi

# --- adapters/claude/build.sh・adapters/codex/build.sh の再生成後に差分が出ない（--check） ---

DOC55_CLAUDE_BUILD_CHECK_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-claude-build-check.XXXXXX")"
DOC55_CODEX_BUILD_CHECK_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-codex-build-check.XXXXXX")"

if bash "${REPO_ROOT}/adapters/claude/build.sh" --check >"$DOC55_CLAUDE_BUILD_CHECK_LOG" 2>&1; then
  pass "adapters/claude/build.sh --check: 生成物が正本と一致している（再生成後に差分が無い）"
else
  fail "adapters/claude/build.sh --check: 生成物が正本と一致している（再生成後に差分が無い）" \
    "$(cat "$DOC55_CLAUDE_BUILD_CHECK_LOG")"
fi

if bash "${REPO_ROOT}/adapters/codex/build.sh" --check >"$DOC55_CODEX_BUILD_CHECK_LOG" 2>&1; then
  pass "adapters/codex/build.sh --check: 生成物が正本と一致している（再生成後に差分が無い）"
else
  fail "adapters/codex/build.sh --check: 生成物が正本と一致している（再生成後に差分が無い）" \
    "$(cat "$DOC55_CODEX_BUILD_CHECK_LOG")"
fi

# ---------------------------------------------------------------------------
echo "== Task issueテンプレートの「- Epic: #N」行規定（レビュー#56） =="

# plan-waves.sh の load_from_gh は本文の「- Epic: #N」行で他Epicのタスクを除外する
# （行が無ければフェイルオープンで含める）。この行がどの成果物にも規定されていないと、
# テンプレートどおりに作った Task issue が別Epicの実行中にウェーブ計画へ混入する
# （#39 の再発）。テンプレート・役割定義側に規定があることを固定する。

DOC56_EPIC_SKILL="${REPO_ROOT}/skills/epic/SKILL.md"
DOC56_PLANNER_ROLE="${REPO_ROOT}/core/roles/planner.md"
DOC56_PLAN_SKILL="${REPO_ROOT}/skills/plan/SKILL.md"
DOC56_CODEX_PLAN_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-plan/SKILL.md"
DOC56_PLAN_WAVES="${REPO_ROOT}/scripts/plan-waves.sh"
DOC56_AGENT_PLANNER="${REPO_ROOT}/agents/planner.md"
DOC56_CODEX_AGENT_PLANNER="${REPO_ROOT}/codex-agents/planner.toml"

if grep -Fq -e '- Epic: #[epic番号]' "$DOC56_EPIC_SKILL"; then
  pass "skills/epic/SKILL.md: Task issue本文テンプレートに「- Epic: #[epic番号]」行がある（#56）"
else
  fail "skills/epic/SKILL.md: Task issue本文テンプレートに「- Epic: #[epic番号]」行がある（#56）"
fi

if grep -Fq '`- Epic: #N`' "$DOC56_PLANNER_ROLE"; then
  pass "core/roles/planner.md: 依存宣言の節に「- Epic: #N」の必須化が明記されている（#56）"
else
  fail "core/roles/planner.md: 依存宣言の節に「- Epic: #N」の必須化が明記されている（#56）"
fi

if grep -Fq '`- Epic: #N`' "$DOC56_PLAN_SKILL"; then
  pass "skills/plan/SKILL.md: Task issue要件に「- Epic: #N」が明記されている（#56）"
else
  fail "skills/plan/SKILL.md: Task issue要件に「- Epic: #N」が明記されている（#56）"
fi

if grep -Fq '`- Epic: #N`' "$DOC56_CODEX_PLAN_SKILL"; then
  pass "skills-codex/dev-workflow-plan/SKILL.md: Task issue要件に「- Epic: #N」が明記されている（#56）"
else
  fail "skills-codex/dev-workflow-plan/SKILL.md: Task issue要件に「- Epic: #N」が明記されている（#56）"
fi

if grep -Fq 'skills/epic/SKILL.md' "$DOC56_PLAN_WAVES" && grep -Fq 'Task issue テンプレート' "$DOC56_PLAN_WAVES"; then
  pass "scripts/plan-waves.sh: ヘッダコメントが「- Epic:」行の出所をskills/epic/SKILL.mdに正しく記載している（#56）"
else
  fail "scripts/plan-waves.sh: ヘッダコメントが「- Epic:」行の出所をskills/epic/SKILL.mdに正しく記載している（#56）"
fi

# core/roles/planner.md の追記は adapters/*/build.sh の再生成対象であるため、
# 生成物側にも同じ記述が反映されていることを固定する（生成漏れの検出）。
if [ -f "$DOC56_AGENT_PLANNER" ] && grep -Fq '`- Epic: #N`' "$DOC56_AGENT_PLANNER"; then
  pass "agents/planner.md: 正本（core/roles/planner.md）の「- Epic: #N」追記内容が反映されている（#56）"
else
  fail "agents/planner.md: 正本（core/roles/planner.md）の「- Epic: #N」追記内容が反映されている（#56）" \
    "見つかりません: ${DOC56_AGENT_PLANNER}"
fi

if [ -f "$DOC56_CODEX_AGENT_PLANNER" ] && grep -Fq '`- Epic: #N`' "$DOC56_CODEX_AGENT_PLANNER"; then
  pass "codex-agents/planner.toml: 正本の「- Epic: #N」追記内容が反映されている（#56）"
else
  fail "codex-agents/planner.toml: 正本の「- Epic: #N」追記内容が反映されている（#56）" \
    "見つかりません: ${DOC56_CODEX_AGENT_PLANNER}"
fi

# ---------------------------------------------------------------------------
echo "== DEV_WORKFLOW_TEST_CMD の必須化がREADME/ガイドに反映されている（レビュー#57） =="

# adapters/codex/run-loop.sh は DEV_WORKFLOW_TEST_CMD が未設定なら exit 1 する（#37対応）。
# この必須化が利用者向けドキュメントに反映されていないと、ドキュメントどおりに起動した
# 利用者が原因不明の停止に見える形で失敗する。

DOC57_README="${REPO_ROOT}/README.md"
DOC57_GUIDE="${REPO_ROOT}/docs/dev-workflow-multi-vendor-guide.md"
DOC57_RUN_LOOP="${REPO_ROOT}/adapters/codex/run-loop.sh"

# run-loop.sh の必須チェックが実在し、「DRY_RUNならcodex起動をスキップする」分岐より前に
# あることをまず固定する（ドキュメントの「DRY_RUNでも必須」という説明が実装と食い違わない
# ようにするため）。L72 の `[ "$DRY_RUN" = "1" ] || need codex` は codex コマンドの存在確認を
# 条件分岐しているだけで「スキップして確認だけする」分岐ではないため対象外とし、
# 実際に処理をスキップする `if [ "$DRY_RUN" = "1" ]; then` ブロックの初出を基準にする。
DOC57_RUN_LOOP_REQUIRED_LINE="$(grep -n 'DEV_WORKFLOW_TEST_CMD が未設定です' "$DOC57_RUN_LOOP" | head -1 | cut -d: -f1)"
DOC57_RUN_LOOP_DRY_RUN_LINE="$(grep -n 'if \[ "\$DRY_RUN" = "1" \]; then' "$DOC57_RUN_LOOP" | head -1 | cut -d: -f1)"

if [ -n "$DOC57_RUN_LOOP_REQUIRED_LINE" ] && [ -n "$DOC57_RUN_LOOP_DRY_RUN_LINE" ] \
  && [ "$DOC57_RUN_LOOP_REQUIRED_LINE" -lt "$DOC57_RUN_LOOP_DRY_RUN_LINE" ]; then
  pass "adapters/codex/run-loop.sh: DEV_WORKFLOW_TEST_CMD必須チェック（L${DOC57_RUN_LOOP_REQUIRED_LINE}）がDRY_RUN分岐（L${DOC57_RUN_LOOP_DRY_RUN_LINE}）より前にある（#57）"
else
  fail "adapters/codex/run-loop.sh: DEV_WORKFLOW_TEST_CMD必須チェックがDRY_RUN分岐より前にある（#57）" \
    "required_line=${DOC57_RUN_LOOP_REQUIRED_LINE:-なし} dry_run_line=${DOC57_RUN_LOOP_DRY_RUN_LINE:-なし}"
fi

if grep -Fq 'DEV_WORKFLOW_TEST_CMD=' "$DOC57_README" && grep -Fq 'run-loop.sh' "$DOC57_README"; then
  pass "README.md: 「無人で回す」のコマンド例にDEV_WORKFLOW_TEST_CMDが含まれる（#57）"
else
  fail "README.md: 「無人で回す」のコマンド例にDEV_WORKFLOW_TEST_CMDが含まれる（#57）"
fi

if grep -Fq '必須' "$DOC57_README" && grep -Fq 'DEV_WORKFLOW_TEST_CMD' "$DOC57_README"; then
  pass "README.md: DEV_WORKFLOW_TEST_CMDが必須である旨の説明がある（#57）"
else
  fail "README.md: DEV_WORKFLOW_TEST_CMDが必須である旨の説明がある（#57）"
fi

if grep -Fq 'DRY_RUN より前に走るため' "$DOC57_README"; then
  pass "README.md: DRY_RUNの案内にもDEV_WORKFLOW_TEST_CMDが必要である旨が明記されている（#57）"
else
  fail "README.md: DRY_RUNの案内にもDEV_WORKFLOW_TEST_CMDが必要である旨が明記されている（#57）"
fi

if grep -Fq 'DEV_WORKFLOW_TEST_CMD=' "$DOC57_GUIDE" && grep -Fq 'run-loop.sh' "$DOC57_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: 「完全無人で回す場合」のコマンド例にDEV_WORKFLOW_TEST_CMDが含まれる（#57）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: 「完全無人で回す場合」のコマンド例にDEV_WORKFLOW_TEST_CMDが含まれる（#57）"
fi

if grep -Fq '必須' "$DOC57_GUIDE" && grep -Fq 'DEV_WORKFLOW_TEST_CMD' "$DOC57_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: DEV_WORKFLOW_TEST_CMDが必須である旨の説明がある（#57）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: DEV_WORKFLOW_TEST_CMDが必須である旨の説明がある（#57）"
fi

if grep -Fq 'DRY_RUN' "$DOC57_GUIDE" && grep -Fq 'DRY_RUN より前' "$DOC57_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: DRY_RUNの案内にもDEV_WORKFLOW_TEST_CMDが必要である旨が明記されている（#57）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: DRY_RUNの案内にもDEV_WORKFLOW_TEST_CMDが必要である旨が明記されている（#57）"
fi

# ---------------------------------------------------------------------------
echo "== ponytail の7段ラダーを generator の正本に規定（#69） =="

# ponytail（DietrichGebert/ponytail, MIT）の「最も怠惰なシニア開発者のように考える」7段の判断ラダーを
# core/roles/generator.md に日本語で規定する。実装コードのみが対象でテストは対象外。
# 生成物（agents/generator.md・codex-agents/generator.toml）にも同じ文言が反映されていることを検査する。

DOC69_GENERATOR_ROLE="${REPO_ROOT}/core/roles/generator.md"
DOC69_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC69_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"

# --- core/roles/generator.md に7段のラダーが日本語で規定されている ---

if grep -Fq '7段のラダー' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'これは存在する必要があるか？' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'ここまで来て初めて: 動く最小限を書く' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 7段のラダーが日本語で規定されている（#69）"
else
  fail "core/roles/generator.md: 7段のラダーが日本語で規定されている（#69）"
fi

# --- 「削ってはいけないもの」にテスト・回帰確認・検証が含まれている ---

if grep -Fq '削ってはいけないもの' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'テスト・回帰確認・検証' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 「削ってはいけないもの」にテスト・回帰確認・検証が含まれている（#69）"
else
  fail "core/roles/generator.md: 「削ってはいけないもの」にテスト・回帰確認・検証が含まれている（#69）"
fi

# --- 実装コードのみ対象、テストコードには適用しない旨が明記されている ---

if grep -Fq '実装コードにのみ適用する' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'テストコードには適用しない' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 「実装コードのみ対象、テストコードには適用しない」旨が明記されている（#69）"
else
  fail "core/roles/generator.md: 「実装コードのみ対象、テストコードには適用しない」旨が明記されている（#69）"
fi

# --- 出典（DietrichGebert/ponytail, MIT）が明記されている ---

if grep -Fq 'DietrichGebert/ponytail' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'MIT License' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 出典（DietrichGebert/ponytail, MIT）が明記されている（#69）"
else
  fail "core/roles/generator.md: 出典（DietrichGebert/ponytail, MIT）が明記されている（#69）"
fi

# --- 完了報告テンプレートに「作らなかったもの」の欄がある ---

if grep -Fq '作らなかったもの（ラダー判定）' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 完了報告テンプレートに「作らなかったもの（ラダー判定）」の欄がある（#69）"
else
  fail "core/roles/generator.md: 完了報告テンプレートに「作らなかったもの（ラダー判定）」の欄がある（#69）"
fi

# --- 生成物（agents/generator.md・codex-agents/generator.toml）に正本の追記内容が反映されている ---

if [ -f "$DOC69_AGENT_GENERATOR" ] \
  && grep -Fq '7段のラダー' "$DOC69_AGENT_GENERATOR" \
  && grep -Fq 'DietrichGebert/ponytail' "$DOC69_AGENT_GENERATOR" \
  && grep -Fq '作らなかったもの（ラダー判定）' "$DOC69_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本（core/roles/generator.md）のponytailラダー追記内容が反映されている（#69）"
else
  fail "agents/generator.md: 正本（core/roles/generator.md）のponytailラダー追記内容が反映されている（#69）" \
    "見つかりません: ${DOC69_AGENT_GENERATOR}"
fi

if [ -f "$DOC69_CODEX_AGENT_GENERATOR" ] \
  && grep -Fq '7段のラダー' "$DOC69_CODEX_AGENT_GENERATOR" \
  && grep -Fq 'DietrichGebert/ponytail' "$DOC69_CODEX_AGENT_GENERATOR" \
  && grep -Fq '作らなかったもの（ラダー判定）' "$DOC69_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: 正本のponytailラダー追記内容が反映されている（#69）"
else
  fail "codex-agents/generator.toml: 正本のponytailラダー追記内容が反映されている（#69）" \
    "見つかりません: ${DOC69_CODEX_AGENT_GENERATOR}"
fi

# ---------------------------------------------------------------------------
echo "== 「過剰実装・過剰設計」をレビュー観点に追加（#70） =="

# ponytail のラダー（#69）と対になる、evaluator 側の「作らなくてよいものを作った差分」の
# 検出観点を core/roles/evaluator.md と core/instructions.md に規定する。
# core/instructions.md は agents/*.md と codex-agents/*.toml の全ファイルに反映される。

DOC70_EVALUATOR_ROLE="${REPO_ROOT}/core/roles/evaluator.md"
DOC70_INSTRUCTIONS="${REPO_ROOT}/core/instructions.md"
DOC70_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
DOC70_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"

# --- core/roles/evaluator.md のレビューチェックリストに「過剰実装・過剰設計」の小節がある ---

if grep -Fq '#### 過剰実装・過剰設計' "$DOC70_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: レビューチェックリストに「過剰実装・過剰設計」の小節がある（#70）"
else
  fail "core/roles/evaluator.md: レビューチェックリストに「過剰実装・過剰設計」の小節がある（#70）"
fi

# --- チェックリストに「削ってはいけないものを削っていないか」の項目が含まれている ---

if grep -Fq 'テスト・回帰確認・検証・セキュリティ・データ損失の扱いを「削減」していないか' "$DOC70_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 「削ってはいけないものを削っていないか」の項目が含まれている（#70）"
else
  fail "core/roles/evaluator.md: 「削ってはいけないものを削っていないか」の項目が含まれている（#70）"
fi

# --- core/instructions.md のレビュー基準に、過剰実装・過剰設計の重要度の当てはめが明記されている ---

if grep -Fq '過剰実装・過剰設計の重要度の当てはめ' "$DOC70_INSTRUCTIONS" \
  && grep -Fq '仕様・Task issue に無い機能を足している（明確な仕様逸脱） | high' "$DOC70_INSTRUCTIONS" \
  && grep -Fq '重複実装・不要な抽象化・自前実装で済ませられた標準機能の再実装 | medium' "$DOC70_INSTRUCTIONS" \
  && grep -Fq '好みの範囲の簡潔さ（1行にできた等） | low' "$DOC70_INSTRUCTIONS"; then
  pass "core/instructions.md: レビュー基準に過剰実装・過剰設計の重要度の当てはめが明記されている（#70）"
else
  fail "core/instructions.md: レビュー基準に過剰実装・過剰設計の重要度の当てはめが明記されている（#70）"
fi

# --- 生成物（agents/evaluator.md・codex-agents/evaluator.toml）に反映されている ---

if [ -f "$DOC70_AGENT_EVALUATOR" ] \
  && grep -Fq '#### 過剰実装・過剰設計' "$DOC70_AGENT_EVALUATOR" \
  && grep -Fq '過剰実装・過剰設計の重要度の当てはめ' "$DOC70_AGENT_EVALUATOR"; then
  pass "agents/evaluator.md: 正本の「過剰実装・過剰設計」追記内容が反映されている（#70）"
else
  fail "agents/evaluator.md: 正本の「過剰実装・過剰設計」追記内容が反映されている（#70）" \
    "見つかりません: ${DOC70_AGENT_EVALUATOR}"
fi

if [ -f "$DOC70_CODEX_AGENT_EVALUATOR" ] \
  && grep -Fq '#### 過剰実装・過剰設計' "$DOC70_CODEX_AGENT_EVALUATOR" \
  && grep -Fq '過剰実装・過剰設計の重要度の当てはめ' "$DOC70_CODEX_AGENT_EVALUATOR"; then
  pass "codex-agents/evaluator.toml: 正本の「過剰実装・過剰設計」追記内容が反映されている（#70）"
else
  fail "codex-agents/evaluator.toml: 正本の「過剰実装・過剰設計」追記内容が反映されている（#70）" \
    "見つかりません: ${DOC70_CODEX_AGENT_EVALUATOR}"
fi

# ---------------------------------------------------------------------------
echo "== プラグイン宣言MCPの未導入時挙動を実測しdocs/optional-mcp-tools.mdに記録している（#67） =="

# Epic #66 Phase 1（#67）: MCP結線方式（方式A: 宣言方式 / 方式B: 非宣言方式）を実測して確定し、
# 後続タスク（#71 context7 / #73 code-review-graph）が同じ文書を参照できるようにする。
# 決め打ちで方式名だけ書いていないか、必須6節が揃っているかを機械的に検査する。

DOC67_MCP="${REPO_ROOT}/docs/optional-mcp-tools.md"

if [ -f "$DOC67_MCP" ]; then
  pass "docs/optional-mcp-tools.md が存在する（#67）"

  for section in "## 対象ツール" "## 実測手順" "## 実測結果" "## 採用方式" "## MCP ツール名" "## 任意依存であることの保証"; do
    if grep -Fq "$section" "$DOC67_MCP"; then
      pass "docs/optional-mcp-tools.md: 「${section}」節がある（#67）"
    else
      fail "docs/optional-mcp-tools.md: 「${section}」節がある（#67）"
    fi
  done

  DOC67_ADOPTED_SECTION="$(awk '/^## 採用方式/{flag=1; next} /^## /{flag=0} flag' "$DOC67_MCP")"
  if printf '%s' "$DOC67_ADOPTED_SECTION" | grep -Fq '方式A: 宣言方式' \
    || printf '%s' "$DOC67_ADOPTED_SECTION" | grep -Fq '方式B: 非宣言方式'; then
    pass "docs/optional-mcp-tools.md: 「## 採用方式」節に方式A/Bいずれかが明記されている（#67）"
  else
    fail "docs/optional-mcp-tools.md: 「## 採用方式」節に方式A/Bいずれかが明記されている（#67）"
  fi
else
  fail "docs/optional-mcp-tools.md が存在する（#67）"
  skip "docs/optional-mcp-tools.md: 必須節の検査（#67）" "ファイルが存在しないためスキップ"
  skip "docs/optional-mcp-tools.md: 採用方式の検査（#67）" "ファイルが存在しないためスキップ"
fi

# ---------------------------------------------------------------------------
echo "== code-review-graph を evaluator にのみ結線する（#73） =="

# Epic #66 Phase 4（#73）: #67で確定した方式Aに従い、code-review-graphをevaluatorにのみ結線する。
# planner/generatorには一切現れないこと、未導入でも壊れないこと（.gitignore）、
# plugin.jsonが変更後もJSONとして妥当であることを機械的に検査する。

DOC73_CLAUDE_PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
DOC73_GITIGNORE="${REPO_ROOT}/.gitignore"
DOC73_EVALUATOR_ROLE="${REPO_ROOT}/core/roles/evaluator.md"
DOC73_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
DOC73_AGENT_PLANNER="${REPO_ROOT}/agents/planner.md"
DOC73_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC73_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"
DOC73_CODEX_AGENT_PLANNER="${REPO_ROOT}/codex-agents/planner.toml"
DOC73_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"

# --- .claude-plugin/plugin.json に code-review-graph の mcpServers エントリがある ---

if grep -Fq '"code-review-graph"' "$DOC73_CLAUDE_PLUGIN_JSON" \
  && grep -Fq '"command": "code-review-graph"' "$DOC73_CLAUDE_PLUGIN_JSON"; then
  pass ".claude-plugin/plugin.json: mcpServers に code-review-graph のエントリがある（#73）"
else
  fail ".claude-plugin/plugin.json: mcpServers に code-review-graph のエントリがある（#73）"
fi

# --- .claude-plugin/plugin.json が変更後もJSONとして妥当（既存の _hj_json_syntax_ok を再利用） ---

if _hj_json_syntax_ok "$DOC73_CLAUDE_PLUGIN_JSON"; then
  pass ".claude-plugin/plugin.json: 構文として妥当（括弧の対応が取れている）（#73）"
else
  fail ".claude-plugin/plugin.json: 構文として妥当（括弧の対応が取れている）（#73）" \
    "$(cat "$DOC73_CLAUDE_PLUGIN_JSON" 2>&1)"
fi

# --- .gitignore に .code-review-graph/ が追加されている ---

if grep -Fq '.code-review-graph/' "$DOC73_GITIGNORE"; then
  pass ".gitignore: .code-review-graph/ が追加されている（#73）"
else
  fail ".gitignore: .code-review-graph/ が追加されている（#73）"
fi

# --- core/roles/evaluator.md に「任意ツール: code-review-graph」節がある ---

if grep -Fq '## 任意ツール: code-review-graph' "$DOC73_EVALUATOR_ROLE" \
  && grep -Fq 'ツールがあれば使う。無ければ従来どおり' "$DOC73_EVALUATOR_ROLE" \
  && grep -Fq '発火しない' "$DOC73_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 「任意ツール: code-review-graph」節がある（#73）"
else
  fail "core/roles/evaluator.md: 「任意ツール: code-review-graph」節がある（#73）"
fi

# --- 生成物（agents/evaluator.md・codex-agents/evaluator.toml）に反映されている ---

if [ -f "$DOC73_AGENT_EVALUATOR" ] \
  && grep -Fq 'mcp__plugin_dev-workflow_code-review-graph' "$DOC73_AGENT_EVALUATOR" \
  && grep -Fq '## 任意ツール: code-review-graph' "$DOC73_AGENT_EVALUATOR"; then
  pass "agents/evaluator.md: 正本の code-review-graph 結線内容が反映されている（#73）"
else
  fail "agents/evaluator.md: 正本の code-review-graph 結線内容が反映されている（#73）" \
    "見つかりません: ${DOC73_AGENT_EVALUATOR}"
fi

if [ -f "$DOC73_CODEX_AGENT_EVALUATOR" ] \
  && grep -Fq '[mcp_servers.code-review-graph]' "$DOC73_CODEX_AGENT_EVALUATOR" \
  && grep -Fq '## 任意ツール: code-review-graph' "$DOC73_CODEX_AGENT_EVALUATOR"; then
  pass "codex-agents/evaluator.toml: 正本の code-review-graph 結線内容が反映されている（#73）"
else
  fail "codex-agents/evaluator.toml: 正本の code-review-graph 結線内容が反映されている（#73）" \
    "見つかりません: ${DOC73_CODEX_AGENT_EVALUATOR}"
fi

# --- code-review-graph（MCPツール）が evaluator にのみ与えられている（generatorには現れない） ---
# planner.md/toml は #75 で「## 準備コマンド」の例としてCLIコマンド `code-review-graph build`
# を書く（MCPツールの結線ではない）ため、この2ファイルは対象から除外し、MCPツール結線の
# 有無（mcp__plugin_..._code-review-graph という文字列）だけを別途チェックする。

for f in "$DOC73_AGENT_GENERATOR" "$DOC73_CODEX_AGENT_GENERATOR"; do
  rel="${f#"${REPO_ROOT}/"}"
  if [ -f "$f" ]; then
    if grep -Fq 'code-review-graph' "$f"; then
      fail "${rel}: code-review-graph が現れない（evaluator専用であること）（#73）" \
        "$(grep -Fn 'code-review-graph' "$f")"
    else
      pass "${rel}: code-review-graph が現れない（evaluator専用であること）（#73）"
    fi
  else
    fail "${rel}: code-review-graph が現れない（evaluator専用であること）（#73）" "見つかりません: ${f}"
  fi
done

# --- planner.md/toml には code-review-graph の「MCPツール結線」が現れない
#     （#75 の準備コマンド例としての言及 `code-review-graph build` は許容する） ---

for f in "$DOC73_AGENT_PLANNER" "$DOC73_CODEX_AGENT_PLANNER"; do
  rel="${f#"${REPO_ROOT}/"}"
  if [ -f "$f" ]; then
    if grep -Fq 'mcp__plugin_dev-workflow_code-review-graph' "$f" \
      || grep -Fq '[mcp_servers.code-review-graph]' "$f"; then
      fail "${rel}: code-review-graph のMCPツール結線が現れない（evaluator専用であること）（#73/#75）" \
        "$(grep -Fn 'code-review-graph' "$f")"
    else
      pass "${rel}: code-review-graph のMCPツール結線が現れない（evaluator専用であること）（#73/#75）"
    fi
  else
    fail "${rel}: code-review-graph のMCPツール結線が現れない（evaluator専用であること）（#73/#75）" "見つかりません: ${f}"
  fi
done

# ---------------------------------------------------------------------------
echo "== context7 を generator にのみ結線している（#71） =="

# Epic #66 Phase 3（#71）: #67 で確定した方式A（宣言方式）でcontext7を結線し、
# generatorにのみ与える（決定6）。planner / evaluatorには一切現れないことを検査する。
# Codex側はサーバー単位でしか絞れないため、絞り込み方式そのものは異なるが（詳細は
# docs/optional-mcp-tools.md「Phase 3（#71）」節）、結果として「generatorにのみ与える」ことは
# 両CLIで一致していることを検査する。

DOC71_CLAUDE_PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
DOC71_CODEX_PLUGIN_JSON="${REPO_ROOT}/.codex-plugin/plugin.json"
DOC71_MCP_DOC="${REPO_ROOT}/docs/optional-mcp-tools.md"
DOC71_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC71_AGENT_PLANNER="${REPO_ROOT}/agents/planner.md"
DOC71_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
DOC71_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"
DOC71_CODEX_AGENT_PLANNER="${REPO_ROOT}/codex-agents/planner.toml"
DOC71_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"

# --- .claude-plugin/plugin.json が方式Aどおりcontext7を宣言しており、変更後もJSONとして妥当 ---

if _hj_json_syntax_ok "$DOC71_CLAUDE_PLUGIN_JSON"; then
  pass ".claude-plugin/plugin.json: 変更後もJSON構文として妥当（括弧の対応が取れている）（#71）"
else
  fail ".claude-plugin/plugin.json: 変更後もJSON構文として妥当（括弧の対応が取れている）（#71）" \
    "$(cat "$DOC71_CLAUDE_PLUGIN_JSON" 2>&1)"
fi

if grep -Fq '"mcpServers"' "$DOC71_CLAUDE_PLUGIN_JSON" && grep -Fq '"context7"' "$DOC71_CLAUDE_PLUGIN_JSON"; then
  pass ".claude-plugin/plugin.json: mcpServersにcontext7が宣言されている（方式A）（#71）"
else
  fail ".claude-plugin/plugin.json: mcpServersにcontext7が宣言されている（方式A）（#71）"
fi

# --- context7のツールがgeneratorにのみ与えられている（Claude Code版） ---

if grep -Fq 'mcp__plugin_dev-workflow_context7__resolve-library-id' "$DOC71_AGENT_GENERATOR" \
  && grep -Fq 'mcp__plugin_dev-workflow_context7__query-docs' "$DOC71_AGENT_GENERATOR"; then
  pass "agents/generator.md: context7の2ツール（resolve-library-id / query-docs）がtools:にある（#71）"
else
  fail "agents/generator.md: context7の2ツール（resolve-library-id / query-docs）がtools:にある（#71）" \
    "見つかりません: ${DOC71_AGENT_GENERATOR}"
fi

for f in "$DOC71_AGENT_PLANNER" "$DOC71_AGENT_EVALUATOR"; do
  label="agents/$(basename "$f")"
  if grep -Fq 'context7' "$f"; then
    fail "${label}: context7が現れない（#71）" "見つかりました: ${f}"
  else
    pass "${label}: context7が現れない（#71）"
  fi
done

# --- context7のツールがgeneratorにのみ与えられている（Codex版） ---

if grep -Fq 'mcp_servers.context7' "$DOC71_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: mcp_servers.context7が宣言されている（#71）"
else
  fail "codex-agents/generator.toml: mcp_servers.context7が宣言されている（#71）" \
    "見つかりません: ${DOC71_CODEX_AGENT_GENERATOR}"
fi

for f in "$DOC71_CODEX_AGENT_PLANNER" "$DOC71_CODEX_AGENT_EVALUATOR"; do
  label="codex-agents/$(basename "$f")"
  if grep -Fq 'context7' "$f"; then
    fail "${label}: context7が現れない（#71）" "見つかりました: ${f}"
  else
    pass "${label}: context7が現れない（#71）"
  fi
done

# --- .codex-plugin/plugin.json にはcontext7を宣言しない（宣言すると全サブエージェントに継承されるため） ---

if grep -Fq 'context7' "$DOC71_CODEX_PLUGIN_JSON"; then
  fail ".codex-plugin/plugin.json: context7を宣言していない（宣言するとplanner/evaluatorにも継承されるため）（#71）"
else
  pass ".codex-plugin/plugin.json: context7を宣言していない（宣言するとplanner/evaluatorにも継承されるため）（#71）"
fi

# --- Claude/Codex間の機能差が無い（同等にできない場合はdocsに理由が明記されている） ---

if grep -Fq '## Phase 3（#71）' "$DOC71_MCP_DOC" \
  && grep -Fq 'Codex にはサブエージェント単位でMCPの「ツール名」を絞り込む機構が無い' "$DOC71_MCP_DOC"; then
  pass "docs/optional-mcp-tools.md: Codex側で同等にできない理由と回避策が明記されている（#71）"
else
  fail "docs/optional-mcp-tools.md: Codex側で同等にできない理由と回避策が明記されている（#71）"
fi

# ---------------------------------------------------------------------------
echo "== generator の規約に context7 の使いどころを追加（#72） =="

# #71 の結線だけではgeneratorはcontext7を使わないため、正本に「いつ使うか」を明記する。
# 完了条件の3点（推測禁止・未導入時の従来動作・ラダー2段目との優先関係）と、
# 生成物への反映を検査する。

DOC72_GENERATOR_ROLE="${REPO_ROOT}/core/roles/generator.md"
DOC72_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC72_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"

# --- 「未知のライブラリ／バージョン依存のAPIは推測で書かずcontext7で確認する」旨が明記されている ---

if grep -Fq '未知のライブラリ' "$DOC72_GENERATOR_ROLE" \
  && grep -Fq 'バージョン依存の API' "$DOC72_GENERATOR_ROLE" \
  && grep -Fq '推測で書かない' "$DOC72_GENERATOR_ROLE" \
  && grep -Fq 'context7' "$DOC72_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 未知のライブラリ／バージョン依存のAPIは推測で書かずcontext7で確認する旨が明記されている（#72）"
else
  fail "core/roles/generator.md: 未知のライブラリ／バージョン依存のAPIは推測で書かずcontext7で確認する旨が明記されている（#72）"
fi

# --- 「未導入なら従来どおり動く」旨が明記されている（必須依存として書かれていないこと） ---

if grep -Fq '未導入なら従来どおり動く' "$DOC72_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 「未導入なら従来どおり動く」旨が明記されている（#72）"
else
  fail "core/roles/generator.md: 「未導入なら従来どおり動く」旨が明記されている（#72）"
fi

if grep -Eiq 'context7[^。\n]*(必ず使う|使わなければならない|使うこと)' "$DOC72_GENERATOR_ROLE"; then
  fail "core/roles/generator.md: context7 を必須依存として書いていない（#72）" \
    "$(grep -EinB1 'context7[^。]*(必ず使う|使わなければならない|使うこと)' "$DOC72_GENERATOR_ROLE")"
else
  pass "core/roles/generator.md: context7 を必須依存として書いていない（#72）"
fi

# --- 「既にコードベースで使われている用法は既存箇所を読む方が優先」旨が明記されている（ラダー2段目との整合） ---

if grep -Fq '既存箇所を読む方が' "$DOC72_GENERATOR_ROLE" \
  && grep -Fq 'このコードベースに既にあるか？' "$DOC72_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 既存箇所を読む方が優先（ラダー2段目との整合）である旨が明記されている（#72）"
else
  fail "core/roles/generator.md: 既存箇所を読む方が優先（ラダー2段目との整合）である旨が明記されている（#72）"
fi

# --- 生成物（agents/generator.md・codex-agents/generator.toml）に正本の追記内容が反映されている ---

if [ -f "$DOC72_AGENT_GENERATOR" ] \
  && grep -Fq '未知のライブラリ' "$DOC72_AGENT_GENERATOR" \
  && grep -Fq '未導入なら従来どおり動く' "$DOC72_AGENT_GENERATOR" \
  && grep -Fq '既存箇所を読む方が' "$DOC72_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本（core/roles/generator.md）のcontext7使いどころ追記内容が反映されている（#72）"
else
  fail "agents/generator.md: 正本（core/roles/generator.md）のcontext7使いどころ追記内容が反映されている（#72）" \
    "見つかりません: ${DOC72_AGENT_GENERATOR}"
fi

if [ -f "$DOC72_CODEX_AGENT_GENERATOR" ] \
  && grep -Fq '未知のライブラリ' "$DOC72_CODEX_AGENT_GENERATOR" \
  && grep -Fq '未導入なら従来どおり動く' "$DOC72_CODEX_AGENT_GENERATOR" \
  && grep -Fq '既存箇所を読む方が' "$DOC72_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: 正本のcontext7使いどころ追記内容が反映されている（#72）"
else
  fail "codex-agents/generator.toml: 正本のcontext7使いどころ追記内容が反映されている（#72）" \
    "見つかりません: ${DOC72_CODEX_AGENT_GENERATOR}"
fi

echo "== Epic一括レビューに「変更50ファイル超」しきい値の3分岐を入れる（#74） =="

# Epic #66 Phase 4（#74）: R1起動前の変更ファイル数しきい値を、既存の「変更50ファイル超」に
# 相乗りさせて3分岐（<=50は従来どおり / >50かつ利用可能ならblast radius / >50かつ未導入なら
# 従来どおりPhase分割）にする。新しいしきい値の軸を増やさないこと、Claude版とCodex版で
# 機能差を作らないこと（決定3）を検査する。

DOC74_RUN_SKILL="${REPO_ROOT}/skills/run/SKILL.md"
DOC74_CODEX_RUN_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"

# --- skills/run/SKILL.md: 3分岐（<=50 / >50かつ利用可能 / >50かつ未導入）が記述されている ---

if grep -Fq '<= 50' "$DOC74_RUN_SKILL" \
  && grep -Fq '従来どおり' "$DOC74_RUN_SKILL" \
  && grep -Fq 'code-review-graphが利用可能' "$DOC74_RUN_SKILL" \
  && grep -Fq 'blast radius' "$DOC74_RUN_SKILL" \
  && grep -Fq 'code-review-graphが未導入' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: 変更ファイル数50を境にした3分岐が記述されている（#74）"
else
  fail "skills/run/SKILL.md: 変更ファイル数50を境にした3分岐が記述されている（#74）"
fi

# --- skills/run/SKILL.md: 未導入ならPhase分割にフォールバックする旨が明記されている ---

if grep -Fq '未導入' "$DOC74_RUN_SKILL" && grep -Fq 'Phase単位に分割して起動する' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: code-review-graph未導入ならPhase分割にフォールバックする旨が明記されている（#74）"
else
  fail "skills/run/SKILL.md: code-review-graph未導入ならPhase分割にフォールバックする旨が明記されている（#74）"
fi

# --- skills/run/SKILL.md: 「新しいしきい値の軸は増やさない」旨が明記され、しきい値が50のみである ---

if grep -Fq '新しいしきい値の軸は増やさず' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: 新しいしきい値の軸を増やさない旨が明記されている（#74）"
else
  fail "skills/run/SKILL.md: 新しいしきい値の軸を増やさない旨が明記されている（#74）"
fi

DOC74_THRESHOLD_NUMBERS="$(grep -oE '[0-9]+ファイル超' "$DOC74_RUN_SKILL" | sort -u)"
if [ "$DOC74_THRESHOLD_NUMBERS" = "50ファイル超" ]; then
  pass "skills/run/SKILL.md: 「Xファイル超」しきい値が50のみである（新しい軸が増えていない）（#74）"
else
  fail "skills/run/SKILL.md: 「Xファイル超」しきい値が50のみである（新しい軸が増えていない）（#74）" \
    "検出したしきい値: ${DOC74_THRESHOLD_NUMBERS}"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 同等の3分岐が記述されている（決定3: 機能差を作らない） ---

if grep -Fq '<= 50' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq '従来どおり' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'code-review-graph が利用可能' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'blast radius' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'code-review-graph が未導入' "$DOC74_CODEX_RUN_SKILL"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: 変更ファイル数50を境にした3分岐が記述されている（#74）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: 変更ファイル数50を境にした3分岐が記述されている（#74）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 未導入ならPhase分割にフォールバックする旨が明記されている ---

if grep -Fq '未導入' "$DOC74_CODEX_RUN_SKILL" && grep -Fq 'R1 を Phase 単位に分割して起動する' "$DOC74_CODEX_RUN_SKILL"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: code-review-graph未導入ならPhase分割にフォールバックする旨が明記されている（#74）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: code-review-graph未導入ならPhase分割にフォールバックする旨が明記されている（#74）"
fi

# --- Claude版とCodex版で分岐の有無が一致している（決定3: 機能差を作らない） ---

DOC74_CLAUDE_HAS_SECTION="no"
DOC74_CODEX_HAS_SECTION="no"
grep -Fq '### レビュー粒度の調整' "$DOC74_RUN_SKILL" && DOC74_CLAUDE_HAS_SECTION="yes"
grep -Fq '### レビュー粒度の調整' "$DOC74_CODEX_RUN_SKILL" && DOC74_CODEX_HAS_SECTION="yes"

if [ "$DOC74_CLAUDE_HAS_SECTION" = "yes" ] && [ "$DOC74_CODEX_HAS_SECTION" = "yes" ]; then
  pass "skills/run/SKILL.md と skills-codex/dev-workflow-run/SKILL.md の両方に「レビュー粒度の調整」節があり分岐の有無が一致する（#74）"
else
  fail "skills/run/SKILL.md と skills-codex/dev-workflow-run/SKILL.md の両方に「レビュー粒度の調整」節があり分岐の有無が一致する（#74）" \
    "claude=${DOC74_CLAUDE_HAS_SECTION} codex=${DOC74_CODEX_HAS_SECTION}"
fi

# --- しきい値の値は既存記述と同じ50であり、Codex版側にも50以外の新しい軸が増えていない ---

DOC74_CODEX_THRESHOLD_NUMBERS="$(grep -oE '[0-9]+ファイル超' "$DOC74_CODEX_RUN_SKILL" | sort -u)"
if [ "$DOC74_CODEX_THRESHOLD_NUMBERS" = "50ファイル超" ]; then
  pass "skills-codex/dev-workflow-run/SKILL.md: 「Xファイル超」しきい値が50のみである（新しい軸が増えていない）（#74）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: 「Xファイル超」しきい値が50のみである（新しい軸が増えていない）（#74）" \
    "検出したしきい値: ${DOC74_CODEX_THRESHOLD_NUMBERS}"
fi

echo "== CHANGED_FILESのしきい値算出がベースブランチを決め打ちしない（#81） =="

# レビュー指摘 #81: 「変更50ファイル超」しきい値算出（#74）が
# `git diff --name-only master...` とベースブランチを決め打ちしていた。dev-workflowは
# 他プロジェクトを駆動するプラグインでありSKILL.mdは駆動先で実行されるテンプレートなので、
# dev-workflow自身のリポジトリ固有の値（master）を埋め込んではならない。
# また `git diff | wc -l` のパイプはgit diffの失敗を握り潰し0に化けさせるため、
# 失敗時にPhase単位分割へ安全側フォールバックできるよう終了コードを直接見る形にする。

# --- skills/run/SKILL.md: `master...` によるベースブランチ決め打ちが残っていない ---

if grep -Eq 'git diff --name-only master\.\.\.' "$DOC74_RUN_SKILL"; then
  fail "skills/run/SKILL.md: CHANGED_FILES算出がmasterブランチを決め打ちしていない（#81）" \
    "'git diff --name-only master...' が残っている"
else
  pass "skills/run/SKILL.md: CHANGED_FILES算出がmasterブランチを決め打ちしていない（#81）"
fi

# --- skills/run/SKILL.md: ベースブランチを動的に解決している（gh repo view で駆動先の実際の値を使う） ---

if grep -Fq 'gh repo view --json defaultBranchRef' "$DOC74_RUN_SKILL" \
  && grep -Fq 'BASE_BRANCH' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: ベースブランチをgh repo viewで動的に解決している（#81）"
else
  fail "skills/run/SKILL.md: ベースブランチをgh repo viewで動的に解決している（#81）"
fi

# --- skills/run/SKILL.md: git diffをwc -lへ直接パイプしていない（失敗を握り潰さない） ---

if grep -Eq 'git diff --name-only "\$\{BASE_BRANCH\}\.\.\.\$\{EPIC_BRANCH\}" \| wc -l' "$DOC74_RUN_SKILL"; then
  fail "skills/run/SKILL.md: git diffの失敗がwc -lで握り潰されない（#81）" \
    "git diffの出力を直接wc -lにパイプしている箇所が残っている"
else
  pass "skills/run/SKILL.md: git diffの失敗がwc -lで握り潰されない（#81）"
fi

# --- skills/run/SKILL.md: git diff失敗時に「数えられなかった」旨を出しPhase分割へ倒す記述がある ---

if grep -Fq '数えられなかった' "$DOC74_RUN_SKILL" \
  && grep -Fq 'Phase単位分割にフォールバックする' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: git diff失敗時にPhase単位分割へフォールバックする旨が明記されている（#81）"
else
  fail "skills/run/SKILL.md: git diff失敗時にPhase単位分割へフォールバックする旨が明記されている（#81）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 同様にmaster決め打ちが残っていない（決定3: 機能差を作らない） ---

if grep -Eq 'git diff --name-only master\.\.\.' "$DOC74_CODEX_RUN_SKILL"; then
  fail "skills-codex/dev-workflow-run/SKILL.md: CHANGED_FILES算出がmasterブランチを決め打ちしていない（#81）" \
    "'git diff --name-only master...' が残っている"
else
  pass "skills-codex/dev-workflow-run/SKILL.md: CHANGED_FILES算出がmasterブランチを決め打ちしていない（#81）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: ベースブランチを動的に解決している ---

if grep -Fq 'gh repo view --json defaultBranchRef' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'BASE_BRANCH' "$DOC74_CODEX_RUN_SKILL"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: ベースブランチをgh repo viewで動的に解決している（#81）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: ベースブランチをgh repo viewで動的に解決している（#81）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: git diffをwc -lへ直接パイプしていない ---

if grep -Eq 'git diff --name-only "\$\{BASE_BRANCH\}\.\.\.\$\{EPIC_BRANCH\}" \| wc -l' "$DOC74_CODEX_RUN_SKILL"; then
  fail "skills-codex/dev-workflow-run/SKILL.md: git diffの失敗がwc -lで握り潰されない（#81）" \
    "git diffの出力を直接wc -lにパイプしている箇所が残っている"
else
  pass "skills-codex/dev-workflow-run/SKILL.md: git diffの失敗がwc -lで握り潰されない（#81）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: git diff失敗時のフォールバック記述がある ---

if grep -Fq '数えられなかった' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'Phase 単位分割にフォールバックする' "$DOC74_CODEX_RUN_SKILL"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: git diff失敗時にPhase単位分割へフォールバックする旨が明記されている（#81）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: git diff失敗時にPhase単位分割へフォールバックする旨が明記されている（#81）"
fi

# --- 「Xファイル超」しきい値が依然として50のみである（#81の修正でしきい値の軸が増えていない） ---

DOC81_THRESHOLD_NUMBERS="$(grep -oE '[0-9]+ファイル超' "$DOC74_RUN_SKILL" | sort -u)"
if [ "$DOC81_THRESHOLD_NUMBERS" = "50ファイル超" ]; then
  pass "skills/run/SKILL.md: #81修正後も「Xファイル超」しきい値が50のみである（#81）"
else
  fail "skills/run/SKILL.md: #81修正後も「Xファイル超」しきい値が50のみである（#81）" \
    "検出したしきい値: ${DOC81_THRESHOLD_NUMBERS}"
fi

DOC81_CODEX_THRESHOLD_NUMBERS="$(grep -oE '[0-9]+ファイル超' "$DOC74_CODEX_RUN_SKILL" | sort -u)"
if [ "$DOC81_CODEX_THRESHOLD_NUMBERS" = "50ファイル超" ]; then
  pass "skills-codex/dev-workflow-run/SKILL.md: #81修正後も「Xファイル超」しきい値が50のみである（#81）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: #81修正後も「Xファイル超」しきい値が50のみである（#81）" \
    "検出したしきい値: ${DOC81_CODEX_THRESHOLD_NUMBERS}"
fi

echo "== グラフ構築をEpic開始時の準備に載せ限界を明記する（#75） =="

# Epic #66 Phase 4（#75）: code-review-graphのグラフ構築はEpic開始時に1回だけ、
# 既存の「## 準備コマンド」節（issue #23）に載せる。evaluator自身はグラフを構築しない。
# markdown + bash主体のリポジトリ（dev-workflow自身）では発火しないのが正常である旨を
# core/roles/evaluator.mdとdocs/optional-mcp-tools.mdの両方に明記する。

DOC75_EVALUATOR_ROLE="${REPO_ROOT}/core/roles/evaluator.md"
DOC75_PLANNER_ROLE="${REPO_ROOT}/core/roles/planner.md"
DOC75_OPTIONAL_MCP_DOC="${REPO_ROOT}/docs/optional-mcp-tools.md"
DOC75_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
DOC75_AGENT_PLANNER="${REPO_ROOT}/agents/planner.md"
DOC75_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"
DOC75_CODEX_AGENT_PLANNER="${REPO_ROOT}/codex-agents/planner.toml"

# --- core/roles/evaluator.md: 「epic-review かつ変更50ファイル超のときだけ使う」旨 ---

if grep -Fq 'epic-review かつ変更50ファイル超のときだけ' "$DOC75_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: epic-reviewかつ変更50ファイル超のときだけ使う旨が明記されている（#75）"
else
  fail "core/roles/evaluator.md: epic-reviewかつ変更50ファイル超のときだけ使う旨が明記されている（#75）"
fi

# --- core/roles/evaluator.md: 「evaluator自身はグラフを構築しない」旨 ---

if grep -Fq 'evaluator 自身はグラフを構築しない' "$DOC75_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: evaluator自身はグラフを構築しない旨が明記されている（#75）"
else
  fail "core/roles/evaluator.md: evaluator自身はグラフを構築しない旨が明記されている（#75）"
fi

# --- core/roles/evaluator.md: グラフの出力をそのまま指摘にしない旨 ---

if grep -Fq 'グラフの出力をそのまま指摘にしない' "$DOC75_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: グラフの出力をそのまま指摘にしない旨が明記されている（#75）"
else
  fail "core/roles/evaluator.md: グラフの出力をそのまま指摘にしない旨が明記されている（#75）"
fi

# --- core/roles/evaluator.md と docs/optional-mcp-tools.md の両方に
#     「markdown + bash 主体のリポジトリ...発火しないのが正常」の限界が明記されている ---

if grep -Fq 'markdown + bash 主体のリポジトリ' "$DOC75_EVALUATOR_ROLE" \
  && grep -Fq '発火しないのが正常' "$DOC75_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: markdown + bash主体のリポジトリでは発火しないのが正常という限界が明記されている（#75）"
else
  fail "core/roles/evaluator.md: markdown + bash主体のリポジトリでは発火しないのが正常という限界が明記されている（#75）"
fi

if grep -Fq 'markdown + bash 主体のリポジトリ' "$DOC75_OPTIONAL_MCP_DOC" \
  && grep -Fq '発火しないのが正常' "$DOC75_OPTIONAL_MCP_DOC"; then
  pass "docs/optional-mcp-tools.md: markdown + bash主体のリポジトリでは発火しないのが正常という限界が明記されている（#75）"
else
  fail "docs/optional-mcp-tools.md: markdown + bash主体のリポジトリでは発火しないのが正常という限界が明記されている（#75）"
fi

# --- core/roles/planner.md: 「## 準備コマンド」の説明にグラフ構築コマンドの例が追加されている ---

if grep -Fq 'グラフ構築コマンド' "$DOC75_PLANNER_ROLE" \
  && grep -Fq 'code-review-graph build' "$DOC75_PLANNER_ROLE"; then
  pass "core/roles/planner.md: 準備コマンド節の説明にグラフ構築コマンドの例が追加されている（#75）"
else
  fail "core/roles/planner.md: 準備コマンド節の説明にグラフ構築コマンドの例が追加されている（#75）"
fi

# --- docs/optional-mcp-tools.md: グラフ構築はEpic開始時に1回・evaluatorは構築しない旨 ---

if grep -Fq '## 準備コマンド' "$DOC75_OPTIONAL_MCP_DOC" \
  && grep -Fq 'evaluator 自身はグラフを構築しない' "$DOC75_OPTIONAL_MCP_DOC"; then
  pass "docs/optional-mcp-tools.md: グラフ構築は準備コマンド節に載せevaluatorは構築しない旨が明記されている（#75）"
else
  fail "docs/optional-mcp-tools.md: グラフ構築は準備コマンド節に載せevaluatorは構築しない旨が明記されている（#75）"
fi

# --- 生成物: agents/evaluator.md に正本の内容が反映されている ---

if [ -f "$DOC75_AGENT_EVALUATOR" ] \
  && grep -Fq 'epic-review かつ変更50ファイル超のときだけ' "$DOC75_AGENT_EVALUATOR" \
  && grep -Fq 'evaluator 自身はグラフを構築しない' "$DOC75_AGENT_EVALUATOR" \
  && grep -Fq 'markdown + bash 主体のリポジトリ' "$DOC75_AGENT_EVALUATOR"; then
  pass "agents/evaluator.md: 正本のグラフ構築・限界の記述内容が反映されている（#75）"
else
  fail "agents/evaluator.md: 正本のグラフ構築・限界の記述内容が反映されている（#75）" \
    "見つかりません: ${DOC75_AGENT_EVALUATOR}"
fi

# --- 生成物: agents/planner.md に正本の内容が反映されている ---

if [ -f "$DOC75_AGENT_PLANNER" ] \
  && grep -Fq 'グラフ構築コマンド' "$DOC75_AGENT_PLANNER" \
  && grep -Fq 'code-review-graph build' "$DOC75_AGENT_PLANNER"; then
  pass "agents/planner.md: 正本のグラフ構築コマンド例が反映されている（#75）"
else
  fail "agents/planner.md: 正本のグラフ構築コマンド例が反映されている（#75）" \
    "見つかりません: ${DOC75_AGENT_PLANNER}"
fi

# --- 生成物: codex-agents/evaluator.toml に正本の内容が反映されている ---

if [ -f "$DOC75_CODEX_AGENT_EVALUATOR" ] \
  && grep -Fq 'epic-review かつ変更50ファイル超のときだけ' "$DOC75_CODEX_AGENT_EVALUATOR" \
  && grep -Fq 'evaluator 自身はグラフを構築しない' "$DOC75_CODEX_AGENT_EVALUATOR" \
  && grep -Fq 'markdown + bash 主体のリポジトリ' "$DOC75_CODEX_AGENT_EVALUATOR"; then
  pass "codex-agents/evaluator.toml: 正本のグラフ構築・限界の記述内容が反映されている（#75）"
else
  fail "codex-agents/evaluator.toml: 正本のグラフ構築・限界の記述内容が反映されている（#75）" \
    "見つかりません: ${DOC75_CODEX_AGENT_EVALUATOR}"
fi

# --- 生成物: codex-agents/planner.toml に正本の内容が反映されている ---

if [ -f "$DOC75_CODEX_AGENT_PLANNER" ] \
  && grep -Fq 'グラフ構築コマンド' "$DOC75_CODEX_AGENT_PLANNER" \
  && grep -Fq 'code-review-graph build' "$DOC75_CODEX_AGENT_PLANNER"; then
  pass "codex-agents/planner.toml: 正本のグラフ構築コマンド例が反映されている（#75）"
else
  fail "codex-agents/planner.toml: 正本のグラフ構築コマンド例が反映されている（#75）" \
    "見つかりません: ${DOC75_CODEX_AGENT_PLANNER}"
fi

# ---------------------------------------------------------------------------
echo "== scripts/record-agent-tokens.sh（サブエージェントのトークン消費記録・集計。#76） =="
# ---------------------------------------------------------------------------

# Epic #66 Phase 5（#76）: 導入前後のサブエージェントトークン消費を記録・集計する仕組み。
# jq等の追加依存を使わず素のbashで完結すること、記録先が git 管理外であること、
# 不正入力は明快なエラーで非0終了することを検査する。

RAT_SCRIPT="${REPO_ROOT}/scripts/record-agent-tokens.sh"
RAT_TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-agent-tokens.XXXXXX")"
RAT_FILE="${RAT_TESTDIR}/agent-tokens.tsv"

# --- 静的検査: jq等の追加依存を呼んでいない（コメント行は対象外。単語境界での一致のみ見る） ---

RAT_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$RAT_SCRIPT" \
  | grep -E '(^|[^A-Za-z0-9_])jq([^A-Za-z0-9_]|$)' || true)"
if [ -z "$RAT_FORBIDDEN_HITS" ]; then
  pass "record-agent-tokens.sh: スクリプト本体が jq を呼んでいない（#76）"
else
  fail "record-agent-tokens.sh: スクリプト本体が jq を呼んでいない（#76）" "$RAT_FORBIDDEN_HITS"
fi

# --- record: 追記した内容がTSVとして読み戻せる（6列） ---

RAT_RECORD_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role generator --mode "タスク実装" --tokens 90000 --note "dryrun" 2>&1)"
RAT_RECORD_EXIT=$?
assert_exit_code "record-agent-tokens.sh record: 正常入力は exit 0（#76）" 0 "$RAT_RECORD_EXIT"

if [ -f "$RAT_FILE" ]; then
  RAT_LINE="$(tail -n 1 "$RAT_FILE")"
  RAT_COL_COUNT="$(printf '%s' "$RAT_LINE" | awk -F'\t' '{print NF}')"
  assert_eq "record-agent-tokens.sh record: TSVが6列で書かれる（#76）" "6" "$RAT_COL_COUNT"

  RAT_EPIC_COL="$(printf '%s' "$RAT_LINE" | cut -f2)"
  RAT_ROLE_COL="$(printf '%s' "$RAT_LINE" | cut -f3)"
  RAT_MODE_COL="$(printf '%s' "$RAT_LINE" | cut -f4)"
  RAT_TOKENS_COL="$(printf '%s' "$RAT_LINE" | cut -f5)"
  RAT_NOTE_COL="$(printf '%s' "$RAT_LINE" | cut -f6)"
  if [ "$RAT_EPIC_COL" = "76" ] && [ "$RAT_ROLE_COL" = "generator" ] \
    && [ "$RAT_MODE_COL" = "タスク実装" ] && [ "$RAT_TOKENS_COL" = "90000" ] \
    && [ "$RAT_NOTE_COL" = "dryrun" ]; then
    pass "record-agent-tokens.sh record: 各列の値が正しく読み戻せる（#76）"
  else
    fail "record-agent-tokens.sh record: 各列の値が正しく読み戻せる（#76）" \
      "epic=${RAT_EPIC_COL} role=${RAT_ROLE_COL} mode=${RAT_MODE_COL} tokens=${RAT_TOKENS_COL} note=${RAT_NOTE_COL}"
  fi
else
  fail "record-agent-tokens.sh record: TSVが6列で書かれる（#76）" "${RAT_FILE} が作られていません"
  fail "record-agent-tokens.sh record: 各列の値が正しく読み戻せる（#76）" "${RAT_FILE} が作られていません"
fi

# --- record: --note を省略しても6列で書かれる（noteは空文字列） ---

DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role evaluator --mode "epic-review" --tokens 139000 >/dev/null 2>&1
RAT_LINE2="$(tail -n 1 "$RAT_FILE")"
RAT_COL_COUNT2="$(printf '%s' "$RAT_LINE2" | awk -F'\t' '{print NF}')"
assert_eq "record-agent-tokens.sh record: --note省略時も6列で書かれる（#76）" "6" "$RAT_COL_COUNT2"

# --- record: 複数レコードを追記できる（1行1レコード。追記であって上書きではない） ---

RAT_TOTAL_LINES="$(wc -l < "$RAT_FILE" | tr -d ' ')"
assert_eq "record-agent-tokens.sh record: 1行1レコードで追記される（#76）" "2" "$RAT_TOTAL_LINES"

# --- --summary: role・modeごとの件数・合計・平均を出力する ---

DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role generator --mode "タスク実装" --tokens 150000 >/dev/null 2>&1
RAT_SUMMARY_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" bash "$RAT_SCRIPT" --summary --epic 76 2>&1)"
RAT_SUMMARY_EXIT=$?
assert_exit_code "record-agent-tokens.sh --summary: exit 0（#76）" 0 "$RAT_SUMMARY_EXIT"

if printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "generator" \
  && printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "240000" \
  && printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "120000" \
  && printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "evaluator" \
  && printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "139000"; then
  pass "record-agent-tokens.sh --summary: role・modeごとの件数・合計・平均を出力する（#76）"
else
  fail "record-agent-tokens.sh --summary: role・modeごとの件数・合計・平均を出力する（#76）" "$RAT_SUMMARY_OUT"
fi

# --- --summary: 他のEpicのレコードは集計に混ざらない ---

RAT_OTHER_EPIC_FILE="${RAT_TESTDIR}/agent-tokens-other.tsv"
DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_OTHER_EPIC_FILE" \
  bash "$RAT_SCRIPT" record --epic 999 --role generator --mode "タスク実装" --tokens 1 >/dev/null 2>&1
RAT_ISOLATION_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_OTHER_EPIC_FILE" bash "$RAT_SCRIPT" --summary --epic 76 2>&1)"
if printf '%s' "$RAT_ISOLATION_OUT" | grep -Fq "記録が0件です"; then
  pass "record-agent-tokens.sh --summary: 指定Epic以外のレコードは集計対象外（#76）"
else
  fail "record-agent-tokens.sh --summary: 指定Epic以外のレコードは集計対象外（#76）" "$RAT_ISOLATION_OUT"
fi

# --- 不正入力: --tokens が数値でない場合は非0終了しエラーメッセージを出す ---

RAT_BAD_TOKENS_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role generator --mode x --tokens abc 2>&1)"
RAT_BAD_TOKENS_EXIT=$?
if [ "$RAT_BAD_TOKENS_EXIT" -ne 0 ] && printf '%s' "$RAT_BAD_TOKENS_OUT" | grep -Fq "数値"; then
  pass "record-agent-tokens.sh record: --tokensが数値でない場合は非0終了しエラーを出す（#76）"
else
  fail "record-agent-tokens.sh record: --tokensが数値でない場合は非0終了しエラーを出す（#76）" \
    "exit=${RAT_BAD_TOKENS_EXIT} out=${RAT_BAD_TOKENS_OUT}"
fi

# --- 不正入力: 必須オプション（--tokens）が欠けている場合は非0終了する ---

RAT_MISSING_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role generator --mode x 2>&1)"
RAT_MISSING_EXIT=$?
assert_exit_code "record-agent-tokens.sh record: 必須オプション欠落は非0終了する（#76）" 2 "$RAT_MISSING_EXIT"

# --- 不正入力: 末尾に値の無いオプションを置いても無限ループしない（ハングしない）（#79） ---
# bash の `shift 2` は $# が2未満のとき何もせず非0を返す。値なしでオプション名だけが
# 末尾に置かれた場合にこれを検出しないと while ループが同じ分岐を回り続けてハングする
# 不具合があった（実測: timeout 5 bash record-agent-tokens.sh record --epic 66 --role
# generator --mode impl --tokens は exit 124 だった。ただし sandbox 内の BusyBox timeout
# は exit 143 を返すため、終了コードのみでは「ハングして timeout に強制終了させられた」
# ことを判定できない。詳細は assert_no_hang 参照）。「必須オプション欠落」テスト（直上）
# はオプションを丸ごと省く形なのでこのケースを通り抜けていた。cmd_record の全オプション
# （--epic/--role/--mode/--tokens/--note）を、他は有効な値を与えたまま1つだけ末尾で
# 値なしにする形で網羅する。

if command -v timeout >/dev/null 2>&1; then
  RAT_NOVAL_OPTS=(--epic --role --mode --tokens --note)
  for RAT_NOVAL_OPT in "${RAT_NOVAL_OPTS[@]}"; do
    RAT_NOVAL_ARGS=(record)
    for RAT_OTHER_OPT in "${RAT_NOVAL_OPTS[@]}"; do
      [ "$RAT_OTHER_OPT" = "$RAT_NOVAL_OPT" ] && continue
      case "$RAT_OTHER_OPT" in
        --epic) RAT_NOVAL_ARGS+=(--epic 76) ;;
        --role) RAT_NOVAL_ARGS+=(--role generator) ;;
        --mode) RAT_NOVAL_ARGS+=(--mode x) ;;
        --tokens) RAT_NOVAL_ARGS+=(--tokens 1) ;;
        --note) RAT_NOVAL_ARGS+=(--note y) ;;
      esac
    done
    RAT_NOVAL_ARGS+=("$RAT_NOVAL_OPT")

    RAT_NOVAL_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
      timeout 5 bash "$RAT_SCRIPT" "${RAT_NOVAL_ARGS[@]}" 2>&1)"
    RAT_NOVAL_EXIT=$?

    assert_no_hang "record-agent-tokens.sh record: ${RAT_NOVAL_OPT}が末尾で値なしでも無限ループせず exit 2 かつエラーメッセージを出す（#79）" \
      2 "$RAT_NOVAL_EXIT" "$RAT_NOVAL_OUT" "${RAT_NOVAL_OPT} に値がありません"
  done

  RAT_SUMMARY_NOVAL_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
    timeout 5 bash "$RAT_SCRIPT" --summary --epic 2>&1)"
  RAT_SUMMARY_NOVAL_EXIT=$?

  assert_no_hang "record-agent-tokens.sh --summary: --epicが末尾で値なしでも無限ループせず exit 2 かつエラーメッセージを出す（#79）" \
    2 "$RAT_SUMMARY_NOVAL_EXIT" "$RAT_SUMMARY_NOVAL_OUT" "--epic に値がありません"
else
  skip "record-agent-tokens.sh: 末尾に値の無いオプションでも無限ループしない（#79）" "timeout コマンドが利用できません"
fi

# --- 不正入力: --role が想定外の値の場合は非0終了する ---

RAT_BADROLE_EXIT_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role reviewer --mode x --tokens 1 2>&1)"
RAT_BADROLE_EXIT=$?
if [ "$RAT_BADROLE_EXIT" -ne 0 ]; then
  pass "record-agent-tokens.sh record: --roleが想定外の値の場合は非0終了する（#76）"
else
  fail "record-agent-tokens.sh record: --roleが想定外の値の場合は非0終了する（#76）" "$RAT_BADROLE_EXIT_OUT"
fi

# --- --summary: --epic が欠けている場合は非0終了する ---

RAT_SUMMARY_NOEPIC_EXIT_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" bash "$RAT_SCRIPT" --summary 2>&1)"
RAT_SUMMARY_NOEPIC_EXIT=$?
assert_exit_code "record-agent-tokens.sh --summary: --epic欠落は非0終了する（#76）" 2 "$RAT_SUMMARY_NOEPIC_EXIT"

# --- 不正な入力の失敗は記録先ファイルを壊さない（レコード件数が増えていない） ---

RAT_LINES_AFTER_ERRORS="$(wc -l < "$RAT_FILE" | tr -d ' ')"
assert_eq "record-agent-tokens.sh: 不正入力の失敗はファイルへの書き込みを行わない（#76）" "3" "$RAT_LINES_AFTER_ERRORS"

# --- 記録先が git 管理外であること（.gitignore で除外されている） ---
# git worktree（サンドボックスや専用worktree）内では .git ファイルがホスト側の絶対パスを
# 指しており、コンテナ内から親リポジトリを解決できない環境がある（#73のcode-review-graph
# 検査と同じ理由で `git check-ignore` は使わず、.gitignore の内容を直接検査する）。

if grep -Fq '.claude/agent-tokens.tsv' "${REPO_ROOT}/.gitignore"; then
  pass "record-agent-tokens.sh: 既定の記録先（.claude/agent-tokens.tsv）が.gitignoreで除外されている（#76）"
else
  fail "record-agent-tokens.sh: 既定の記録先（.claude/agent-tokens.tsv）が.gitignoreで除外されている（#76）"
fi

# --- run への結線: skills/run/SKILL.md と skills-codex/dev-workflow-run/SKILL.md の両方に
#     record-agent-tokens.sh の呼び出しとPR本文への集計が記述されている ---

RAT_RUN_SKILL="${REPO_ROOT}/skills/run/SKILL.md"
RAT_CODEX_RUN_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"

for f in "$RAT_RUN_SKILL" "$RAT_CODEX_RUN_SKILL"; do
  name="${f#"${REPO_ROOT}"/}"
  if grep -Fq 'record-agent-tokens.sh' "$f" \
    && grep -Fq 'record-agent-tokens.sh --summary' "$f" \
    && grep -Fq 'トークン消費' "$f"; then
    pass "${name}: record-agent-tokens.shの結線とPR本文への集計が記述されている（#76）"
  else
    fail "${name}: record-agent-tokens.shの結線とPR本文への集計が記述されている（#76）"
  fi
done

# --- 呼び出し側への注記: 記録に失敗しても自律ループを止めない旨が両SKILL.mdに明記されている ---

for f in "$RAT_RUN_SKILL" "$RAT_CODEX_RUN_SKILL"; do
  name="${f#"${REPO_ROOT}"/}"
  if grep -Fq '自律ループを止めない' "$f" || grep -Fq 'ループは止めない' "$f"; then
    pass "${name}: 記録失敗が自律ループを止めない旨が明記されている（#76）"
  else
    fail "${name}: 記録失敗が自律ループを止めない旨が明記されている（#76）"
  fi
done

# --- docs/optional-mcp-tools.md: ベースライン表と「外す判断基準」が記載されている ---

RAT_DOC="${REPO_ROOT}/docs/optional-mcp-tools.md"
if grep -Fq '81k' "$RAT_DOC" && grep -Fq '150k' "$RAT_DOC" \
  && grep -Fq '83k' "$RAT_DOC" && grep -Fq '139k' "$RAT_DOC" \
  && grep -Fq 'delta-review' "$RAT_DOC" && grep -Fq 'epic-review' "$RAT_DOC"; then
  pass "docs/optional-mcp-tools.md: ベースライン表（Epic #42実測値）が記載されている（#76）"
else
  fail "docs/optional-mcp-tools.md: ベースライン表（Epic #42実測値）が記載されている（#76）"
fi

if grep -Fq '外す判断基準' "$RAT_DOC" \
  && grep -Fq 'record-agent-tokens.sh' "$RAT_DOC"; then
  pass "docs/optional-mcp-tools.md: 「外す判断基準」が明記されている（#76）"
else
  fail "docs/optional-mcp-tools.md: 「外す判断基準」が明記されている（#76）"
fi

# ---------------------------------------------------------------------------
# ドキュメント更新・v0.14.0・両アダプタ再生成（#77）
# ---------------------------------------------------------------------------

echo "== ドキュメント更新・v0.14.0・両アダプタ再生成（#77） =="

DOC77_CLAUDE_PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
DOC77_CODEX_PLUGIN_JSON="${REPO_ROOT}/.codex-plugin/plugin.json"
DOC77_README="${REPO_ROOT}/README.md"
DOC77_GUIDE="${REPO_ROOT}/docs/dev-workflow-multi-vendor-guide.md"

# --- 両 plugin.json の version が一致している（片方だけ上がる事故の検出。値そのものは固定しない） ---

DOC77_CLAUDE_VERSION="$(grep -m1 '"version"' "$DOC77_CLAUDE_PLUGIN_JSON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
DOC77_CODEX_VERSION="$(grep -m1 '"version"' "$DOC77_CODEX_PLUGIN_JSON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

if [ -n "$DOC77_CLAUDE_VERSION" ] && [ "$DOC77_CLAUDE_VERSION" = "$DOC77_CODEX_VERSION" ]; then
  pass ".claude-plugin/plugin.json と .codex-plugin/plugin.json の version が一致している（#77）"
else
  fail ".claude-plugin/plugin.json と .codex-plugin/plugin.json の version が一致している（#77）" \
    "claude=[${DOC77_CLAUDE_VERSION}] codex=[${DOC77_CODEX_VERSION}]"
fi

assert_eq "両plugin.jsonのversionが0.14.0である（#77）" "0.14.0" "$DOC77_CLAUDE_VERSION"

# --- README.md に「任意依存の外部ツール」節があり、4点（任意依存・未導入時の挙動・入れ方・外す基準）が書かれている ---

if grep -Fq '## 任意依存の外部ツール' "$DOC77_README"; then
  pass "README.md: 「任意依存の外部ツール」節がある（#77）"
else
  fail "README.md: 「任意依存の外部ツール」節がある（#77）"
fi

if grep -Fq '必須依存ではありません' "$DOC77_README"; then
  pass "README.md: 任意依存であり必須依存ではない旨が明記されている（#77）"
else
  fail "README.md: 任意依存であり必須依存ではない旨が明記されている（#77）"
fi

if grep -Fq 'context7 で確認しません' "$DOC77_README" && grep -Fq 'blast radius' "$DOC77_README" \
  && grep -Fq 'Phase 単位に分割' "$DOC77_README"; then
  pass "README.md: 未導入時にcontext7/code-review-graphがどう動かないかが明記されている（#77）"
else
  fail "README.md: 未導入時にcontext7/code-review-graphがどう動かないかが明記されている（#77）"
fi

# --- README に「未導入でも従来どおり動く」旨の記述がある ---

if grep -Fq '入れなくても dev-workflow は従来どおり動作します' "$DOC77_README" \
  || grep -Fq 'いずれもワークフローを止めません' "$DOC77_README"; then
  pass "README.md: 「未導入でも従来どおり動く」旨の記述がある（#77）"
else
  fail "README.md: 「未導入でも従来どおり動く」旨の記述がある（#77）"
fi

if grep -Fq 'optional-mcp-tools.md' "$DOC77_README"; then
  pass "README.md: 入れ方としてdocs/optional-mcp-tools.mdを参照している（#77）"
else
  fail "README.md: 入れ方としてdocs/optional-mcp-tools.mdを参照している（#77）"
fi

if grep -Fq '外す判断基準' "$DOC77_README"; then
  pass "README.md: 「外す判断基準」への参照がある（#77）"
else
  fail "README.md: 「外す判断基準」への参照がある（#77）"
fi

# --- README.md に ponytail のラダー・出典（MIT）・テスト対象外の旨が書かれている ---

if grep -Fq 'DietrichGebert/ponytail' "$DOC77_README" && grep -Fq 'MIT' "$DOC77_README" \
  && grep -Fq '7段の判断ラダー' "$DOC77_README"; then
  pass "README.md: ponytailのラダーと出典（MIT）が明記されている（#77）"
else
  fail "README.md: ponytailのラダーと出典（MIT）が明記されている（#77）"
fi

if grep -Fq 'テスト・回帰確認・検証・セキュリティは削減対象外' "$DOC77_README"; then
  pass "README.md: テスト・検証・安全性は削減対象外である旨が明記されている（#77）"
else
  fail "README.md: テスト・検証・安全性は削減対象外である旨が明記されている（#77）"
fi

# --- docs/dev-workflow-multi-vendor-guide.md にClaude/Codex双方の任意依存の扱いが書かれている ---

if grep -Fq '任意依存の外部 MCP ツール' "$DOC77_GUIDE" \
  && grep -Fq 'ツール単位' "$DOC77_GUIDE" && grep -Fq 'サーバー単位' "$DOC77_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: Claude/Codexの設定場所の違いが書かれている（#77）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: Claude/Codexの設定場所の違いが書かれている（#77）"
fi

if grep -Fq '機能差は無い' "$DOC77_GUIDE" && grep -Fq '同等にできない箇所' "$DOC77_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: 機能差の有無と同等にできない箇所の理由・回避策が書かれている（#77）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: 機能差の有無と同等にできない箇所の理由・回避策が書かれている（#77）"
fi

# ---------------------------------------------------------------------------
echo "== docs/dev-workflow-multi-vendor-guide.md の節参照が参照先ファイルに実在する（レビュー#84） =="

# レビュー指摘 #84: ガイドが「正本はそちら」として案内する節見出しが、実際には参照先ファイルに
# 存在しないケース（`core/roles/generator.md`ではなく`docs/optional-mcp-tools.md`にある節を
# 誤って`core/roles/generator.md`と案内していた）が見つかった。ドキュメント自体が成果物である
# このリポジトリでは参照切れが再発しうるため、`` `ファイル名.md` 「見出しテキスト」節 `` という
# 形式で書かれた参照をガイドから機械的に抽出し、参照先ファイルに同名の見出し（`#`〜`######`の
# いずれか）が実在することを検査する。新たに同形式の参照を追加した場合も自動的に対象になる。

DOC84_GUIDE="${REPO_ROOT}/docs/dev-workflow-multi-vendor-guide.md"

# ガイド全文を1行に連結してから抽出する（参照が改行を挟んで書かれていることがあるため）。
DOC84_REFS="$(tr '\n' ' ' < "$DOC84_GUIDE" | grep -oE '`[A-Za-z0-9_./-]+\.md`[[:space:]]*「[^」]+」節' | sort -u)"

if [ -z "$DOC84_REFS" ]; then
  fail "docs/dev-workflow-multi-vendor-guide.md: 節参照の抽出パターンが1件も見つからない（テスト自体が空振りしていないか）（#84）"
else
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    ref_file="$(printf '%s' "$ref" | grep -oE '^`[A-Za-z0-9_./-]+\.md`' | tr -d '`')"
    ref_heading="$(printf '%s' "$ref" | grep -oE '「[^」]+」節$' | sed -E 's/^「//; s/」節$//')"
    ref_target="${REPO_ROOT}/${ref_file}"

    if [ ! -f "$ref_target" ]; then
      fail "docs/dev-workflow-multi-vendor-guide.md: 参照先ファイルが実在する（#84）" \
        "参照=[${ref_file}] 見つかりません"
      continue
    fi

    ref_found=0
    for level in 1 2 3 4 5 6; do
      prefix="$(printf '#%.0s' $(seq 1 "$level"))"
      if grep -Fxq "${prefix} ${ref_heading}" "$ref_target"; then
        ref_found=1
        break
      fi
    done

    if [ "$ref_found" -eq 1 ]; then
      pass "docs/dev-workflow-multi-vendor-guide.md: 「${ref_heading}」節が ${ref_file} に実在する（#84）"
    else
      fail "docs/dev-workflow-multi-vendor-guide.md: 「${ref_heading}」節が ${ref_file} に実在する（#84）" \
        "参照先=[${ref_file}] 見出し=[${ref_heading}] が見つかりません"
    fi
  done <<< "$DOC84_REFS"
fi

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
