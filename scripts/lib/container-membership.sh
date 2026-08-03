#!/bin/bash
# dev-workflow: 管理コンテナの所属判定（Docker 非依存の純粋関数）
#
# `--down --all` の対象判定に使う。docker から取得した値（label・マウント元）を
# 引数として受け取るだけの純粋関数として切り出すことで、docker を一切起動せずに
# tests/run-tests.sh からテストできるようにする（Epic #3 仕様書 4.5）。
#
# 判定基準:
#   1. label（dev-workflow.repo）を第一とする。値があればそれが現在の repo と
#      一致するかどうかだけで判定する。
#   2. label が無い（旧命名の残骸）場合は、マウント元がリポジトリルート配下かで
#      実体判定する。名前ではなく実体で判定するため、命名規則を変えても掃除が生き残る。
#
# このファイルは sandbox-exec.sh から source される。単体では何もしない。

set -u

container_belongs_to_repo() {
  # container_belongs_to_repo <label_repo> <mount_source> <host_root> <project>
  # 戻り値: 0=現在のリポジトリに属する（削除対象に含める） 1=属さない
  local label_repo="$1" mount_source="$2" host_root="$3" project="$4"

  if [ -n "$label_repo" ]; then
    [ "$label_repo" = "$project" ]
    return $?
  fi

  # label なし（旧命名の残骸候補）。マウント元がリポジトリルート配下かで実体判定する。
  [ -n "$mount_source" ] && [ -n "$host_root" ] || return 1
  case "$mount_source" in
    "$host_root")   return 0 ;;
    "$host_root"/*) return 0 ;;
    *)              return 1 ;;
  esac
}
