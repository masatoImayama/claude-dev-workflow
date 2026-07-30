# Dev Workflow Plugin for Claude Code

3エージェント自律開発ワークフロー。  
Docker sandbox内でplanner・generator・evaluatorによる仕様策定から自律実装までを一気通貫で行うClaude Codeプラグイン。

## インストール

### 1. マーケットプレイスを追加

```bash
claude plugin marketplace add https://github.com/masatoImayama/claude-dev-workflow-marketplace.git
```

### 2. プラグインをインストール

```bash
claude plugin install dev-workflow@dev-workflow-marketplace
```

### 3. セッションを再起動

```bash
claude
```

### プラグインの更新（インストール済みの場合）

プラグインが更新された場合、以下の手順で再反映できます:

```bash
# 方法1: マーケットプレイスを更新してリロード
/plugin marketplace update dev-workflow-marketplace
/reload-plugins
```

```bash
# 方法2: 再インストール
/plugin uninstall dev-workflow@dev-workflow-marketplace
/plugin install dev-workflow@dev-workflow-marketplace
/reload-plugins
```

### ローカルでテスト（インストール不要）

```bash
claude --plugin-dir /path/to/dev-workflow
```

## 前提条件

- [GitHub CLI (`gh`)](https://cli.github.com/) がインストール・認証済み
- [Docker](https://docs.docker.com/get-docker/) がインストール・起動済み
- Git リポジトリ内で実行
- プロジェクトルートに `Dockerfile.dev` または `docker-compose.dev.yml` を配置
- 上記が満たされない場合、セッション開始時にブロックされます

### 自動設定（SessionStart時）

プラグインのセッション開始フックが以下を自動的に行います:

- **`gh auth setup-git`** — gitの認証をgh CLIに委任し、push/PR作成時のアカウント選択ポップアップを防止
- **Docker起動チェック** — Docker デーモンが未起動の場合にブロック

## Docker sandbox のセットアップ

プロジェクトルートに開発用Dockerfileを配置してください:

```dockerfile
# Dockerfile.dev の例
FROM node:20-alpine
WORKDIR /workspace
COPY package*.json ./
RUN npm ci
# テスト・ビルドに必要なツールをインストール
```

DB等の依存サービスが必要な場合は `docker-compose.dev.yml` を使用:

```yaml
# docker-compose.dev.yml の例
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/workspace
    working_dir: /workspace
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: dev
```

## コマンド

### 段階的に実行

```
/dev-workflow:plan ユーザーがワンクリックで作業を開始できるボタンを追加したい
```
→ planner がヒアリング → 仕様書・計画書作成 → GitHub issue作成 → **ユーザー承認で停止**

```
/dev-workflow:run #123
```
→ 承認済みEpicに対して Docker sandbox内で generator + evaluator が**YOLOモードで完全自律実装**

### 全自動

```
/dev-workflow:goal リアルタイムで他ユーザーの存在が分かるプレゼンス機能を実装したい
```
→ plan → ユーザー承認 → Docker sandbox内でYOLO run を一気通貫

### 個別スキル

```
/dev-workflow:grill-me WebSocket経由のリアルタイム通知を検討したい
/dev-workflow:spec notifications
/dev-workflow:epic notifications
```

## 3エージェント

| エージェント | 役割 | モデル | 特徴 |
|---|---|---|---|
| **planner** (紫) | 仕様ヒアリング・計画・issue管理 | Opus | 書き込み可 |
| **generator** (青) | Docker sandbox内でコード実装・テスト | Sonnet | worktree隔離 + Docker |
| **evaluator** (緑) | Epic完了時に全差分を一括レビュー | Opus | 読み取り専用 + Docker |

## ワークフロー

```
/plan [自然言語の指示]
  │
  ├─ planner: 仕様ヒアリング（1問ずつ）
  ├─ planner: 仕様書・実装計画書作成
  ├─ planner: Epicブランチ作成 (epic/epicXX/[機能名])
  ├─ planner: Epic issue作成（仕様書・計画書を本文に添付）
  ├─ planner: Task issue 作成
  └─ ユーザー承認待ち
        │
        ▼
/run #[epic番号]  [YOLO]
  │
  ├─ Epicブランチの確認
  ├─ Docker sandbox 起動
  ├─ タスク選定（Phase順・自動）
  ├─ generator: Docker sandbox内でEpicブランチ上に実装 + テスト
  ├─ 機械的ゲート: テスト・ビルド・可読性ガード（LLM呼び出しなし）
  ├─ 通過 → Epicブランチにマージ → 次のタスクへ
  ├─ 失敗 → generatorに差し戻し（3回で当該タスクをスキップ）
  │
  ├─ 【全タスク完了後】evaluator: main...epic の全差分を一括レビュー
  ├─ 指摘(high/medium) → review issue化 → generatorが対応 → 差分のみ再レビュー
  ├─ 最大2巡で打ち切り（残りはissueを開いたままPR本文に明記）
  ├─ main向けPR作成（人間がレビュー・マージ）
  └─ Docker sandbox クリーンアップ
```

### レビューをEpic単位でまとめる理由

レビューは最もコストの高い工程で、タスクごとにOpusで全文脈を読み直すと
**レビュー費用が実装費用を上回る**。そこでevaluatorの起動をEpic単位に集約している。

| | 旧（タスクごと） | 現（Epic一括） |
|---|---|---|
| evaluator起動回数 | タスク数 × 差し戻し回数 | **1〜3回（タスク数に非依存）** |
| タスクごとの品質担保 | Opusレビュー | テスト・ビルド・可読性ガード（機械的・LLM不要） |
| 指摘の扱い | その場で差し戻し | **issue化してgeneratorが対応** |
| 打ち切り | 3回REQUEST_CHANGESでスキップ | 2巡で打ち切り、残りは人間のPRレビューへ |

副次的な効果として、レビュアーが**タスクをまたいだ整合性**（重複実装、
タスク間で食い違う命名やデータ構造、仕様の実装漏れ）を見られるようになる。
タスク単位のレビューでは原理的に見えなかった観点。

## ブランチ戦略

```
main (保護: 人間のみマージ可)
 ├─ epic/epic10/feature-a  ← Epic #10 の全タスク
 ├─ epic/epic11/feature-b  ← Epic #11 の全タスク（並行開発可）
 └─ ...
```

- 各Epicは専用ブランチで開発し、mainには直接変更を加えない
- 複数Epicの並行開発に対応（ブランチ・Docker sandboxが独立）
- 各タスク開始前にEpicブランチを最新に同期（古いベースからの分岐を防止）
- 全タスク完了後にmain向けPRを作成し、人間がレビュー・マージする

### worktree運用の注意

`node_modules` 等がsymlinkの場合、`git worktree remove --force` がsymlink越しにメインリポの実体ファイルを削除する。worktree削除前に必ずsymlinkを解除すること。

## YOLOモード（完全自律動作）

実装フェーズ（run）ではユーザー確認を一切行わず完全自律で動作する。

### パーミッション設定（必須）

YOLOモードではClaude Code本体のパーミッション確認を無効化する必要がある。
プロジェクトの `.claude/settings.json` に許可・拒否コマンドを設定する:

```json
{
  "permissions": {
    "deny": [
      "Bash(rm *)",
      "Bash(rm)",
      "Bash(rmdir *)",
      "Bash(unlink *)",
      "Bash(shred *)",
      "Bash(* rm *)",
      "Bash(* rmdir *)",
      "PowerShell(Remove-Item *)",
      "PowerShell(* Remove-Item *)",
      "PowerShell(del *)",
      "PowerShell(* del *)",
      "PowerShell(rd *)",
      "PowerShell(* rd *)"
    ],
    "allow": [
      "Bash(*)",
      "PowerShell(*)",
      "Edit",
      "Write",
      "NotebookEdit"
    ]
  }
}
```

> **ルール優先度:** `deny` は `allow` より常に優先される。  
> `rm` 系コマンドはパイプや `&&` 経由でも個別にブロックされる。  
> プロジェクトのビルド・テストコマンドは `allow` に追加してください。

### 自律動作ポリシー

- ユーザーへの質問・確認は行わない
- 問題発生時はissueにコメントを残してスキップし、次のタスクへ進む
- 同一タスクで機械的ゲート（テスト・ビルド・可読性）に3回失敗 → スキップ
- テスト5回連続失敗 → スキップ
- スキップしたタスクはPR本文に明示される
- Epic一括レビューは最大2巡。未対応の指摘はissueを開いたままPR本文に明示される

### テスト時の注意事項

- **メール送信:** テスト実行時に実ユーザーにメールが送信されないよう細心の注意を払うこと。テスト用の受信アドレス（mailhog, mailtrap等）が設定されていない場合は、タスクを中断し、issueにコメントを残して開発者（人間）にテスト用メール設定を促すこと
- **本番データの保護:** いかなる理由においても本番環境のデータを編集・削除・変更しないこと。本番データは常に非侵襲であること。テスト時はDocker sandbox内のテスト用データベースのみを使用すること

## 可読性ガード

**「ソースを読めば何をしているのか分かる」状態を、AIの自律判断に関わらず決定論的に守る機構。** 可読性を犠牲にした効率化（コンテンツの base64+gzip 化、ミニファイ/難読化されたソースのコミット、元の人間可読ソースの消失）を抑止する。

### 仕組み（多層防御）

| 層 | 内容 |
|---|---|
| **フック**（中核） | `PostToolUse(Write/Edit)` と `Stop` で `check-readability.sh` が変更を走査。違反を検出すると**ブロックし、理由をエージェントに差し戻す**（自己修正ループ）。AIの判断に依存しない |
| **git pre-commit**（任意） | CLIを問わず、コミット時にステージ済みの変更を走査してブロックする。下記で設置する |
| **generator** | 「ソースは人間可読／生成物を正本にしない／元ソースを必ず残す」を最優先ルールとして遵守 |
| **evaluator** | Epic一括レビューで可読性違反を**重要度「高」の必須対応指摘**として扱う |

### git pre-commit への設置（ベンダー非依存の最終防衛線）

CLIのフックは「編集直後の即時フィードバック」を担いますが、素の `git commit` や別のツールから
編集された場合は通りません。git 側にも同じガードを置くと、どこから編集してもコミットは通らなくなります。

```bash
# 設置（既存の pre-commit がある場合は壊さず追記する）
bash "${CLAUDE_PLUGIN_ROOT}/adapters/common/install-git-hooks.sh" .

# 解除
bash "${CLAUDE_PLUGIN_ROOT}/adapters/common/install-git-hooks.sh" --uninstall .
```

一時的に回避する場合は `READABILITY_GUARD=off git commit ...` とします。

### 検出するもの

- 巨大な base64 ブロブ（コンテンツ/データをエンコードしてソースに埋め込む）
- 極端に長い行（ミニファイ/難読化されたコードのコミット）

### 誤検知対策

- **許可リスト:** lock ファイル、`__snapshots__`、`fixtures`/`testdata`、`node_modules`/`vendor`、`*.min.*`、`*.svg`、`*.generated.*`、gitignore 済みファイル等は自動で除外
- **エスケープハッチ:** どうしてもエンコード済みデータが必要な場合、ファイル内に `readability-guard:allow <理由>` と書くと当該ファイルを除外。**人間可読な正当化をソースに残させる**ことで抑止の理念と整合させる

### 調整（環境変数）

```bash
READABILITY_GUARD=off          # ガード全体を無効化
READABILITY_MAX_BASE64=2000    # 連続base64文字列の許容上限（文字数）
READABILITY_MAX_LINE=5000      # ソース1行の許容上限（文字数）
```

### ブロック契約（マルチベンダー対応）

違反の通知方法はCLIごとに契約が異なるため、実行中のCLIを自動判定して出し分けます。

| 実行環境 | 判定条件 | 通知方法 |
|---|---|---|
| Claude Code | 既定 | `exit 2` + stderr |
| Codex CLI | `PLUGIN_ROOT` が設定済み、または入力JSONに `turn_id` がある | `exit 0` + stdout に `{"continue": false, ...}` |
| git pre-commit | インストーラが `DEV_WORKFLOW_HOOK_VENDOR=exit-code` を設定 | `exit 1` + stderr |

`DEV_WORKFLOW_HOOK_VENDOR=claude|codex|exit-code` で自動判定を上書きできます（デバッグ・CI用）。

## サンドボックス設定

実装・テストに使うコンテナの設定は環境変数を正本として解決します（plugin userConfig は
他CLIに相当物がないため）。

```bash
DEV_WORKFLOW_DOCKER_IMAGE=my-image:tag      # 既存イメージを使う（ビルドしない）
DEV_WORKFLOW_DOCKER_COMPOSE_FILE=path.yml   # 使用する compose ファイル
DEV_WORKFLOW_DOCKERFILE=path                # 使用する Dockerfile（既定: Dockerfile.dev）
```

未設定の場合は `Dockerfile.dev` → `docker-compose.dev.yml` の順に探索します。
現在の解決結果は次のコマンドで確認できます。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-sandbox.sh" --print
```

## Slack通知

**自律実行の完了・許可プロンプトをSlackに通知する。** 長時間の自律実行を放置しておいて、止まったタイミングだけ気づける。

### 設定（プロジェクトごと）

通知先はプロジェクト単位で設定する。**未設定のプロジェクトでは通知は一切行われない（通知OFF扱い）。**

1. Slackで [Incoming Webhook](https://api.slack.com/messaging/webhooks) を作成し、URLを取得
2. プロジェクトルートに `.claude/slack-webhook` を作成

```
# .claude/slack-webhook
name=tessera (API)
https://hooks.slack.com/services/XXX/YYY/ZZZ
```

- `https://` で始まる最初の行がWebhook URL（必須）
- `name=` 行は通知に表示するプロジェクト名（任意、既定はディレクトリ名）
- `mention=` 行はメンション先（任意、**既定は `channel` ＝ 全通知が `@channel`**）
- `#` 始まりの行はコメント

`mention=` に指定できる値:

| 値 | 動作 |
|---|---|
| `channel`（既定） | `@channel` — チャンネル全員に通知 |
| `here` | `@here` — オンラインのメンバーのみ |
| `none` | メンションなし |
| `<@U123ABC>` | 特定ユーザーへのメンション（SlackのメンバーID） |

3. **`.claude/slack-webhook` は必ず `.gitignore` に追加する**（Webhook URLは秘密情報）

```bash
echo ".claude/slack-webhook" >> .gitignore
```

環境変数 `SLACK_WEBHOOK_URL` / `DEV_WORKFLOW_PROJECT_NAME` でも指定できる（ファイル設定が優先）。メンションは `DEV_WORKFLOW_SLACK_MENTION` で上書きでき、こちらはファイル設定より優先される。

### 通知されるタイミング

| タイミング | フック | 内容 |
|---|---|---|
| **許可プロンプト表示** | `Notification` | `:lock: 承認待ち` — ファイルアクセス等の承認でエージェントが止まったとき |
| **入力待ちで放置** | `Notification` | `:hourglass: 入力待ち` — **既定でOFF**（下記） |
| **自律実行の完全な完了** | skill | `:white_check_mark: 完了` — 全タスク完了＋PR作成まで到達したとき |
| **自律実行の途中停止** | `Stop` | `:octagonal_sign: 自律実行が停止` — 完了に到達せず止まったとき |
| **通常の応答完了** | `Stop` | `:white_check_mark: 応答完了` — 既定でOFF（下記） |

通知は必ず `[プロジェクト名]` から始まり、ブランチ名と作業ディレクトリも添えられるため、複数プロジェクトを並行実行していても発信元が分かる。

### 「入力待ち」通知が既定でOFFの理由

`Notification` フックは、人の操作を必要としない場面（サブエージェントの切り替え、LLMの応答待ちなど）でも発火する。**それらとユーザー入力待ちを文言で区別できなかった**ため、待たせていないタイミングで通知が飛び続けた。

そこで **`:hourglass: 入力待ち` は既定で送信しない**。実際に人を止めているのは承認プロンプトであり、そちらは引き続き通知される。

どうしても入力待ちも受け取りたい場合のみ、明示的に有効化する:

```json
// .claude/settings.json
{
  "env": {
    "DEV_WORKFLOW_NOTIFY_IDLE": "1"
  }
}
```

承認待ち・入力待ちのいずれの文言にも一致しない通知は、従来どおり黙って捨てられる。

同じ内容の通知が繰り返し発火した場合に備え、**同一内容は既定で10分間抑止される**。間隔は `DEV_WORKFLOW_NOTIFY_COOLDOWN`（秒、`0` で無効）で変更できる。

それでも不要な通知が届く場合は `DEV_WORKFLOW_NOTIFY_DEBUG=1` を設定すると、受け取った payload が `.claude/.dev-workflow-notify.log` に記録され、どの文言で発火しているか確認できる。

### 「完全な完了」と「途中停止」の区別

`Stop` フックは毎ターン発火するだけで、自律実行がやり切ったのか途中で止まったのかを区別できない。そこでマーカーファイルで判別する:

1. `/run`・`/goal` はループ開始時に `.claude/.dev-workflow-run` を作成する
2. **PR作成まで到達した場合のみ** `run-complete` を実行 → マーカーを消して `:white_check_mark: 完了`（PR URL付き）を通知
3. マーカーが残ったまま `Stop` した場合 → 完了地点に到達していない ＝ `:octagonal_sign: 自律実行が停止` を通知

これにより、**エラーで落ちた・承認待ちで止まった・コンテキストが尽きた**といった「静かな失敗」も取りこぼさずに通知される。停止通知は鳴り続けないよう1回だけ送られる。

マーカーは一時ファイルなので `.gitignore` に追加しておく:

```bash
echo ".claude/.dev-workflow-*" >> .gitignore
```

（通知の抑止状態を持つ `.claude/.dev-workflow-notify-last` とデバッグログも同じパターンで除外される）

### 通常の応答完了通知の有効化

自律実行と関係ない通常のターン終了は、毎ターン鳴ってしまうため既定でOFF。必要なプロジェクトでのみ有効にする:

```json
// .claude/settings.json
{
  "env": {
    "DEV_WORKFLOW_NOTIFY_STOP": "1"
  }
}
```

> **注意:** `--dangerously-skip-permissions`（完全なYOLO）では許可プロンプト自体が発生しないため、承認待ち通知も発生しない。`/run`・`/goal` は allowlist ベースで動作するため、許可されていない操作に当たった際は通知される。
>
> 停止通知・応答完了通知の要約表示には `jq` が必要（未インストールでも通知自体は届く）。「完了」通知はskillが渡すサマリーを使うため `jq` は不要。

## プロジェクト固有のカスタマイズ

エージェントはプロジェクトの `CLAUDE.md` と `.claude/rules/` を自動的に読み込みます。  
プロジェクト固有のルール（コーディング規約、禁止事項、設計思想）はそこに記載してください。

## Codex CLI で使う

このプラグインは Claude Code と Codex CLI の**両方のプラグイン**として動作します。
Claude Code が利用不能になったときのフェイルオーバー先として、平常時に用意しておくことを推奨します。

役割定義・ワークフロー規約・可読性原則・安全ルールは両CLIで**同じ `core/` を正本**にしているため、
どちらで作業しても同じルールで動きます。

### 導入

```bash
# 1. マーケットプレイスとプラグインを追加
codex plugin marketplace add masatoImayama/claude-dev-workflow-marketplace
codex plugin add dev-workflow@dev-workflow-marketplace

# 2. サブエージェント定義をプロジェクトに設置
#    （Codexのプラグインは agents を配布できないためコピーが必要）
bash "${CLAUDE_PLUGIN_ROOT}/adapters/codex/install-agents.sh" .

# 3. 生成物をコミット（障害時に生成処理を実行できない可能性があるため）
git add .codex/agents/ && git commit -m "chore: Codex用サブエージェント定義を配置"
```

Codex 側のスキルは `dev-workflow-plan` / `dev-workflow-run` / `dev-workflow-goal` /
`install-codex-agents` です。初回はプラグイン同梱フックの**信頼付与**を求められます
（承認しないと可読性ガードが働きません）。

### 無人で回す

```bash
bash "${CLAUDE_PLUGIN_ROOT}/adapters/codex/run-loop.sh" <Epic issue番号>
```

ループをシェル側に置き、1回の `codex exec` = 1役として起動するため、役割ごとに文脈が分離されます。
`DEV_WORKFLOW_DRY_RUN=1` を付けると実行内容の確認だけができます。

### Claude Code との差分

| 項目 | Claude Code | Codex |
|---|---|---|
| 役割ごとのモデル指定 | `agents/*.md` の `model` | `.codex/agents/*.toml` の `model`（既定は継承。環境変数で指定可） |
| レビュアーの書き込み禁止 | `disallowedTools: Write, Edit` | `sandbox_mode = "read-only"` |
| ターン数の上限 | `maxTurns` | **相当機能なし。** ループ側の反復上限とプロンプト規約で担保 |
| サブエージェント専用worktree | `isolation: worktree`（自動） | **なし。** generator を並行実行しない設計 |
| 判定JSONの強制 | なし（本文から読み取り） | `--output-schema` でスキーマ強制 |
| 「入力待ち」Slack通知 | `Notification` フック | **なし**（Codexに該当イベントがない） |

## このプラグイン自体を開発する場合

`agents/*.md` と `codex-agents/*.toml` は**生成物**です。直接編集しないでください。

| ファイル | 内容 |
|---|---|
| `core/instructions.md` | ベンダー中立なハーネス共通ルール（ワークフロー・規約・可読性原則・安全ルール） |
| `core/roles/*.md` | ベンダー中立な役割定義（planner / generator / evaluator） |
| `adapters/claude/overlays/*.md` | Claude Code固有のfrontmatterと補足 → `agents/*.md` |
| `adapters/codex/overlays/*.toml` | Codex固有のTOMLキーと補足 → `codex-agents/*.toml` |

```bash
# core/ や overlays/ を編集したら両方を再生成する
bash adapters/claude/build.sh
bash adapters/codex/build.sh

# 生成物が正本と一致しているか検証する（差分があれば exit 1）
bash adapters/claude/build.sh --check
bash adapters/codex/build.sh --check
```

**`core/` を編集したら両方を再生成し、生成物をコミットに含めてください。**

設計方針は [docs/dev-workflow-multi-vendor-guide.md](docs/dev-workflow-multi-vendor-guide.md) を参照してください。

## ライセンス

MIT
