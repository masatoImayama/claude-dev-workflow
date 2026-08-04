#!/bin/bash
# dev-workflow: Task issue が宣言した依存関係からウェーブ分解を計算する（ベンダー中立）
#
# `dev-workflow:run` のタスク実行を、依存グラフに基づくウェーブ単位の並列実行に切り替えるための
# 決定論の本体（Epic #14 仕様書 5.2）。ウェーブ分解は並列化の「正しさの本体」であり、
# SKILL.md の散文として LLM に実行させると解釈が実行ごとにぶれるため、ここに切り出して
# tests/run-tests.sh で固定する。Docker には一切触れない。
#
# 使い方:
#   bash scripts/plan-waves.sh --epic <Epic issue番号> [--lanes N] [--skipped 4,7] [--print]
#   bash scripts/plan-waves.sh --from-file <TSV> [--lanes N] [--skipped 4,7] [--print]
#
# --epic: 数値の Epic issue 番号（例: 14）。既定の入力は
#         `gh issue list --label task --state open --json number,body --limit 200`。
#         依存先が既に closed（同一 Epic の完了済みタスク）なら充足済み扱いにするため、
#         最初のフェッチに含まれない依存番号は `gh issue view` で個別に state/labels を確認する
#         （task ラベル付き closed のみ充足済み。それ以外は unknown-dep として警告し無視する）。
#
#         Epic 混入対策: 本文の「- Epic: #N」行（`skills/epic/SKILL.md` の Task issue テンプレート、
#         `skills/run/SKILL.md` の Review issue テンプレートが書く行）を見て、N が指定 Epic と
#         異なるタスクだけを除外する。行が無い
#         （旧形式の Task issue）場合はフェイルオープンで含める。`gh issue list --search` は
#         数値・記号をトークン化して "Epic: #3" が "#34" 等にもマッチする誤検出を起こすため
#         （Task #39 対応時に実データで確認済み）、本文の完全一致抽出のみを信頼する。
#
# --from-file: タブ区切り、1行1タスク。テストが GitHub に依存しないようにするための入力差し替え。
#   <issue番号>\t<state: open|closed>\t<前提行の生テキスト（無ければ空文字列）>
#   前提行は本文中の「- 前提:」で始まる行そのもの（例: "- 前提: #4, #9（注釈）"）。
#   空文字列は「- 前提: 行そのものが無い」＝宣言漏れを意味する。「- 前提: なし」は
#   明記された0件の依存として扱われ、宣言漏れの警告は出ない。
#
# --lanes N: 既定3。環境変数 DEV_WORKFLOW_MAX_LANES があればそれを既定にする。
# --skipped: カンマ区切りの issue 番号。それらに依存するタスクは推移的にスキップする。
# --print: 人間向けの表を出す（ドライラン。既定は機械可読な TSV）。
#
# 出力（既定・機械可読、タブ区切り）:
#   lanes	<N>
#   task	<番号>	wave	<W>	subbatch	<S>	deps	<dep1,dep2,...>
#   wave	<W>	tasks	<n1,n2,...>
#   warn	missing-deps	<番号>
#   warn	unknown-dep	<番号>	<未知のdep番号>
#   skip	<番号>	reason	depends-on-skipped	<依存先番号>
#
# 終了コード: 0=成功 2=引数エラー 3=循環依存（循環に含まれるタスクを stderr に列挙して停止）

set -u

# ---------------------------------------------------------------------------
# 引数解析
# ---------------------------------------------------------------------------

EPIC=""
FROM_FILE=""
LANES="${DEV_WORKFLOW_MAX_LANES:-3}"
SKIPPED_CSV=""
PRINT_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --epic)
      if [ $# -lt 2 ]; then
        echo "ERROR: --epic には値が必要です" >&2
        exit 2
      fi
      EPIC="$2"; shift 2 ;;
    --from-file)
      if [ $# -lt 2 ]; then
        echo "ERROR: --from-file には値が必要です" >&2
        exit 2
      fi
      FROM_FILE="$2"; shift 2 ;;
    --lanes)
      if [ $# -lt 2 ]; then
        echo "ERROR: --lanes には値が必要です" >&2
        exit 2
      fi
      LANES="$2"; shift 2 ;;
    --skipped)
      if [ $# -lt 2 ]; then
        echo "ERROR: --skipped には値が必要です" >&2
        exit 2
      fi
      SKIPPED_CSV="$2"; shift 2 ;;
    --print) PRINT_MODE=1; shift ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$EPIC" ] && [ -n "$FROM_FILE" ]; then
  echo "ERROR: --epic と --from-file は同時に指定できません" >&2
  exit 2
