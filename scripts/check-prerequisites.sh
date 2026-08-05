#!/bin/bash
# dev-workflow plugin: 前提条件チェック
# exit 0 = OK, exit 2 = ブロック（必須依存が不足）
#
# crlf_warning_message は Docker 非依存の純粋関数として切り出してあり、
# tests/run-tests.sh から直接 source して単体テストする（Epic #3 仕様書 4.10）。
# このファイルが source されただけの場合、以降の前提条件チェック本体は実行しない
# （$0 と BASH_SOURCE[0] が一致するのは直接実行された場合のみ）。

crlf_warning_message() {
  # crlf_warning_message
  # 条件: core.autocrlf が true かつ *.sh の eol 解決が lf でない。
  # 該当すれば警告メッセージを標準出力に返し、非該当なら何も出力しない（非ブロッキング）。
  # 判定に git check-attr を使うのは、グローバル設定を含む git 自身の解決結果を見るため。
  local autocrlf
  autocrlf="$(git config --get core.autocrlf 2>/dev/null)"
  [ "$autocrlf" = "true" ] || return 0

  local eol
  eol="$(git check-attr eol -- "dev-workflow-crlf-probe.sh" 2>/dev/null | sed -n 's/^.*: eol: //p')"
  [ "$eol" = "lf" ] && return 0

  cat <<'MSG'
[dev-workflow] 警告: core.autocrlf=true ですが、.gitattributes で *.sh の改行コードが
lf に固定されていません。Windows で生成した .sh が CRLF のままサンドボックス
（Linuxコンテナ）に渡ると、次のようなエラーになります（原因が分かりにくいので注意）:
  syntax error near unexpected token $'{\r'
対処: .gitattributes に以下の1行を追記してください:
  *.sh text eol=lf
MSG
}

optional_tools_notice() {
  # optional_tools_notice
  # 任意ツール（context7 / code-review-graph）の導入状況を非ブロッキングで通知する。
  # docs/optional-mcp-tools.md「## 対象ツール」節・「## 申し送りに対してどう応えたか（#80 レビュー対応）」節に
  # 記録したとおり、dev-workflowが実際に`.claude-plugin/plugin.json`等の`command`に指定する
  # コマンド名（context7: context7-mcp / code-review-graph: code-review-graph）の有無を
  # command -v で判定する（#80で`npx -y ...`からの自動取得をやめ、導入済みバイナリ`context7-mcp`を
  # 直接指す方式に変更したため、`npx`ではなく`context7-mcp`の有無で判定する。#82）。
  # 両方とも利用可能なら何も出力しない（黙って通す）。エラーとして扱わないため、
  # 呼び出し側は errors 配列に追加してはならない（exit 2 を返さない）。
  local missing_context7=0 missing_code_review_graph=0
  command -v context7-mcp &> /dev/null || missing_context7=1
  command -v code-review-graph &> /dev/null || missing_code_review_graph=1

  [ "$missing_context7" -eq 0 ] && [ "$missing_code_review_graph" -eq 0 ] && return 0

  echo "[dev-workflow] 情報: 任意ツールが未導入です（未導入でも dev-workflow は従来どおり動作します）:"
  if [ "$missing_context7" -eq 1 ]; then
    echo "  - context7: 未導入です。generator は未知のライブラリ・バージョン依存APIの確認に"
    echo "    context7 を使わず、従来どおり（リポジトリ内の既存利用箇所・公式ドキュメントの確認）で動作します。"
  fi
  if [ "$missing_code_review_graph" -eq 1 ]; then
    echo "  - code-review-graph: 未導入です。evaluator は大規模差分（変更50ファイル超）でも"
    echo "    blast radius の算出を使わず、従来どおり Phase 単位に分割してレビューします。"
  fi
  echo "  導入方法は docs/optional-mcp-tools.md を参照してください。"
}

if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  return 0
fi

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
    if gh auth setup-git 2>/dev/null; then
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

# CRLF 警告（非ブロッキング。仕様書 4.10）。git リポジトリ内でのみ判定できるため、
# 上の git リポジトリチェックが通っている場合に限って実行する。
if git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
  crlf_warning="$(crlf_warning_message)"
  if [ -n "$crlf_warning" ]; then
    echo "$crlf_warning" >&2
  fi
fi

# 任意ツール（context7 / code-review-graph）の未導入通知（非ブロッキング。Epic #66 Phase 1 / #68）。
# crlf_warning_message と同じ作法: errors 配列には絶対に追加しない。
optional_tools="$(optional_tools_notice)"
if [ -n "$optional_tools" ]; then
  echo "$optional_tools" >&2
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
