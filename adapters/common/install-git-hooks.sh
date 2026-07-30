#!/bin/bash
# dev-workflow: 可読性ガードを git の pre-commit フックに設置する
#
# 各CLIのフック機構とは別に、git 側にも強制点を置くことでベンダー非依存にする。
# CLIのフックが即時フィードバック（編集直後のブロック）を担い、
# こちらは「どのツールから編集されてもコミットは通さない」最終防衛線になる。
#
# 使い方:
#   bash adapters/common/install-git-hooks.sh [プロジェクトパス]
#   bash adapters/common/install-git-hooks.sh --uninstall [プロジェクトパス]
#
# 既存の pre-commit がある場合は上書きせず、dev-workflow の呼び出し行を追記する。

set -euo pipefail

MARKER_BEGIN="# >>> dev-workflow readability guard >>>"
MARKER_END="# <<< dev-workflow readability guard <<<"

UNINSTALL=0
if [ "${1:-}" = "--uninstall" ]; then
  UNINSTALL=1
  shift
fi

PROJECT_ROOT="${1:-.}"
GUARD_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/check-readability.sh"

if [ ! -f "$GUARD_SCRIPT" ]; then
  echo "ERROR: 可読性ガードが見つかりません: ${GUARD_SCRIPT}" >&2
  exit 1
fi

# gitリポジトリであることと、フックの置き場所を確認する。
# worktree では .git がファイルなので rev-parse に解決させる。
if ! HOOKS_DIR="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)"; then
  echo "ERROR: gitリポジトリではありません: ${PROJECT_ROOT}" >&2
  exit 1
fi

HOOK_FILE="${HOOKS_DIR}/pre-commit"

# ── アンインストール ─────────────────────────────────────────────────
if [ "$UNINSTALL" -eq 1 ]; then
  if [ ! -f "$HOOK_FILE" ] || ! grep -qF "$MARKER_BEGIN" "$HOOK_FILE"; then
    echo "dev-workflow の pre-commit フックは設置されていません"
    exit 0
  fi
  # マーカーで囲まれた区間だけを取り除く
  sed -i "/$(printf '%s' "$MARKER_BEGIN" | sed 's/[]\/$*.^[]/\\&/g')/,/$(printf '%s' "$MARKER_END" | sed 's/[]\/$*.^[]/\\&/g')/d" "$HOOK_FILE"
  echo "削除しました: ${HOOK_FILE}"
  exit 0
fi

mkdir -p "$HOOKS_DIR"

# ── 追記する内容 ─────────────────────────────────────────────────────
# DEV_WORKFLOW_HOOK_VENDOR=exit-code で「exit 1 + stderr」の契約に切り替える
# （CLIのフックではないため、exit 2 や JSON 出力ではなく通常の失敗を返させる）
guard_block() {
  cat <<BLOCK
${MARKER_BEGIN}
# 可読性ガード: エンコード済みブロブやミニファイ済みソースのコミットを止める
# 一時的に無効化する場合: READABILITY_GUARD=off git commit ...
DEV_WORKFLOW_HOOK_VENDOR=exit-code \\
  bash "${GUARD_SCRIPT}" --staged </dev/null || exit 1
${MARKER_END}
BLOCK
}

if [ ! -f "$HOOK_FILE" ]; then
  {
    echo "#!/bin/bash"
    echo "set -euo pipefail"
    echo ""
    guard_block
  } > "$HOOK_FILE"
  chmod +x "$HOOK_FILE" 2>/dev/null || true
  echo "作成しました: ${HOOK_FILE}"
  exit 0
fi

if grep -qF "$MARKER_BEGIN" "$HOOK_FILE"; then
  echo "既に設置済みです: ${HOOK_FILE}"
  exit 0
fi

# 既存のフックは壊さず、末尾に追記する
{
  echo ""
  guard_block
} >> "$HOOK_FILE"
chmod +x "$HOOK_FILE" 2>/dev/null || true
echo "追記しました: ${HOOK_FILE}"
