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
