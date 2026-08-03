#!/bin/bash
# dev-workflow: マウント元パスの正規化（Docker 非依存の純粋関数）
#
# Windows + Docker Desktop では `docker container inspect` の bind mount `.Source` が
# `/run/desktop/mnt/host/c/Users/.../dev-workflow` という Linux 側の変換済みパスで返る。
# 一方 sandbox-exec.sh が計算する MOUNT_SOURCE / HOST_ROOT は `pwd -W` による
# `C:/Users/.../dev-workflow` 形式であり、素の文字列比較では常に不一致になる
# （Epic #3 issue #25）。
#
# normalize_mount_source() はこの差異を吸収するため、ドライブ付きの各種表現を
# `<DRIVE>:/...` 形式に正規化する。区切りは `/` に統一し、ドライブレターは大文字、
# パス部分は小文字にすることで、由来の異なる同一パスを文字列比較できるようにする。
#
# 対応する入力形式:
#   - /run/desktop/mnt/host/<drive>/...  （Docker Desktop の bind mount .Source）
#   - /mnt/<drive>/...                    （WSL）
#   - //<drive>/...                       （Git Bash 等）
#   - <drive>:/...                        （pwd -W 等。既に正規化済みの Windows 形式）
#
# 上記のいずれにも一致しない入力（ドライブレターを持たない通常の Unix パス等）は、
# 区切り文字の変換のみ行い、大小文字は変えずにそのまま返す
# （大小文字を区別するファイルシステムでの比較を壊さないため）。
#
# このファイルは sandbox-exec.sh / container-membership.sh から source される。
# 単体では何もしない。

set -u

normalize_mount_source() {
  # normalize_mount_source <path>
  local input="$1"
  local drive rest

  # バックスラッシュ区切りをスラッシュへ統一する。
  input="${input//\\//}"

  case "$input" in
    /run/desktop/mnt/host/[A-Za-z]|/run/desktop/mnt/host/[A-Za-z]/*)
      drive="${input#/run/desktop/mnt/host/}"
      rest="${drive#?}"
      drive="${drive%%/*}"
      ;;
    /mnt/[A-Za-z]|/mnt/[A-Za-z]/*)
      drive="${input#/mnt/}"
      rest="${drive#?}"
      drive="${drive%%/*}"
      ;;
    //[A-Za-z]|//[A-Za-z]/*)
      drive="${input#//}"
      rest="${drive#?}"
      drive="${drive%%/*}"
      ;;
    [A-Za-z]:|[A-Za-z]:/*)
      drive="${input%%:*}"
      rest="${input#*:}"
      ;;
    *)
      # ドライブ形式でない通常の Unix パス。大小文字は変えずにそのまま返す。
      printf '%s' "$input"
      return 0
      ;;
  esac

  drive="$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')"
  rest="$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')"
  printf '%s:%s' "$drive" "$rest"
}
