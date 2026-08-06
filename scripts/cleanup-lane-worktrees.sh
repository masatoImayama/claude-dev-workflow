#!/bin/bash
# dev-workflow: 取り込み済みのレーン worktree を安全に片付ける（ベンダー中立）
#
# Claude Code の generator は `isolation: worktree` で起動され、`.claude/worktrees/agent-XXXXXX`
# に専用の worktree を持つ。`skills/run/SKILL.md` は「ハーネスが自動整理する」としてきたが、
# 変更を加えた（＝コミットを持つ）worktree は自動削除の対象外と見られ、Epic を重ねるごとに
# 単調増加する（`docs/dev-workflow-handover.md` H6節。実測: 163個の残留、run実行者が71個を手削除）。
#
# 「取り込み済みかどうか」の確認を散文で LLM にやらせると取りこぼす（H1・H5 と同じ失敗パターン）
# ため、判定をスクリプトに固定する。呼び出し側（run）からの結線は #95 で行う。ここでは
# スクリプトと単体テストの追加のみを行う。
#
# 使い方:
#   bash scripts/cleanup-lane-worktrees.sh --epic-branch <ブランチ> \
#       --lane-branch <ブランチ> [--lane-branch <ブランチ> ...] [--dry-run]
#
# --epic-branch: 取り込み済みかどうかの判定基準にする Epic ブランチ。
# --lane-branch: 片付け対象のレーンブランチ。複数指定できる。
# --dry-run: 削除せず、対象と判定理由だけを出力する。
#
# 出力（1行1件・機械可読。この順で標準出力へ）:
#   removed	<レーンブランチ>	<worktreeのパス>
#   skip	<レーンブランチ>	reason	<no-worktree|protected|not-merged|remove-failed>
#
# --dry-run のときの removed 行は「削除予定」の意味であり、実際には削除しない。
#
# 終了コード:
#   0 = 正常終了（削除0件・skipのみでも0）
#   2 = 引数エラー
#
# レーンブランチごとの処理順序:
#   1. `git worktree list --porcelain` から、そのブランチをチェックアウトしている worktree の
#      パスを引く。見つからなければ skip reason no-worktree
#   2. メインの worktree、および --epic-branch をチェックアウトしている worktree は
#      決して対象にしない → skip reason protected。
#      判定はディレクトリ名ではなく「チェックアウト中のブランチ」と「メイン worktree かどうか」
#      で行う（`git worktree list --porcelain` は主 worktree を必ず先頭に出す仕様を利用する）
#   3. `git merge-base --is-ancestor <レーンブランチ> <epic-branch>` で
#      Epic ブランチへ取り込み済みであることを確認する。偽なら削除しない → skip reason not-merged
#      （取り込めなかったレーンの成果を消さないための安全条件。R7 対策）
#   4. `node_modules` 等の symlink を解除してから `git worktree remove --force` する。
#      symlink を残したまま削除するとメインリポの実体ファイルが消える事故になる
#      （既存の skills/run/SKILL.md・adapters/claude/overlays/generator.md と同じ手順）
#   5. 全件処理後（--dry-run 以外）に `git worktree prune` を1回実行する
#
# 安全ルール:
#   - `rm` / `rmdir` によるディレクトリ削除は行わない。worktree の削除は
#     `git worktree remove` に限る（`unlink` は node_modules 等の symlink 解除のみに使う）
#   - 他 Epic・他リポジトリの worktree には一切触れない。`--lane-branch` で明示された
#     ブランチだけを対象にする（`agent-*` を名前で総なめしない）
#   - `git worktree remove` が失敗しても（長いファイル名等）run 全体を落とさず、
#     skip reason remove-failed として次のレーンブランチの処理へ進む
#
# 追加の依存物（jq 等）は要求しない。素の bash / git / find のみで完結させる。

set -u

