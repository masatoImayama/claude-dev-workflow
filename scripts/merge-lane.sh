#!/bin/bash
# dev-workflow: レーンの成果を wave ブランチへ統合する（ベンダー中立）
#
# `dev-workflow:run` のウェーブ並列実行（Epic #14）で、`--ff-only` が兼ねていた
# 「ベース逸脱の検出」と「履歴の直線性」を分離し、前者だけを merge-base 検証として担う。
# 取り込みは `git merge --no-edit` を使うため、レーンが1本だけのウェーブでは
# 自然に fast-forward になり、履歴は現行と同じ直線を保つ（仕様書 5.4）。
#
# なぜ完全一致で検証できるか（仕様書 5.4 の根拠）:
#   merge-base(wave, laneB) は、laneA を wave に取り込んだ後でも WAVE_BASE のままである
#   （wave は WAVE_BASE を含み、laneB の祖先集合は WAVE_BASE 以下だから）。
#   したがって完全一致による検証が並列レーンでもそのまま成立する。
#   誤って master 等から分岐したレーンは merge-base が古いコミットになるため検出される。
#
# 使い方:
#   bash scripts/merge-lane.sh \
#     --wave-branch wave/<epicN>/<n> --expected-base <WAVE_BASE> \
#     --lane-branch <レーンのブランチ> [--task <番号>] [--create]
#
# --wave-branch: 統合先のブランチ名（例: wave/epic14/1）。
# --expected-base: そのウェーブの唯一の正しい分岐元（epic ブランチ tip のコミット）。
#                   ブランチ名・タグ・コミットハッシュのいずれでもよい（内部で正規化して比較する）。
# --lane-branch: 取り込むレーンのブランチ名。
# --task: ログ表示用（省略可）。呼び出し側の issue 番号をメッセージに出すだけで、動作は変えない。
# --create: wave ブランチが存在しなければ --expected-base から作成する。
#
# 実行前提: 呼び出し側の cwd は epic worktree を想定する（実行中に wave ブランチを checkout する）。
#
# 終了コード:
#   0  取り込み成功
#   10 merge-base ≠ EXPECTED_BASE（ベース逸脱）。実際の merge-base とそのコミットログを stdout に出す
#   11 マージ競合（git merge --abort 済み）。競合ファイル一覧を stdout に出す
#   2  引数エラー
#   1  その他の失敗
#
# exit 10 のとき cherry-pick による載せ替えは行わない（検証されていないツリーを作る経路を
# 残さないため）。救済は呼び出し側が「次ウェーブで再実行」として行う（仕様書 5.6）。
# 競合の自動解決も一切試みない。

set -u

# ---------------------------------------------------------------------------
# 引数解析
# ---------------------------------------------------------------------------

WAVE_BRANCH=""
EXPECTED_BASE=""
LANE_BRANCH=""
TASK_NUM=""
CREATE_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wave-branch)
      if [ $# -lt 2 ]; then
        echo "ERROR: --wave-branch には値が必要です" >&2
        exit 2
      fi
      WAVE_BRANCH="$2"; shift 2 ;;
    --expected-base)
      if [ $# -lt 2 ]; then
        echo "ERROR: --expected-base には値が必要です" >&2
        exit 2
      fi
      EXPECTED_BASE="$2"; shift 2 ;;
    --lane-branch)
      if [ $# -lt 2 ]; then
        echo "ERROR: --lane-branch には値が必要です" >&2
        exit 2
      fi
      LANE_BRANCH="$2"; shift 2 ;;
    --task)
      if [ $# -lt 2 ]; then
        echo "ERROR: --task には値が必要です" >&2
        exit 2
      fi
      TASK_NUM="$2"; shift 2 ;;
    --create) CREATE_MODE=1; shift ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$WAVE_BRANCH" ]; then
  echo "ERROR: --wave-branch は必須です" >&2
  exit 2
fi
if [ -z "$EXPECTED_BASE" ]; then
  echo "ERROR: --expected-base は必須です" >&2
  exit 2
