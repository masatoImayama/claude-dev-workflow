# Epic #42 ウェーブ2 の未コミット作業の退避（一時ブランチ）

このブランチ `wip/epic42/wave2-salvage` は、PC 再起動をまたぐために
未コミットだった作業を git に載せただけのものです。**epic ブランチにはマージしません。**

## 経緯

- Task #44（heartbeat.sh）: エージェントを一時停止したため未コミットだった
- Task #45（watchdog.sh）: API エラー（ENOTFOUND）で途中終了し未コミットだった

いずれも実装の実体は残っていたので退避した。

## 中身

| パス | 内容 | 元のベース |
| --- | --- | --- |
| `scripts/heartbeat.sh` | Task #44 の実装（110行） | `816c07c` |
| `scripts/watchdog.sh` | Task #45 の実装（333行） | `3367106` |
| `.wip-salvage/task44-tests.patch` | Task #44 のテスト差分（206行） | `816c07c` |
| `.wip-salvage/task45-tests.patch` | Task #45 のテスト差分（314行） | `3367106` |

テスト差分は `tests/run-tests.sh` の末尾追加同士で競合するため、統合せずパッチのまま置いた。
再開時は epic ブランチの最新に対して**末尾に追加し直す**のが確実。

## 再開手順

1. `epic/epic42/run-watchdog` を最新にする
2. このブランチから `scripts/heartbeat.sh` / `scripts/watchdog.sh` を取り出す
   （`git checkout wip/epic42/wave2-salvage -- scripts/heartbeat.sh`）
3. 内容を読んで正しさを確認する（**どちらも完走した報告が無いため無検証**）
4. テストは `.wip-salvage/*.patch` を参考に、最新の `tests/run-tests.sh` の末尾へ追加し直す
5. サンドボックスでゲート3点を通してからコミットする

## 破棄してよいタイミング

Task #44 と #45 が epic ブランチにマージされたら、このブランチは削除してよい。
