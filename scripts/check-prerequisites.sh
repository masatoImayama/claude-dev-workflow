#!/bin/bash
# dev-workflow plugin: 前提条件チェック
# exit 0 = OK, exit 2 = ブロック（必須依存が不足）

errors=()

# GitHub CLI（必須：epic/task issue管理に必要）
if ! command -v gh &> /dev/null; then
  errors+=("gh (GitHub CLI) がインストールされていません。https://cli.github.com/ からインストールしてください。")
fi

# gh 認証チェック
if command -v gh &> /dev/null && ! gh auth status &> /dev/null; then
  errors+=("gh が未認証です。'gh auth login' を実行してください。")
fi

# gh auth setup-git: gitの認証をghに委任する
# これがないとgit push時にWindows Credential Managerのアカウント選択ポップアップが出て自律動作が中断する
if command -v gh &> /dev/null && gh auth status &> /dev/null; then
  # gh がgitのcredential helperとして設定されているか確認
  if ! git config --global credential.helper 2>/dev/null | grep -q "gh"; then
    echo "[dev-workflow] git認証をgh CLIに委任します（ポップアップ防止）..." >&2
    gh auth setup-git 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "[dev-workflow] gh auth setup-git 完了。git操作はgh CLIのトークンを使用します。" >&2
    else
      errors+=("'gh auth setup-git' に失敗しました。手動で実行してください。")
    fi
  fi
fi

# Docker（必須：sandbox実行に必要）
if ! command -v docker &> /dev/null; then
  errors+=("Docker がインストールされていません。https://docs.docker.com/get-docker/ からインストールしてください。")
fi

# Docker 起動チェック
if command -v docker &> /dev/null && ! docker info &> /dev/null; then
  errors+=("Docker デーモンが起動していません。Docker Desktop を起動してください。")
fi

# git リポジトリチェック
if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
  errors+=("git リポジトリ内で実行してください。")
fi

# エラーがあればブロック
if [ ${#errors[@]} -gt 0 ]; then
  echo "[dev-workflow] 前提条件が満たされていません:" >&2
  for err in "${errors[@]}"; do
    echo "  - $err" >&2
  done
  exit 2
fi

exit 0