fi
if [ -z "$LANE_BRANCH" ]; then
  echo "ERROR: --lane-branch は必須です" >&2
  exit 2
fi

TASK_LABEL=""
[ -n "$TASK_NUM" ] && TASK_LABEL=" (#${TASK_NUM})"

# ---------------------------------------------------------------------------
# 前提の検証（gitリポジトリであること・各種参照の解決）
# ---------------------------------------------------------------------------

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: 現在のディレクトリは git リポジトリではありません" >&2
  exit 1
fi

EXPECTED_BASE_SHA="$(git rev-parse --verify -q "${EXPECTED_BASE}^{commit}" 2>/dev/null)"
if [ -z "$EXPECTED_BASE_SHA" ]; then
  echo "ERROR: --expected-base を解決できません: ${EXPECTED_BASE}" >&2
  exit 2
fi

if ! git rev-parse --verify -q "refs/heads/${LANE_BRANCH}" >/dev/null 2>&1; then
  echo "ERROR: レーンのブランチが見つかりません: ${LANE_BRANCH}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# wave ブランチの用意（--create なら無ければ作成）と checkout
# ---------------------------------------------------------------------------

if ! git rev-parse --verify -q "refs/heads/${WAVE_BRANCH}" >/dev/null 2>&1; then
  if [ "$CREATE_MODE" -eq 1 ]; then
    if ! git branch "$WAVE_BRANCH" "$EXPECTED_BASE_SHA" >/dev/null 2>&1; then
      echo "ERROR: wave ブランチの作成に失敗しました: ${WAVE_BRANCH}" >&2
      exit 1
    fi
    echo "wave ブランチを作成しました: ${WAVE_BRANCH} (${EXPECTED_BASE_SHA})"
  else
    echo "ERROR: wave ブランチが見つかりません: ${WAVE_BRANCH}（--create で作成できます）" >&2
    exit 1
  fi
fi

if ! git checkout -q "$WAVE_BRANCH" 2>&1; then
  echo "ERROR: wave ブランチの checkout に失敗しました: ${WAVE_BRANCH}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# merge-base 検証（ベース逸脱の検出。仕様書 5.4）
# ---------------------------------------------------------------------------

ACTUAL_BASE="$(git merge-base "$WAVE_BRANCH" "$LANE_BRANCH" 2>/dev/null)"
if [ -z "$ACTUAL_BASE" ]; then
  echo "ERROR: merge-base を計算できません（共通の祖先が無い可能性があります）: ${WAVE_BRANCH} <-> ${LANE_BRANCH}" >&2
  exit 1
fi

if [ "$ACTUAL_BASE" != "$EXPECTED_BASE_SHA" ]; then
  echo "ERROR: merge-base がベースと一致しません（ベース逸脱）${TASK_LABEL}"
  echo "  expected: ${EXPECTED_BASE_SHA}"
  echo "  actual:   ${ACTUAL_BASE}"
  echo "実際の merge-base のコミットログ:"
  git log -1 --oneline "$ACTUAL_BASE"
  exit 10
fi

# ---------------------------------------------------------------------------
# 取り込み（git merge --no-edit。ff可能ならff。競合の自動解決は一切試みない）
# ---------------------------------------------------------------------------

MERGE_OUTPUT="$(git merge --no-edit "$LANE_BRANCH" 2>&1)"
MERGE_EXIT=$?

if [ "$MERGE_EXIT" -ne 0 ]; then
  echo "$MERGE_OUTPUT"
  echo "ERROR: マージ競合が発生しました${TASK_LABEL}: ${LANE_BRANCH} -> ${WAVE_BRANCH}"
  echo "競合ファイル一覧:"
  git diff --name-only --diff-filter=U
  git merge --abort
  exit 11
fi

echo "$MERGE_OUTPUT"
echo "取り込み成功${TASK_LABEL}: ${LANE_BRANCH} -> ${WAVE_BRANCH}"

exit 0