fi
if [ -z "$EPIC" ] && [ -z "$FROM_FILE" ]; then
  echo "ERROR: --epic または --from-file のいずれかが必要です" >&2
  exit 2
fi

case "$LANES" in
  ''|*[!0-9]*) echo "ERROR: --lanes は正の整数で指定してください: [${LANES}]" >&2; exit 2 ;;
esac
if [ "$LANES" -lt 1 ]; then
  echo "ERROR: --lanes は1以上で指定してください: [${LANES}]" >&2
  exit 2
fi

if [ -n "$EPIC" ]; then
  case "$EPIC" in
    ''|*[!0-9]*) echo "ERROR: --epic は数値のEpic issue番号で指定してください: [${EPIC}]" >&2; exit 2 ;;
  esac
fi

SOURCE_MODE="file"
[ -n "$EPIC" ] && SOURCE_MODE="gh"

# ---------------------------------------------------------------------------
# タスク登録
# ---------------------------------------------------------------------------

declare -A TASK_STATE   # issue番号 -> open|closed（この番号を知っている＝Epic内 or 個別確認済み）
declare -A DEPS_LINE    # issue番号 -> 前提行の生テキスト（空文字列＝宣言漏れ）
PLAN_LIST=()            # ウェーブ計画の対象（state=open のタスク）issue番号の配列

register_task() {
  # register_task <issue番号> <state:open|closed> <前提行の生テキスト>
  local num="$1" state="$2" deps_line="$3"
  TASK_STATE["$num"]="$state"
  DEPS_LINE["$num"]="$deps_line"
  if [ "$state" = "open" ]; then
    PLAN_LIST+=("$num")
  fi
}

load_from_file() {
  local file="$1" num state deps_line
  if [ ! -f "$file" ]; then
    echo "ERROR: --from-file で指定されたファイルが見つかりません: ${file}" >&2
    exit 2
  fi
  while IFS=$'\t' read -r num state deps_line; do
    [ -n "$num" ] || continue
    case "$num" in ''|*[!0-9]*) continue ;; esac
    register_task "$num" "$state" "$deps_line"
  done < "$file"
}

load_from_gh() {
  # フィールド区切りは @tsv（タブ）ではなく Unit Separator（0x1f）を使う。tab は bash の read が
  # 「IFS空白文字」として連続する区切りを1個に畳んでしまうため、前提行が空でそのあとに
  # Epic行が続く行（実データで頻出）だと3列目が2列目にずれて誤検出する
  # （Task #39 対応時、テスト実装中に実際にこの畳み込みで検出漏れを起こして発覚した）。
  local num deps_line epic_line epic_in_line
  while IFS=$'\x1f' read -r num deps_line epic_line; do
    [ -n "$num" ] || continue
    # 本文の「- Epic: #N」行から N を取り出す（無ければ空文字＝フェイルオープンで含める）。
    epic_in_line="$(printf '%s' "$epic_line" | grep -oE '#[0-9]+' | head -1 | tr -d '#')"
    if [ -n "$epic_in_line" ] && [ "$epic_in_line" != "$EPIC" ]; then
      continue
    fi
    register_task "$num" "open" "$deps_line"
  done < <(gh issue list --label task --state open --json number,body --limit 200 \
    -q '.[] | [(.number|tostring), ((.body // "") | split("\n") | map(select(startswith("- 前提:"))) | (.[0] // "")), ((.body // "") | split("\n") | map(select(startswith("- Epic:"))) | (.[0] // ""))] | join("\u001f")')
}

if [ "$SOURCE_MODE" = "file" ]; then
  load_from_file "$FROM_FILE"
else
  load_from_gh
fi

# 昇順に整列する（宣言漏れの fail-safe・サブバッチ分割の両方が昇順を前提にするため）
if [ "${#PLAN_LIST[@]}" -gt 0 ]; then
  mapfile -t PLAN_LIST < <(printf '%s\n' "${PLAN_LIST[@]}" | sort -n)
fi

