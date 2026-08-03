#!/bin/bash
# dev-workflow: 管理コンテナの所属判定（Docker 非依存の純粋関数）
#
# `--down --all` の対象判定に使う。docker から取得した値（label・マウント元）を
# 引数として受け取るだけの純粋関数として切り出すことで、docker を一切起動せずに
# tests/run-tests.sh からテストできるようにする（Epic #3 仕様書 4.5）。
#
# 判定基準（issue #29 で label_root を追加）:
#   1. label（dev-workflow.repo）を第一とする。値があれば、まず現在の repo と
#      一致するかどうかで絞り込む。不一致なら即座に対象外とする
#      （同名 basename・別 root の混入を防ぐため、マウント元判定にはフォールバックしない）。
#   2. label の repo が一致した場合、さらに label（dev-workflow.root）を見る。
#      値があれば、正規化済みの HOST_ROOT と一致するときだけ対象に含める
#      （同じ basename で別ディレクトリにクローンした場合の誤爆を防ぐ）。
#      値が空（本 Epic 以前に起動された旧コンテナ）の場合のみ、
#      3 のマウント元判定にフォールバックする。
#   3. label（dev-workflow.repo）自体が無い（旧命名の残骸）場合は、マウント元が
#      リポジトリルート配下かで実体判定する。名前ではなく実体で判定するため、
#      命名規則を変えても掃除が生き残る。
#
# マウント元の比較は正規化済み（normalize_mount_source）で行う。Windows + Docker
# Desktop では bind mount の .Source が `/run/desktop/mnt/host/c/...` という
# Linux 側の変換済みパスで返るため、素の文字列比較では常に不一致になる（issue #25）。
#
# このファイルは sandbox-exec.sh から source される。単体では何もしない。

set -u

_CONTAINER_MEMBERSHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./mount-path.sh
. "${_CONTAINER_MEMBERSHIP_DIR}/mount-path.sh"

container_belongs_to_repo() {
  # container_belongs_to_repo <label_repo> <label_root> <mount_source> <host_root> <project>
  # 戻り値: 0=現在のリポジトリに属する（削除対象に含める） 1=属さない
  local label_repo="$1" label_root="$2" mount_source="$3" host_root="$4" project="$5"

  if [ -n "$label_repo" ]; then
    [ "$label_repo" = "$project" ] || return 1

    if [ -n "$label_root" ]; then
      [ "$(normalize_mount_source "$label_root")" = "$(normalize_mount_source "$host_root")" ]
      return $?
    fi
    # label_root が空（本 Epic 以前に起動された旧コンテナ）の場合のみ、
    # マウント元判定にフォールバックする。
  fi

  # label（dev-workflow.repo）が無い、または label はあるが root label が空。
  # マウント元がリポジトリルート配下かで実体判定する。
  [ -n "$mount_source" ] && [ -n "$host_root" ] || return 1

  local norm_mount norm_host
  norm_mount="$(normalize_mount_source "$mount_source")"
  norm_host="$(normalize_mount_source "$host_root")"
  case "$norm_mount" in
    "$norm_host")   return 0 ;;
    "$norm_host"/*) return 0 ;;
    *)              return 1 ;;
  esac
}
