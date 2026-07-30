---
name: dev-workflow-plan
description: 機能要求を仕様ヒアリングして仕様書・実装計画書にまとめ、GitHubのEpic/Task issueとEpicブランチを作成し、承認待ちで停止する。
---

# Dev Workflow Plan（Codex）

機能要求を、承認可能な実装計画に変換する。**issue作成まで行い、実装は始めない。**

## 前提

`.codex/agents/planner.toml` が設置されていること。未設置なら `install-codex-agents` を先に実行する。

役割定義・issue管理ルール・タスク粒度・ブランチ命名規則は**planner エージェント側に埋め込まれている**。
このスキルは起動と受け渡しだけを担う。

## 手順

`planner` エージェントを起動し、以下を渡す。

```
「<ユーザーの要求>」について計画フェーズを実行してください。

1. ユーザーに1つずつ質問し、仕様を確定させる（推奨案を添えること）
2. 仕様書と実装計画書を作成する（ファイル出力は不要）
3. Epic issue を作成する（epicラベル、仕様書・計画書を <details> で本文に埋め込む）
4. Epic issue番号を使って epic/epic<番号>/<機能名> ブランチを作成・push する
5. 各タスクの Task issue を作成する（taskラベル）
6. Epic issue 本文に Task issue のチェックリストを追記する
7. 成果物一覧を表示してユーザーに確認を求める
```

## 停止条件

planner が成果物一覧を出したら**そこで止まる。** ユーザーの承認を待つ。

承認されたら次の案内を出す。

```
確認後 dev-workflow-run スキルに Epic issue 番号を渡すと自律実装を開始できます。
一気通貫で進める場合は dev-workflow-goal を使います。
```

## ヘッドレス実行時の注意

`codex exec` から起動された場合は対話できない。その場合は質問せず、
Epic issue に「未確定事項」セクションを設けて列挙し、確定できた範囲で計画を作る。