# ---------------------------------------------------------------------------
# 依存解決（宣言漏れの fail-safe・closed 充足・unknown-dep の検出）
# ---------------------------------------------------------------------------

declare -A REAL_DEPS       # issue番号 -> 実際にウェーブ計算へ使う依存（スペース区切り）
MISSING_DEPS_WARN=()       # 宣言漏れの issue 番号
UNKNOWN_DEP_WARN=()        # "issue番号:未知のdep番号"

lookup_external_state() {
  # lookup_external_state <issue番号>
  # 既知でない依存先の state を確認する。gh モードでは task ラベル付き closed のみ
  # 「充足済み」として扱い、それ以外（存在しない／task ラベル無し／open）は空文字列を返す
  # （呼び出し側が unknown-dep として警告する）。from-file モードは常に空文字列。
  local d="$1"
  [ "$SOURCE_MODE" = "gh" ] || { printf ''; return; }
  local raw state_val has_task
  raw="$(gh issue view "$d" --json state,labels \
    -q '[.state, ([.labels[].name] | index("task") != null)] | @tsv' 2>/dev/null)"
  [ -n "$raw" ] || { printf ''; return; }
  IFS=$'\t' read -r state_val has_task <<< "$raw"
  if [ "$has_task" = "true" ] && [ "$state_val" = "CLOSED" ]; then
    register_task "$d" "closed" ""
    printf 'closed'
  else
    printf ''
  fi
}

resolve_task_deps() {
  # resolve_task_deps <issue番号>  REAL_DEPS[番号] を埋める。副作用で警告配列も積む。
  local n="$1"
  local line="${DEPS_LINE[$n]:-}"
  local deps="" m d st nums

  if [ -z "$line" ]; then
    # 「- 前提:」行そのものが無い＝宣言漏れ。fail-safe: 自分より番号が小さい全タスクに依存する。
    MISSING_DEPS_WARN+=("$n")
    for m in "${PLAN_LIST[@]}"; do
      [ "$m" -lt "$n" ] || continue
      deps="${deps}${deps:+ }${m}"
    done
  else
    nums="$(printf '%s' "$line" | grep -oE '#[0-9]+' | tr -d '#')"
    # shellcheck disable=SC2086  # nums は数字の空白区切り列。意図的に単語分割してループする
    for d in $nums; do
      [ "$d" != "$n" ] || continue   # 自己参照は無視する（循環検出に頼らせない）
      st="${TASK_STATE[$d]:-}"
      if [ -z "$st" ]; then
        st="$(lookup_external_state "$d")"
      fi
      case "$st" in
        closed) : ;;                                   # 充足済み。依存として数えない
        open)   deps="${deps}${deps:+ }${d}" ;;
        *)      UNKNOWN_DEP_WARN+=("${n}:${d}") ;;
      esac
    done
  fi
  REAL_DEPS["$n"]="$deps"
}

for _n in "${PLAN_LIST[@]}"; do
  resolve_task_deps "$_n"
done
unset _n

# ---------------------------------------------------------------------------
# スキップの推移的伝播
# ---------------------------------------------------------------------------

declare -A SKIPPED_REASON   # issue番号 -> 伝播の原因になった依存先番号（明示スキップは空文字列）
SKIP_PROPAGATED=()          # 伝播によりスキップされた "issue番号:原因番号"（出力順）

IFS=',' read -r -a _skipped_arr <<< "$SKIPPED_CSV"
for _s in "${_skipped_arr[@]:-}"; do
  [ -n "$_s" ] || continue
  SKIPPED_REASON["$_s"]=""
done
unset _s _skipped_arr

_changed=1
while [ "$_changed" -eq 1 ]; do
  _changed=0
  for _n in "${PLAN_LIST[@]}"; do
    [ -z "${SKIPPED_REASON[$_n]+x}" ] || continue
    # shellcheck disable=SC2086  # REAL_DEPS の値は数字の空白区切り列。意図的に単語分割してループする
    for _d in ${REAL_DEPS[$_n]:-}; do
      if [ -n "${SKIPPED_REASON[$_d]+x}" ]; then
        SKIPPED_REASON["$_n"]="$_d"
        SKIP_PROPAGATED+=("${_n}:${_d}")
        _changed=1
        break
      fi
    done
  done
done
unset _n _d _changed

