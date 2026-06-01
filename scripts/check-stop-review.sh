#!/bin/bash
# dev-workflow plugin: Stop時のレビューチェック
# git差分がある場合のみレビュー指示を出す
# 差分がなければ何も出力せずexit 0

# gitリポジトリでなければスキップ
if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
  exit 0
fi

# ステージ済み or 未ステージの変更があるかチェック
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
  # 変更なし — スキップ
  exit 0
fi

# 変更あり — レビュー指示を出力
echo "作業が完了しました。変更内容をレビューし、テストが全て通っているか確認してください。問題があれば修正してください。"
exit 0