EPIC_BRANCH=""
LANE_BRANCHES=()
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --epic-branch)
      if [ $# -lt 2 ]; then
        echo "ERROR: --epic-branch には値が必要です" >&2
        exit 2
      fi
      EPIC_BRANCH="$2"; shift 2 ;;
    --lane-branch)
      if [ $# -lt 2 ]; then
        echo "ERROR: --lane-branch には値が必要です" >&2
        exit 2
      fi
      LANE_BRANCHES+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$EPIC_BRANCH" ]; then
  echo "ERROR: --epic-branch は必須です" >&2
  exit 2
fi
if [ "${#LANE_BRANCHES[@]}" -eq 0 ]; then
  echo "ERROR: --lane-branch は最低1つ必要です" >&2
  exit 2
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: 現在のディレクトリは git リポジトリではありません" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# git worktree list --porcelain を1回だけ読み、レコード（パス／ブランチ／メインか）に
# 分解する。主 worktree は必ず先頭に出る仕様（git-worktree(1)）を利用し、
# 最初に現れたレコードだけを「メイン」として扱う。
# ---------------------------------------------------------------------------

WT_PATHS=()
WT_BRANCHES=()
WT_IS_MAIN=()

_cur_path=""
_cur_branch=""
_seen_any=0

_flush_wt_record() {
  if [ -n "$_cur_path" ]; then
    WT_PATHS+=("$_cur_path")
    WT_BRANCHES+=("$_cur_branch")
    if [ "$_seen_any" -eq 0 ]; then
      WT_IS_MAIN+=("1")
      _seen_any=1
    else
      WT_IS_MAIN+=("0")
    fi
  fi
}

while IFS= read -r _wt_line; do
  case "$_wt_line" in
    "worktree "*)
      _flush_wt_record
      _cur_path="${_wt_line#worktree }"
      _cur_branch=""
      ;;
    "branch "*)
      _cur_branch="${_wt_line#branch }"
      _cur_branch="${_cur_branch#refs/heads/}"
      ;;
    *) : ;;
  esac
done < <(git worktree list --porcelain)
_flush_wt_record

# ---------------------------------------------------------------------------
# レーンブランチを引く（パス／メイン判定を1組で返す。見つからなければ空文字）
# ---------------------------------------------------------------------------

find_lane_worktree() {
  # find_lane_worktree <レーンブランチ名>
  # 見つかれば "<パス>\t<メインなら1>" を1行出力する。見つからなければ何も出力しない。
  local want="$1" i
  for i in "${!WT_PATHS[@]}"; do
    if [ "${WT_BRANCHES[$i]}" = "$want" ]; then
      printf '%s\t%s\n' "${WT_PATHS[$i]}" "${WT_IS_MAIN[$i]}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# レーンブランチごとの判定・削除
# ---------------------------------------------------------------------------

REMOVED_COUNT=0

for LANE in "${LANE_BRANCHES[@]}"; do
  FOUND_LINE="$(find_lane_worktree "$LANE")"
  if [ -z "$FOUND_LINE" ]; then
    printf 'skip\t%s\treason\tno-worktree\n' "$LANE"
    continue
  fi

  LANE_WT_PATH="${FOUND_LINE%%$'\t'*}"
  LANE_WT_IS_MAIN="${FOUND_LINE##*$'\t'}"

  # メイン worktree、または --epic-branch をチェックアウトしている worktree は対象外
  if [ "$LANE_WT_IS_MAIN" = "1" ] || [ "$LANE" = "$EPIC_BRANCH" ]; then
    printf 'skip\t%s\treason\tprotected\n' "$LANE"
    continue
  fi

  if ! git merge-base --is-ancestor "refs/heads/${LANE}" "refs/heads/${EPIC_BRANCH}" 2>/dev/null; then
    printf 'skip\t%s\treason\tnot-merged\n' "$LANE"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'removed\t%s\t%s\n' "$LANE" "$LANE_WT_PATH"
    continue
  fi

  # node_modules 等の symlink を解除してから削除する。symlink を残したまま
  # `git worktree remove` すると、symlink 越しにメインリポの実体ファイルが消える事故になる。
  find "$LANE_WT_PATH" -maxdepth 2 -type l -name "node_modules" -exec unlink {} \; 2>/dev/null || true

  if git worktree remove --force "$LANE_WT_PATH" 2>/dev/null; then
    printf 'removed\t%s\t%s\n' "$LANE" "$LANE_WT_PATH"
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
  else
    # 長いファイル名等で削除が失敗しうる。run 全体を落とさず、次のレーンへ進む。
    printf 'skip\t%s\treason\tremove-failed\n' "$LANE"
  fi
done

if [ "$DRY_RUN" -eq 0 ]; then
  git worktree prune >/dev/null 2>&1 || true
fi

exit 0