ACTIVE_LIST=()
for _n in "${PLAN_LIST[@]}"; do
  [ -n "${SKIPPED_REASON[$_n]+x}" ] || ACTIVE_LIST+=("$_n")
done
unset _n

# ---------------------------------------------------------------------------
# ウェーブ計算（依存グラフのレベル分け。DFS + 循環検出）
# ---------------------------------------------------------------------------

declare -A WAVE_OF        # issue番号 -> ウェーブ番号
declare -A VISIT_STATE    # issue番号 -> 0未訪問/1訪問中/2完了
PATH_STACK=()
LAST_WAVE=0
CYCLE_MEMBERS=()

compute_wave() {
  # compute_wave <issue番号>  戻り値 0=成功（結果は LAST_WAVE） 1=循環検出
  local n="$1"
  local state="${VISIT_STATE[$n]:-0}"

  if [ "$state" = "2" ]; then
    LAST_WAVE="${WAVE_OF[$n]}"
    return 0
  fi
  if [ "$state" = "1" ]; then
    local item found=0
    CYCLE_MEMBERS=()
    for item in "${PATH_STACK[@]}"; do
      if [ "$found" -eq 1 ] || [ "$item" = "$n" ]; then
        found=1
        CYCLE_MEMBERS+=("$item")
      fi
    done
    return 1
  fi

  VISIT_STATE["$n"]=1
  PATH_STACK+=("$n")

  local max_dep_wave=0 d
  # shellcheck disable=SC2086  # REAL_DEPS の値は数字の空白区切り列。意図的に単語分割してループする
  for d in ${REAL_DEPS[$n]:-}; do
    if ! compute_wave "$d"; then
      unset 'PATH_STACK[${#PATH_STACK[@]}-1]'
      return 1
    fi
    [ "$LAST_WAVE" -gt "$max_dep_wave" ] && max_dep_wave="$LAST_WAVE"
  done

  unset 'PATH_STACK[${#PATH_STACK[@]}-1]'
  WAVE_OF["$n"]=$((max_dep_wave + 1))
  VISIT_STATE["$n"]=2
  LAST_WAVE="${WAVE_OF[$n]}"
  return 0
}

for _n in "${ACTIVE_LIST[@]}"; do
  if [ "${VISIT_STATE[$_n]:-0}" != "2" ]; then
    if ! compute_wave "$_n"; then
      echo "ERROR: 循環依存を検出しました。循環に含まれるタスク: ${CYCLE_MEMBERS[*]}" >&2
      exit 3
    fi
  fi
done
unset _n

# ---------------------------------------------------------------------------
# ウェーブごとのタスク集約とサブバッチ割当
# ---------------------------------------------------------------------------

MAX_WAVE=0
for _n in "${ACTIVE_LIST[@]}"; do
  [ "${WAVE_OF[$_n]}" -gt "$MAX_WAVE" ] && MAX_WAVE="${WAVE_OF[$_n]}"
done
unset _n

declare -A SUBBATCH_OF   # issue番号 -> サブバッチ番号（ウェーブ内、1始まり）
WAVE_TASKS=()            # インデックス = ウェーブ番号（1始まり）の "n1,n2,..." 文字列

_w=1
while [ "$_w" -le "$MAX_WAVE" ]; do
  _tasks=()
  for _n in "${ACTIVE_LIST[@]}"; do
    [ "${WAVE_OF[$_n]}" -eq "$_w" ] && _tasks+=("$_n")
  done
  # ACTIVE_LIST は PLAN_LIST（昇順整列済み）由来の順序をそのまま保つため既に昇順
  _i=0
  for _n in "${_tasks[@]}"; do
    SUBBATCH_OF["$_n"]=$((_i / LANES + 1))
    _i=$((_i + 1))
  done
  _joined="$(IFS=,; printf '%s' "${_tasks[*]:-}")"
  WAVE_TASKS[_w]="$_joined"
  _w=$((_w + 1))
done
unset _w _n _i _tasks _joined

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------

print_machine() {
  echo -e "lanes\t${LANES}"

  local n
  for n in "${ACTIVE_LIST[@]}"; do
    local deps_csv
    deps_csv="$(printf '%s' "${REAL_DEPS[$n]:-}" | tr ' ' ',')"
    if [ -n "$deps_csv" ]; then
      echo -e "task\t${n}\twave\t${WAVE_OF[$n]}\tsubbatch\t${SUBBATCH_OF[$n]}\tdeps\t${deps_csv}"
    else
      echo -e "task\t${n}\twave\t${WAVE_OF[$n]}\tsubbatch\t${SUBBATCH_OF[$n]}\tdeps"
    fi
  done

  local w
  w=1
  while [ "$w" -le "$MAX_WAVE" ]; do
    echo -e "wave\t${w}\ttasks\t${WAVE_TASKS[$w]:-}"
    w=$((w + 1))
  done

  if [ "${#MISSING_DEPS_WARN[@]}" -gt 0 ]; then
    local sorted_missing
    mapfile -t sorted_missing < <(printf '%s\n' "${MISSING_DEPS_WARN[@]}" | sort -n)
    for n in "${sorted_missing[@]}"; do
      echo -e "warn\tmissing-deps\t${n}"
    done
  fi

  if [ "${#UNKNOWN_DEP_WARN[@]}" -gt 0 ]; then
    local pair task dep
    for pair in "${UNKNOWN_DEP_WARN[@]}"; do
      task="${pair%%:*}"
      dep="${pair##*:}"
      echo -e "warn\tunknown-dep\t${task}\t${dep}"
    done
  fi

  if [ "${#SKIP_PROPAGATED[@]}" -gt 0 ]; then
    local pair task dep
    for pair in "${SKIP_PROPAGATED[@]}"; do
      task="${pair%%:*}"
      dep="${pair##*:}"
      echo -e "skip\t${task}\treason\tdepends-on-skipped\t${dep}"
    done
  fi
}

print_human() {
  echo "=== ウェーブ分解（lanes=${LANES}） ==="
  local w
  w=1
  while [ "$w" -le "$MAX_WAVE" ]; do
    local tasks_csv sub_count
    tasks_csv="${WAVE_TASKS[$w]:-}"
    sub_count=0
    local n
    IFS=',' read -r -a _wtasks <<< "$tasks_csv"
    for n in "${_wtasks[@]:-}"; do
      [ -n "$n" ] || continue
      [ "${SUBBATCH_OF[$n]}" -gt "$sub_count" ] && sub_count="${SUBBATCH_OF[$n]}"
    done
    if [ "$sub_count" -gt 1 ]; then
      local detail="" s
      s=1
      while [ "$s" -le "$sub_count" ]; do
        local part=""
        for n in "${_wtasks[@]:-}"; do
          [ -n "$n" ] || continue
          [ "${SUBBATCH_OF[$n]}" -eq "$s" ] && part="${part}${part:+,}#${n}"
        done
        detail="${detail}${detail:+ / }サブバッチ${s}: ${part}"
        s=$((s + 1))
      done
      echo "ウェーブ ${w}: ${tasks_csv//,/, } (${detail})"
    else
      echo "ウェーブ ${w}: ${tasks_csv//,/, }"
    fi
    w=$((w + 1))
  done

  if [ "${#MISSING_DEPS_WARN[@]}" -gt 0 ]; then
    echo ""
    echo "[警告] 前提未宣言（宣言漏れ・完全逐次にフォールバック）:"
    local sorted_missing n2
    mapfile -t sorted_missing < <(printf '%s\n' "${MISSING_DEPS_WARN[@]}" | sort -n)
    for n2 in "${sorted_missing[@]}"; do
      echo "  #${n2}"
    done
  fi

  if [ "${#UNKNOWN_DEP_WARN[@]}" -gt 0 ]; then
    echo ""
    echo "[警告] 不明な依存（Epic外・存在しない issue。無視されます）:"
    local pair task dep
    for pair in "${UNKNOWN_DEP_WARN[@]}"; do
      task="${pair%%:*}"
      dep="${pair##*:}"
      echo "  #${task} -> #${dep}"
    done
  fi

  if [ "${#SKIP_PROPAGATED[@]}" -gt 0 ]; then
    echo ""
    echo "[スキップ] 依存先のスキップが伝播:"
    local pair task dep
    for pair in "${SKIP_PROPAGATED[@]}"; do
      task="${pair%%:*}"
      dep="${pair##*:}"
      echo "  #${task}（依存先 #${dep} がスキップされたため）"
    done
  fi
}

if [ "$PRINT_MODE" -eq 1 ]; then
  print_human
else
  print_machine
fi

exit 0
