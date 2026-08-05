# dev-workflow マルチベンダー対応設計指示書

## 1. 本指示書の目的

dev-workflowは現在Claude Code専用のgitプロジェクトとして構築されており、各プロジェクトにプラグインとしてインストールして利用するハーネス（開発ワークフロー基盤）である。

本指示書は、Claude Codeが障害等で利用不能になった際に、OpenAI Codex CLIなど別ベンダーのコーディングエージェントへ即座にフェイルオーバーできるよう、dev-workflowをマルチベンダー対応に改修するための設計方針と具体的な手順を定める。

### 1.1. 背景と動機

- Claude Codeのハーネスを使って実装を進めていた際、障害で利用不能になった経験がある
- その際、同一のハーネス（ワークフロー定義・開発ルール・スキル）を別ベンダーのCLIでそのまま稼働させ、作業を継続したい
- ただし、各CLIが提供するリッチなUX（差分表示、承認フロー、コンテキスト管理など）を損なうことは避ける

### 1.2. 基本方針：共通化すべきはドキュメントであり、コードではない

当初検討したアプローチ（共通Skill抽象基盤クラス＋スキーマ変換アダプター＋自前オーケストレーターによるAPI直接制御）は、以下の理由で不採用とする。

- Claude Code・Codex CLIとも、ファイル操作やターミナル実行などのツールは各CLI内部に組み込み済みであり、共通Skillを外部に自作する意味がない
- 自前オーケストレーターを構築すると、各CLIのリッチなUX（差分プレビュー、承認フロー、セッション管理など）を全て失う
- MCPサーバーなどの外部インフラ構築も、この目的には過剰

代わりに採用するアプローチは、**プロジェクトコンテキスト（指示・ルール・進捗状態）のポータビリティ確保**である。各CLIのネイティブ機能はそのまま活かし、「何をやるか・どういうルールか」を記述するドキュメント層のみを共通化する。

---

## 2. 現在のワークフロー構造の確認

### 2.1. dev-workflowの役割

dev-workflowは各プロジェクトにプラグインとしてインストールされ、開発ルールの基礎的な部分（ハーネス本体）を提供する。プロジェクト固有の内容は各プロジェクト側に保持する。

### 2.2. ワークフローの運用フロー

1. **Planner**がGitHub Issueを作成する
2. **Generator**がIssueをもとにコード改変を行う
3. **Evaluator**がIssueをもとにレビュー・フィードバックを行う

### 2.3. ベンダー中立性における現在の強み

ワークフローの状態管理がGitHub Issuesに置かれている点は、すでにベンダー中立である。Issues はどのCLIからも読み書きでき、planner → generator → evaluator の流れ自体はCLIに依存していない。ファイル状態もgit履歴もCLI間で共有される。

---

## 3. Claude Code と Codex CLI の構造比較

本章の内容は Codex CLI 0.146.0 と公式マニュアルで実測・確認済みである（初版は未検証の推測を含んでいたため全面的に差し替えた）。

### 3.1. 指示ファイル・設定ディレクトリの対照表

| 項目 | Claude Code | Codex CLI |
| --- | --- | --- |
| プロジェクト指示ファイル | `CLAUDE.md`（プロジェクトルート） | `AGENTS.md`（プロジェクトルート） |
| 個人用指示ファイル | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` |
| 設定ディレクトリ | `.claude/` | `.codex/` |
| 設定ファイル | `.claude/settings.json` | `~/.codex/config.toml` / `<project>/.codex/config.toml` |
| **サブエージェント定義** | **`agents/*.md`（frontmatter + 本文）** | **`.codex/agents/*.toml` / `~/.codex/agents/*.toml`** |
| スキル | `.claude/skills/xxx/SKILL.md` | **`.agents/skills/xxx/SKILL.md`**（プロジェクト）/ `~/.agents/skills/` |
| **フック定義** | **`hooks/hooks.json`** | **`hooks/hooks.json`（プラグイン）/ `.codex/hooks.json` / config.toml インライン** |
| 実行ポリシー | `settings.json` の `permissions` | `.codex/rules/*.rules`（`codex execpolicy`） |
| プラグインマニフェスト | `.claude-plugin/plugin.json` | `.codex-plugin/plugin.json` |
| マーケットプレイス | `.claude-plugin/marketplace.json` | `~/.agents/plugins/marketplace.json` / `<repo>/.agents/plugins/marketplace.json` |
| プラグイン管理コマンド | `/plugin` | `codex plugin add\|list\|marketplace\|remove` |
| ヘッドレス実行 | — | `codex exec` |
| セッション | `~/.claude/projects/` | `~/.codex/sessions/` |
| プロジェクトルート判定 | — | `project_root_markers`（既定 `.git`） |

初版で `.codex/skills/` と記載していた箇所は誤りで、正しくは **`.agents/skills/`** である。`.agents/` というベンダー中立に見えるパスが使われている点に注意。

### 3.2. 共通点は Agent Skills だけではない

初版は「Agent Skills 標準が共通」という1点のみを共通基盤として挙げていたが、実際にはもっと広い。

#### 3.2.1. Agent Skills（`SKILL.md`）

YAMLフロントマター + Markdown本体 + `scripts/` `references/` `assets/` の構造は共通。
Codex は加えて `agents/openai.yaml` によるUI表示メタデータ（`display_name`, `short_description`,
`icon_small`, `icon_large`, `default_prompt`）を持つ。これは任意項目である。

#### 3.2.2. フック定義スキーマが同一

両者とも以下の構造を取る。

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "...", "timeout": 30, "statusMessage": "..." }
        ]
      }
    ]
  }
}
```

さらに Codex はプラグインルートの **`hooks/hooks.json`** を既定で探索する。これは Claude Code と同じパスである。

#### 3.2.3. `CLAUDE_PLUGIN_ROOT` が Codex でも設定される

Codex はプラグインフックの実行時に `PLUGIN_ROOT` / `PLUGIN_DATA` に加えて、
**`CLAUDE_PLUGIN_ROOT` / `CLAUDE_PLUGIN_DATA` を互換目的で設定する**（公式マニュアル記載）。

したがって現行の `hooks/hooks.json` と `${CLAUDE_PLUGIN_ROOT}/scripts/*.sh` という参照は、
**Codex 側でもほぼそのまま機能する。**

#### 3.2.4. プラグイン + マーケットプレイス配布モデルが同型

`.claude-plugin/plugin.json` と `.codex-plugin/plugin.json` は**別ファイル名なので同一リポジトリに共存できる**。
どちらも `skills` と `hooks` のパスを指すため、**1つのリポジトリを両CLIのプラグインとして同時に配布できる。**
これが第4章で「1プラグインに統合」を採る根拠である。

### 3.3. サブエージェント（Codex の `multi_agent`）

`codex features list` で `multi_agent` は **stable / 有効**。組み込みエージェントとして
`default` / `worker` / `explorer` を持ち、同名の定義で上書きできる。

#### 3.3.1. カスタムエージェントのスキーマ

| 必須 | フィールド | 内容 |
| --- | --- | --- |
| ✓ | `name` | 起動時に参照する名前（`name` が正本。ファイル名は慣習） |
| ✓ | `description` | どんなときに使うかの説明 |
| ✓ | `developer_instructions` | エージェントの振る舞いを定義する中核指示 |

加えて `config.toml` のキーを併記できる（`model`, `model_reasoning_effort`, `sandbox_mode`,
`mcp_servers`, `skills.config` 等）。省略した設定は親セッションから継承される。

グローバル設定は `[agents]`（`enabled`, `max_concurrent_threads_per_session`,
`default_subagent_model`, `default_subagent_reasoning_effort`, `interrupt_message`）。

#### 3.3.2. frontmatter の対応表

| Claude Code `agents/*.md` | Codex `.codex/agents/*.toml` |
| --- | --- |
| `name` | `name` |
| `description` | `description` |
| 本文（システムプロンプト） | `developer_instructions` |
| `model: sonnet` / `opus` | `model` |
| `effort: high` | `model_reasoning_effort` |
| `tools:` / `disallowedTools:` | `sandbox_mode`（`read-only` / `workspace-write` / `danger-full-access`。**粒度は粗い**） |
| `isolation: worktree` | **サブエージェント単位の相当物なし**（3.3.3参照） |
| `maxTurns` | **相当物なし**（3.3.4参照） |
| `color` | なし |

**重要な非対称性: サブエージェント定義はプラグインで配布できない。**
`.codex-plugin/plugin.json` がサポートするのは `skills` / `hooks` / `mcpServers` / `apps` / `interface` のみで、
`agents` は含まれない。したがって `.codex/agents/*.toml` は**プロジェクト側に設置する**必要がある。

#### 3.3.3. worktree 隔離の粒度

Codex の `[agents]` 配下のキーは `enabled` / `max_concurrent_threads_per_session`（旧名 `max_threads`）/
`default_subagent_model` / `default_subagent_reasoning_effort` / `interrupt_message` /
`<role>.config_file` / `<role>.description` のみで、**作業ディレクトリを指定するキーはない。**
カスタムエージェントの TOML にも `cwd` 相当は存在しない
（`cwd` はセッションおよびMCPサーバのフィールドとしては存在するが、エージェント設定にはない）。

一方、**セッション単位の worktree は第一級機能**である（`codex exec -C <DIR>`、デスクトップアプリの
worktree 作成、スケジュールタスクの worktree 実行、Local ↔ Worktree ハンドオフ）。
`sandbox_workspace_write.writable_roots` で書き込み可能ルートを追加することもできるが、
これは「許可の追加」であって隔離ではない。

| 粒度 | Claude Code | Codex |
| --- | --- | --- |
| セッション単位 | `.claude/worktrees/<epicN>` を run スキルが作成 | `codex exec -C <DIR>` / アプリの worktree 機能 |
| **サブエージェント単位** | **`isolation: worktree`（自動）** | **不可** |

**設計への影響:** generator を並行実行して衝突を避ける方式は Codex では取れない。
Epic ごとに1 worktree を割り当てて**逐次実行**するか、シェルループ側が worktree を割り当てて
`codex exec -C` で起動する方式のいずれかを採る（4.4.3参照）。

#### 3.3.5. レーンの並列起動（Epic #14）

`dev-workflow:run` のタスク実行を、Task issue が宣言した依存関係（`- 前提: #N`）から組む
依存グラフに基づく**ウェーブ単位の並列実行**に切り替えた（Epic #14）。このうち Claude/Codex で
対応が分かれるのは「レーンの並列起動」だけであり、それ以外は**共通仕様として `core/instructions.md`
に規定し、両アダプタに同一の規約として適用する。**

| 項目 | Claude Code | Codex |
| --- | --- | --- |
| `- 前提: #N` 記法・ウェーブの概念 | 適用 | 適用 |
| merge-base 検証・`--ff-only` 廃止・cherry-pick 廃止 | 適用 | 適用 |
| wave ブランチ経由の統合＋統合ゲート | 適用 | 適用（1レーンのウェーブとして） |
| **レーンの並列起動（`--lanes` > 1）** | **実装（既定 `--lanes 3`）** | **非対応。`lanes=1` 固定** |

Codex が非対応なのは 3.3.3 の worktree 隔離の粒度による制約（サブエージェント単位の隔離が無い
ため generator を並行実行できない）が理由であり、「仕様が違う」のではなく「設定値が固定されている
だけ」という位置づけである。Claude 版の `--lanes 1` と Codex 版はどちらも「1レーンのウェーブ」
として同じコードパスを通るため、両 run スキル（`skills/run/SKILL.md` /
`skills-codex/dev-workflow-run/SKILL.md`）の記述は一致する。

#### 3.3.4. ターン上限の相当物はない

`maxTurns: 200` / `120` に相当する設定は Codex に存在しない。最も近いのは
`features.rollout_budget`（`enabled` / `limit_tokens` / `prefill_token_weight` /
`reminder_interval_tokens` / `sampling_token_weight`）だが、これは

- **under development で既定オフ**
- ターン数ではなく**トークン予算**

であり、そのままの代替にはならない。

**設計への影響:** 暴走時の停止条件は以下で担保する。

1. シェルループ方式では**オーケストレーター側が反復回数を制御する**（`codex exec` 1起動＝1タスク）
2. `core/instructions.md` の打ち切り条件（同一タスク3回失敗でスキップ、レビュー最大2巡）を
   プロンプト側の規約として明記する（既に記載済み）
3. `features.rollout_budget` が stable になった時点で導入を再検討する

### 3.4. `codex exec`（ヘッドレス実行）

| オプション | 用途 |
| --- | --- |
| `-m, --model <MODEL>` | 起動ごとのモデル指定 |
| `-s, --sandbox read-only\|workspace-write\|danger-full-access` | 権限の機構的な制限 |
| `-C, --cd <DIR>` / `--add-dir <DIR>` | 作業ルート指定（worktree を指せる） |
| `--dangerously-bypass-approvals-and-sandbox` | 承認プロンプトを飛ばす（自律ループ用） |
| `--output-schema <FILE>` | **最終応答の形状を JSON Schema で強制** |
| `-o, --output-last-message <FILE>` | 最終メッセージをファイルに書き出す |
| `--json` | イベントを JSONL で stdout に出力 |

`--output-schema` は Claude Code に相当物がなく、evaluator の判定JSONを**スキーマで強制できる**。
現行の `run/SKILL.md` は応答本文からJSONを目視で拾っているため、**Codex 側の方が堅くなる。**

### 3.5. フックのイベントとブロック契約

#### 3.5.1. イベント一覧（Codex）

`PreToolUse` / `PermissionRequest` / `PostToolUse` / `PreCompact` / `PostCompact` /
`SessionStart` / `SessionEnd` / `SubagentStart` / `SubagentStop` / `UserPromptSubmit` / `Stop`

dev-workflow が使用する **`SessionStart` / `PostToolUse` / `Stop` はすべて存在する。**

#### 3.5.2. 唯一の実質的な差分：ブロック契約

| | Claude Code | Codex |
| --- | --- | --- |
| ブロック手段 | `exit 2` + stderr にメッセージ | stdout に JSON を出力 |
| JSON | — | `{"continue": false, "stopReason": "...", "systemMessage": "..."}` |
| 成功 | `exit 0` | `exit 0` かつ無出力 |
| `PostToolUse` | 対応 | `systemMessage` / `continue: false` / `stopReason` に対応 |
| `PreToolUse` | 対応 | **`systemMessage` のみ**（`continue` は非対応） |

`scripts/check-readability.sh` は現在 `exit 2` のみを返すため、**両契約を満たす二重出力に改修する**必要がある。
これが移植作業のほぼ全てである。

#### 3.5.3. 注意点

- プラグイン同梱フックは**明示的な信頼付与が必要**（インストールしただけでは実行されない）
- `timeout` は秒単位。省略時は多くのフックで 600 秒、`SessionEnd` のみ既定 1 秒（最大 3 秒）
- `type: "command"` のみ実行される（`prompt` / `agent` ハンドラはパースされるがスキップ）
- フックの実行ディレクトリはセッションの `cwd`。リポジトリローカルのフックは
  相対パスではなく git root からの解決を推奨（マニュアルの明示的な指示）
- `plugin-creator` の `validate_plugin.py` は `hooks` フィールドを拒否するが、
  これはスキャフォールド側の制約であり、マニュアルでは正式にサポートされている

### 3.6. 配布方式（Codex マーケットプレイス）

**結論: 既存の `claude-dev-workflow-marketplace` リポジトリをそのまま両CLI用に使える。**

#### 3.6.1. `source` の種別

| `source` | 用途 | 必須フィールド |
| --- | --- | --- |
| `local` | ローカルディレクトリ | `path`（マーケットプレイスルートからの相対、`./` 始まり） |
| `url` | Git リポジトリの**ルート**にプラグインがある | `url` |
| **`git-subdir`** | **Git リポジトリの<b>サブディレクトリ</b>にプラグインがある** | `url`, `path` |
| `npm` | JavaScript パッケージレジストリ | `package`（`version` / `registry` は任意） |

Git 系エントリは `ref` または `sha` セレクタを使える。
**これは現行の `.claude-plugin/marketplace.json` と同形である。**

```json
{
  "name": "dev-workflow",
  "source": {
    "source": "git-subdir",
    "url": "https://github.com/masatoImayama/claude-dev-workflow-marketplace.git",
    "path": "./plugins/dev-workflow",
    "ref": "master",
    "sha": "..."
  },
  "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
  "category": "Productivity"
}
```

Claude Code 側との差分は、Codex エントリでは **`policy.installation` / `policy.authentication` /
`category` が必須**という点のみ。解決できないエントリは**スキップされ、マーケットプレイス全体は壊れない。**

#### 3.6.2. マーケットプレイスファイルの探索パス

| パス | 用途 |
| --- | --- |
| `$REPO_ROOT/.agents/plugins/marketplace.json` | リポジトリ／チーム用（Codexネイティブ） |
| **`$REPO_ROOT/.claude-plugin/marketplace.json`** | **レガシー互換パス（Claude Code 形式をそのまま読む）** |
| `~/.agents/plugins/marketplace.json` | 個人用 |

**現行の `.claude-plugin/marketplace.json` がそのまま読まれる可能性がある**が、マニュアルの記述は
「ChatGPT デスクトップアプリが読める」という文脈であり、**CLI でも同じ探索が行われるかは未検証**である。
安全策として、Codexネイティブな `.agents/plugins/marketplace.json` を追加し、
両ファイルが同じ `plugins/dev-workflow` を指す構成にする。

なお `.claude-plugin/plugin.json` は `.codex-plugin/plugin.json` に**正規化変換される**仕組みも
存在するが（`claude_format_normalized`）、これは公開ポータルへの提出経路の記述であり、
ローカル配布で同じ変換が働くとは限らない。**`.codex-plugin/plugin.json` は明示的に用意する。**

#### 3.6.3. 導入コマンド

```bash
# GitHub ショートハンド / HTTPS / SSH / ローカルパスのいずれも可
codex plugin marketplace add masatoImayama/claude-dev-workflow-marketplace
codex plugin marketplace add https://github.com/masatoImayama/claude-dev-workflow-marketplace.git --ref master

codex plugin add dev-workflow@<marketplace-name>

# Git マーケットプレイスのスナップショット更新（配信後に利用者が実行する）
codex plugin marketplace upgrade <marketplace-name>
```

`--sparse <PATH>` を繰り返し指定すると Git ソースをスパースチェックアウトできる。
インストール先は `~/.codex/plugins/cache/$MARKETPLACE_NAME/$PLUGIN_NAME/$VERSION/`。
有効／無効の状態は `~/.codex/config.toml` に記録される。

`marketplaces.allowed_sources` で許可ソースを制限できる（`source = "git"` は `url`、
`source = "local"` は絶対パス、`source = "host_pattern"` はホスト名の正規表現）。

#### 3.6.4. 配信フローへの影響

現行の2コミット方式（内容更新 → SHA更新）は維持できるが、**SHA を2ファイルに書く**必要がある。

1. `plugins/dev-workflow/` を更新してコミット・push
2. そのコミットSHAを `.claude-plugin/marketplace.json` と
   `.agents/plugins/marketplace.json` の**両方**に書いてコミット・push

### 3.7. 任意依存の外部 MCP ツール（Epic #66）

context7（generator のみ）・code-review-graph（evaluator のみ）は**任意依存**として結線している
（決定は Epic #66 本文、実測は `docs/optional-mcp-tools.md` を参照）。設定場所と絞り込みの
「粒度」は Claude / Codex で異なるが、「どのエージェントに使えるか」という**結果は一致**しており、
機能差は無い。

#### 3.7.1. 設定場所の違い

| 項目 | Claude Code | Codex |
| --- | --- | --- |
| サーバー宣言 | `.claude-plugin/plugin.json` の `mcpServers`（セッション全体に1回宣言） | `adapters/codex/overlays/<role>.toml` の `[mcp_servers.<name>]`（結線したいエージェントのTOMLにだけ個別に書く。`.codex-plugin/plugin.json` には宣言しない） |
| エージェントへの絞り込み | サブエージェント frontmatter の `tools:` allowlist（ツール単位。例: `mcp__plugin_dev-workflow_context7__resolve-library-id`） | エージェントTOMLの `mcp_servers` キー自体の有無（サーバー単位。省略時は親セッションから継承） |
| 絞り込みの粒度 | **ツール単位**（context7 の2ツールを個別に列挙できる） | **サーバー単位**（ツール名での限定は不可。TOMLキー自体を書くか書かないかの二択） |

#### 3.7.2. 機能差の有無

**絞り込みの粒度は異なるが、機能差は無い。** 理由は次の2点。

1. Claude Code 側で `tools:` に列挙していないサブエージェントは、サーバーがセッション全体に
   宣言されていても当該ツールを呼べない（実測は `docs/optional-mcp-tools.md` 参照）。
   これは「セッション全体宣言＋ツール単位限定」で `generator にのみ使える` という結果を作る
2. Codex 側は `mcp_servers` をエージェントTOMLに個別に書くことで、そのエージェントにだけ
   サーバーを渡せる（`.codex-plugin/plugin.json` に宣言しなければ、キーを書いていない
   planner/evaluator には一切渡らない）。context7 はツールが2つしか無いため、
   サーバー単位の限定でも実質的にツール単位限定と同じ結果になる

したがって「context7 は generator にのみ、code-review-graph は evaluator にのみ使える」という
**結果**は両CLIで一致する（決定6・決定4）。詳細な実装は `core/roles/generator.md`
「Phase 3（#71）: context7 の結線方式（Claude / Codex の差分）」節、および
`core/roles/generator.md` 「Phase 4: code-review-graph の結線（#73）」節を参照（正本はそちら）。

#### 3.7.3. 同等にできない箇所とその理由・回避策

**Codex にはツール単位のallowlist機構が無い**（3.3.2の`tools:`対応表のとおり）。
仮に code-review-graph のように1サーバーに30ツールあるケースで「特定の数ツールだけ渡したい」
という要求が生じても、Codex 側はサーバー単位でしか絞り込めない（回避策なし。上流の
`mcp_servers.<id>.enabled_tools` 相当の機構が追加されない限り原理的に不可能）。

今回結線した2ツールはこの限界の影響を受けない。context7 はツールが2個しか無く実質的に
サーバー単位＝ツール単位が一致し、code-review-graph は「evaluatorに全30ツールを一括で渡す」
という設計（`core/roles/generator.md` 参照。恣意的に間引かない方針）のため、そもそも
ツール単位の絞り込みを必要としない。**将来、1サーバーの一部ツールだけをエージェントに
渡したいケースが出た場合は、Codex 側では実現できないことを設計時点で確認すること。**

---

## 4. dev-workflowの改修設計

### 4.0. 前提：dev-workflowはプラグインである

dev-workflowは単なるgitプロジェクトではなく、**Claude Code plugin** として実装・配布されている。

- `.claude-plugin/plugin.json` — プラグインマニフェスト（`name`, `version`, `userConfig` 等）
- `.claude-plugin/marketplace.json` — マーケットプレイス定義
- `agents/*.md` — サブエージェント定義
- `skills/*/SKILL.md` — スキル（スラッシュコマンド）
- `hooks/hooks.json` — フック定義
- 配布は別リポジトリ `claude-dev-workflow-marketplace` 経由（本体のコピー＋SHA更新）

インストール先は `~/.claude/plugins/...` 配下であり、**ユーザーがリポジトリのパスを直接指定して
スクリプトを実行することは想定できない。**

**設計原則: プラグイン構造を壊さない。両CLIに対してプラグインとして配布する。**

第3.2.4節のとおり `.claude-plugin/` と `.codex-plugin/` は共存できるため、
**1つのリポジトリを両CLIのプラグインとして同時に配布する**方針を採る（統合方針は 4.9 参照）。

### 4.1. 目標ディレクトリ構成

```
dev-workflow/
├── .claude-plugin/                 # Claude Code マニフェスト
│   ├── plugin.json
│   └── marketplace.json
├── .codex-plugin/                  # ★Codex マニフェスト（同一リポジトリに共存）
│   └── plugin.json                 #   skills: ./skills/, hooks: ./hooks/hooks.json
├── core/                           # ★ベンダー中立の正本
│   ├── instructions.md             #   ハーネス共通ルール
│   └── roles/                      #   3役割の中立な役割定義
│       ├── planner.md
│       ├── generator.md
│       └── evaluator.md
├── adapters/
│   ├── claude/
│   │   ├── overlays/*.md           #   frontmatter + Claude固有の補足 + include指示
│   │   └── build.sh                #   → agents/*.md を生成
│   ├── codex/                      # ★
│   │   ├── overlays/*.toml         #   TOMLキー + Codex固有の補足 + include指示
│   │   ├── build.sh                #   → codex-agents/*.toml を生成
│   │   └── install-agents.sh       #   codex-agents/*.toml → <project>/.codex/agents/
│   └── common/
│       └── install-git-hooks.sh    #   pre-commit に可読性ガードを設置
├── agents/                         # ★生成物（Claude Code が読む。直接編集禁止）
│   └── {planner,generator,evaluator}.md
├── codex-agents/                   # ★生成物（プロジェクトへコピーする雛形。直接編集禁止）
│   └── {planner,generator,evaluator}.toml
├── skills/                         # 両CLI共有（一部はベンダー別バリアントが必要。4.4参照）
├── hooks/hooks.json                # ★両CLI共有（スキーマ同一・探索パス同一）
├── scripts/*.sh                    # フック実装・通知（両契約対応に改修）
└── README.md
```

`hooks/hooks.json` が**無改造で共有できる**点が、初版設計から最も大きく変わったところである。

### 4.2. core/ ― ベンダー中立の正本

#### 4.2.1. instructions.md

ベンダー中立な指示・ルールを集約する。

含む内容：ワークフロー全体の概要、状態はGitHub issueとgitに置く原則、issueベースの作業管理ルール
（ラベル・タスク粒度・タスク選定順序）、ブランチ戦略、コミットメッセージ規約、可読性原則、
レビュー基準（重要度3段階・判定・Epic単位でまとめる理由）、サンドボックス方針、安全ルール、
プロジェクト固有ルールの参照方法。

**含めない内容**（ベンダー固有）：各CLIのツール名への直接参照、スラッシュコマンドの使用指示、
サブエージェント記法、フック・パーミッション・worktree isolation など各CLIの機構への依存。

#### 4.2.2. roles/

3役割の**役割定義と手順**を中立に記述する。「何をやるか」だけを書き、
「どのツールでやるか」「どう起動されるか」は書かない。

Claude Code では `agents/*.md` の本文になり、Codex では `.codex/agents/*.toml` の
`developer_instructions` の中身になる。

### 4.3. adapters/claude/ ― ビルドによる生成

#### 4.3.1. なぜ「参照」ではなく「生成」なのか

`agents/*.md` を「core/ を読みに行く薄いラッパー」にする案は**不採用**とした。

- `agents/*.md` はサブエージェントのシステムプロンプトとして読み込まれるため、
  内容を実行時に外部ファイルから取得させると、読み込み失敗が役割定義の欠落に直結する
- 参照先パスの解決に使える `${CLAUDE_PLUGIN_ROOT}` は**フック実行時にのみ注入される**環境変数であり、
  サブエージェントの `Bash` 実行時には未設定である（Claude Code 側で実測確認済み）
- 毎回の起動でファイル読み込みのターンを1つ消費する

したがって **core/ を正本とし、ビルド時に内容を展開して生成する。**
生成物はコミットするため、**実行時の挙動は改修前と変わらない。**

#### 4.3.2. overlays/ の構造

オーバーレイは「frontmatter」「include指示」「ベンダー固有の補足」の3要素で構成する。

```markdown
---
name: generator
model: sonnet
tools: Read, Grep, Glob, Bash, Write, Edit
disallowedTools: AskUserQuestion
maxTurns: 200
effort: high
isolation: worktree
---

<!-- 自動生成ファイル。編集しないこと。 -->
<!-- 再生成: bash adapters/claude/build.sh -->

<!-- include: core/roles/generator.md -->

<!-- include: core/instructions.md -->

## Claude Code 固有の補足
（ツールの使い分け / worktreeクリーンアップ / 可読性原則はフックで強制される）
```

#### 4.3.3. build.sh

`<!-- include: <リポジトリルートからの相対パス> -->` 行をファイル内容で置き換える単純な展開器。

```bash
bash adapters/claude/build.sh          # agents/*.md を生成
bash adapters/claude/build.sh --check  # 生成物が core/ と一致するか検証（差分があれば exit 1）
```

`--check` は生成物のドリフト検出用で、core/ を編集する開発時に実行する。
プラグイン利用者のセッションでは実行しない（フックには組み込まない）。

### 4.4. adapters/codex/ ― Codex 向けの生成

#### 4.4.1. サブエージェント定義の生成

Claude 側と同じ include 展開で `.codex/agents/*.toml` の雛形を生成する。
`developer_instructions` は TOML の複数行文字列（`"""`）として core を埋め込む。

```toml
name = "generator"
description = "実行者エージェント。GitHub issueに基づいてコードを実装・テストする。"
model = "gpt-5.4"
model_reasoning_effort = "high"
sandbox_mode = "workspace-write"
developer_instructions = """
<!-- include: core/roles/generator.md -->

<!-- include: core/instructions.md -->

## Codex 固有の補足
（shell ツールの使い方 / codex exec による起動前提 / 可読性原則はフックで強制される）
"""
```

evaluator は `sandbox_mode = "read-only"` とし、**レビュアーがコードを書けないことを機構で担保する。**
これは Claude Code 側の `disallowedTools: Write, Edit` と同じ意図である。

#### 4.4.2. プロジェクトへの設置

サブエージェント定義はプラグインで配布できない（3.3.2）ため、生成した TOML を
プロジェクトの `.codex/agents/` にコピーする手順が必要になる。

```bash
bash adapters/codex/install-agents.sh /path/to/project
```

プラグインからこれを起動できるようにするため、`skills/install-codex-agents/SKILL.md` を用意する。
プラグイン同梱スキルなので、リポジトリをcloneしていないユーザーでも実行できる。

#### 4.4.3. オーケストレーション層

初版は「オーケストレーションはアダプタごとに完全な別実装が必要」「Codex 側は逐次モードへ
degrade させる」としていたが、`multi_agent` と `codex exec` の存在により**この前提は不要になった。**

役割分離・モデル使い分け・権限制限は `.codex/agents/*.toml` で表現でき、
自律ループは以下のいずれかで実現できる。

| 方式 | 内容 | 位置づけ |
| --- | --- | --- |
| **セッション内サブエージェント** | Codex セッション内で `multi_agent` により planner/generator/evaluator を起動 | Claude Code 版 `run/SKILL.md` に最も近い。スキルとして提供できる |
| **シェルループ + `codex exec`** | ループがシェル側にあり、1起動＝1役 | 文脈分離が最も強い。無人実行向き |

前者を既定とし、後者は `--dangerously-bypass-approvals-and-sandbox` を伴う完全無人実行の
選択肢として `adapters/codex/run-loop.sh` に用意する。

#### 4.4.4. スキルの共有範囲

`SKILL.md` は共通形式だが、**全スキルがそのまま共有できるわけではない。**

| スキル | 共有可否 | 理由 |
| --- | --- | --- |
| `grill-me` / `spec` / `epic` | 共有できる見込み | 対話とissue操作のみ。CLI固有機構への依存が薄い |
| `plan` | 概ね共有できる | `@planner` 記法の置換が必要 |
| `run` / `goal` | **ベンダー別バリアントが必要** | `$ARGUMENTS`、`` !`command` `` の事前実行、`@agent` 記法、`permissions.additionalDirectories` の議論、`.claude/worktrees/` パスに依存 |

`run` / `goal` は Claude 版を `skills/run/`、Codex 版を `skills/run-codex/` として並置し、
共通の判断基準（タスク選定順序・機械的ゲートの合否・レビュー巡回回数と打ち切り条件・完了条件）は
`core/instructions.md` に置いて両者から参照する。

### 4.5. 強制点（フック）の移植

現状のハーネスは**フックによる決定論的強制**に依存している。

| フック | 実装 | 役割 |
| --- | --- | --- |
| `SessionStart` | `scripts/check-prerequisites.sh` | gh / Docker / gitリポジトリの前提チェック |
| `PostToolUse`（Write/Edit/MultiEdit） | `scripts/check-readability.sh` | 可読性ガード。編集をブロック |
| `Stop` | `scripts/check-readability.sh --git` | 差分全体への可読性ガード |
| `Stop` | `scripts/check-stop-review.sh` | 差分がある場合のレビュー促し |
| `Notification` / `Stop` | `scripts/notify-slack.sh` | Slack通知 |

**初版はここを「Codex には移植できない」としていたが誤りである。** 第3.5節のとおり、
イベント・スキーマ・探索パス・`CLAUDE_PLUGIN_ROOT` がすべて揃っており、`hooks/hooks.json` は
**無改造で共有できる。**

必要な改修は2点だけ。

1. **`scripts/check-readability.sh` の二重出力対応** — `exit 2` + stderr（Claude Code）と
   stdout の `{"continue": false, ...}`（Codex）の両方を満たす。入力の hook JSON に含まれる
   Codex 固有フィールド（`turn_id` / `permission_mode` / `model`）で分岐する
2. **`Notification` イベントの扱い** — Codex のイベント一覧に `Notification` は無い。

**決定: `hooks.json` を1ファイルに共有せず、Codex 用に `hooks/hooks.codex.json` を分ける。**

`.codex-plugin/plugin.json` の `hooks` エントリでパスを上書きできる（既定は `hooks/hooks.json`）ため、
マニフェスト側で切り替える。

```json
{ "name": "dev-workflow", "hooks": "./hooks/hooks.codex.json" }
```

理由は2つ。

- Codex が未知のイベントキー（`Notification`）を含む `hooks.json` を許容するかが未検証であり、
  共有して壊れると**フック全体が読まれなくなる**リスクがある
- `Notification` は Claude Code の「入力待ち」通知に紐づく概念で、
  Codex の `PermissionRequest` とは意味が異なる。機械的な読み替えは誤った通知を生む

`hooks.codex.json` は `Notification` を除いた構成とし、Slack通知は `Stop` のみに紐づける。
「入力待ち」通知は Codex 側では提供しない（既定でOFFの機能なので実害は小さい）。
実装は Phase C（`.codex-plugin/plugin.json` の作成）と同時に行う。

加えて、**強制点をgit側に二重化する**（`adapters/common/install-git-hooks.sh`）。
これはベンダー非依存の保険であり、フックが移植できるようになった今でも価値がある
（素の `git commit` や他のツールから編集された場合にも効く）。

### 4.6. userConfig の移植

`plugin.json` の `userConfig` は Claude Code plugin 固有で、`.codex-plugin/plugin.json` に相当物がない。

| 設定項目 | Claude Code | Codex |
| --- | --- | --- |
| `default_generator_model` | plugin userConfig | `.codex/agents/generator.toml` の `model`、または `[agents] default_subagent_model` |
| `docker_image` | plugin userConfig | 環境変数 `DEV_WORKFLOW_DOCKER_IMAGE` |
| `docker_compose_file` | plugin userConfig | 環境変数 `DEV_WORKFLOW_DOCKER_COMPOSE_FILE` |

中立層のスクリプトは**環境変数を先に見て、未設定なら既定値にフォールバックする**実装とし、
Claude Code 側のアダプタが userConfig の値を環境変数に流し込む。

### 4.7. プロジェクト指示ファイル（`CLAUDE.md` / `AGENTS.md`）

プロジェクト固有ルールの正本は**各プロジェクトの `CLAUDE.md`** とし、`AGENTS.md` はそこから生成する。

```
AGENTS.md（生成物）= CLAUDE.md を中立化したもの
```

ハーネス共通ルールはプラグイン側（`core/instructions.md`）が `agents/*.md` と
`.codex/agents/*.toml` に焼き込んでいるため、`AGENTS.md` に重複して入れる必要はない。

生成は単純なコピーでは済まない。CLAUDE.md には Codex にとって無意味か有害な記述が含まれるためである
（スラッシュコマンド、ツール名、`.claude/` パス、`settings.json`・permissions、`@agent` 記法、
そして「CLAUDE.mdに従う」という自己参照）。中立化の方式は第7章を参照。

### 4.8. Windows対応 ― symlinkを使わない

初版設計の `ln -sfn` によるスキル配置は**Windowsで動作しない**。

- シンボリックリンク作成には Developer Mode の有効化または管理者権限が必要
- Git Bash 環境では `ln` が実体コピーにフォールバックする場合があり、挙動が環境依存になる

配置は**すべてファイル生成（連結・コピー）で行う**。更新は再実行で反映する方式とし、
リンクによる自動追従は諦める。生成物には必ず「自動生成ファイル。編集しないこと」ヘッダーと
再生成コマンドを埋め込む。

### 4.9. 既存 `codex-dev-workflow` の統合

調査時点で、別リポジトリとして Codex 版が既に存在し、インストール済みだった。

```
codex-dev-workflow/                 # codex-dev-workflow@personal としてインストール済み
├── .codex-plugin/plugin.json       # name: codex-dev-workflow, v0.1.0
├── scripts/check-prerequisites.ps1
└── skills/{dev-workflow-plan,dev-workflow-run,dev-workflow-review,dev-workflow-goal}/SKILL.md
```

`.codex/agents/` と `hooks/` を持たないスキルのみの構成で、`repository` は旧URLを指している。

**方針: `dev-workflow` 1プラグインに統合し、`codex-dev-workflow` は廃止する。**

理由は第3.2節で判明した互換性の高さである。`hooks/hooks.json` が同一パス・同一スキーマで、
`CLAUDE_PLUGIN_ROOT` に互換性があり、`SKILL.md` が共通形式である以上、
ベンダー間の差分は `.codex-plugin/plugin.json` と `.codex/agents/*.toml` の生成のみに収まる。
2系統を保守する理由がない。

移行手順（実施済みの手順は実機で確認したコマンドに置き換えてある）：

1. [x] `codex-dev-workflow/skills/*` の内容を `skills-codex/` に取り込む。
   旧版はタスクごとにレビューする古い設計だったため、**現行の core（Epic一括レビュー）に合わせて改訂した**
2. [x] `dev-workflow` に `.codex-plugin/plugin.json` を追加する
3. [x] Codex 側のマーケットプレイスに登録する

   ```bash
   codex plugin marketplace add masatoImayama/claude-dev-workflow-marketplace --ref master
   codex plugin add dev-workflow@dev-workflow-marketplace
   ```

4. [x] 旧プラグインを削除する。**`<plugin>@<marketplace>` の形式が必須**
   （`codex plugin remove codex-dev-workflow` だけではエラーになる）

   ```bash
   codex plugin remove codex-dev-workflow@personal
   ```

5. [x] ローカルクローンを削除する（`origin/main` と同期済み・固有の変更なしを確認のうえ実施）
6. [ ] GitHub リポジトリを削除する（**未実施。** `gh` トークンに `delete_repo` スコープが必要。
   `gh auth refresh -h github.com -s delete_repo` を実行してから `gh repo delete` する）

旧版の `scripts/check-prerequisites.ps1` は取り込んでいない。
`scripts/check-prerequisites.sh` が同じ項目（gh のインストールと認証、Docker のインストールと
デーモン起動、gitリポジトリ内であること）をすべて確認しており、加えて `gh auth setup-git` による
git認証の委任まで行うため、**機能的に上位互換**である。フックはすべて bash 経由で起動するので
PowerShell 版を残す理由がない。

#### 旧版から意図的に落とした機能

旧 `codex-dev-workflow` には `dev-workflow-review` という**単体のレビュースキル**があったが、
`skills-codex/` には引き継いでいない。現行の core は「レビューはEpic単位でまとめて行う」方針で、
タスク単位のレビューを明示的に禁止しているためである（レビューが最もコストの高い工程であり、
タスクごとに起動するとレビュー費用が実装費用を上回る）。

Epic の途中で単発レビューをしたい需要があれば、`evaluator` エージェントを直接起動すれば足りる。
専用スキルとして復活させるかは運用してから判断する。

---

## 5. 各プロジェクト側のファイル構成

### 5.1. レイヤー構造

| レイヤー | 内容 | 管理元 |
| --- | --- | --- |
| ハーネス層 | planner/generator/evaluatorの役割定義、issueベースのワークフロー、コーディング規約の基礎、可読性原則、安全ルール | dev-workflow プラグイン（`core/` が正本） |
| プロジェクト層 | 使用言語・フレームワーク、ディレクトリ構成、プロジェクト特有のルール | プロジェクトの `CLAUDE.md`（手書き・正本） |

ハーネス層は**プラグインが配る**ので、プロジェクト側に置く必要はない。
初版が想定していた `PROJECT_RULES.md` は不要で、既存の `CLAUDE.md` をそのまま正本として使う。

### 5.2. プロジェクト側のディレクトリ構成

```
my-project/
├── CLAUDE.md                  # ★正本（手書き・git管理）
├── AGENTS.md                  # 生成物（CLAUDE.md から中立化。git管理推奨）
├── .claude/
│   └── settings.json          # permissions 等
├── .codex/
│   ├── agents/                # 生成物（プラグインの codex-agents/ からコピー）
│   │   ├── planner.toml
│   │   ├── generator.toml
│   │   └── evaluator.toml
│   ├── config.toml            # [agents] 等（任意）
│   └── rules/*.rules          # 実行ポリシー（任意）
├── .git/hooks/pre-commit      # 可読性ガードの二重化（ベンダー非依存）
├── Dockerfile.dev             # または docker-compose.dev.yml
└── src/
```

`AGENTS.md` と `.codex/agents/*.toml` は生成物だが、**git管理を推奨する。**
障害発生時に生成処理を実行できない可能性があるため、平常時にコミットしておく
（第6章のフェイルオーバー手順と整合させる）。

### 5.3. CLAUDE.md の記述方針

正本である `CLAUDE.md` は、可能な範囲でベンダー中立に書く。CLI固有の記述が必要な場合は
第7章のマーカーで囲み、`AGENTS.md` 生成時に除外できるようにする。

---

## 6. フェイルオーバー手順

### 6.1. 事前準備（平常時に実施）

障害発生時に生成処理を実行できない可能性があるため、**平常時に両CLI分を用意しておく。**

```bash
# 1. Codex 側にプラグインを導入
codex plugin add dev-workflow@<marketplace-name>

# 2. プロジェクトに Codex 用サブエージェント定義を設置
#    （Claude Code から /dev-workflow:install-codex-agents でも可）
bash <plugin-root>/adapters/codex/install-agents.sh .

# 3. CLAUDE.md から AGENTS.md を生成
/dev-workflow:sync-agents

# 4. 生成物をコミット
git add AGENTS.md .codex/agents/ && git commit -m "chore: Codex 用ハーネスを配置"
```

### 6.2. Claude Code → Codex CLI への切り替え

```bash
cd my-project
codex          # そのまま作業を継続
```

- ファイル状態・git履歴はそのまま引き継がれる
- Planner が作成済みの GitHub Issue はそのまま参照可能
- Generator や Evaluator の作業途中からでも継続できる
- サブエージェント（`.codex/agents/*.toml`）・フック（プラグイン同梱）も機能する

初回はプラグイン同梱フックの**信頼付与**を求められる。承認すると可読性ガードが有効になる。

### 6.3. 完全無人で回す場合

```bash
DEV_WORKFLOW_TEST_CMD='<プロジェクトの全テストコマンド>' \
  bash <plugin-root>/adapters/codex/run-loop.sh 123   # Epic issue 番号
```

`DEV_WORKFLOW_TEST_CMD` は**必須**（例: `DEV_WORKFLOW_TEST_CMD='bash tests/run-tests.sh'`）。
未設定だと起動直後に `exit 1` する。既定値を置かないのは、対象テストの選定を generator に
委ねると一部しか実行されず回帰を見逃すため（#37 の再発防止）で、統合ゲートは常にこのコマンドで
プロジェクトの全テストを実行する。`DEV_WORKFLOW_DRY_RUN=1` で確認する場合も、必須チェックは
DRY_RUN より前に走るため `DEV_WORKFLOW_TEST_CMD` の設定が要る。

---

## 7. 中立化のガイドライン

### 7.1. `core/` をベンダー中立に保つ

`core/instructions.md` および `core/roles/*.md` では以下を避ける。

| 避けるべき表現 | 代替表現 |
| --- | --- |
| 「`Bash` ツールを使って」 | 「ターミナルでコマンドを実行して」 |
| 「`Read` ツールでファイルを読み」 | 「ファイルの内容を確認して」 |
| 「`Write` ツールで書き込み」 | 「ファイルに書き込んで」 |
| 「`/dev-workflow:run` を実行」 | 「実行のスキルを呼び出して」 |
| 「`@generator` に依頼」 | 「実装の役割に引き継いで」 |
| 「`CLAUDE.md` に従う」 | 「プロジェクトの指示ファイルに従う」 |
| 「`.claude/worktrees/` に作る」 | （削除。配置は各アダプタが決める） |
| 「`${CLAUDE_PLUGIN_ROOT}/scripts/...`」 | （削除。スクリプト呼び出しはアダプタ層に置く） |
| 「Claude Codeの承認フローに従い」 | （削除。承認は各CLIのネイティブ機能に委ねる） |
| 「`$ARGUMENTS`」「`` !`command` ``」 | （削除。スラッシュコマンド構文はアダプタ層のみ） |
| 「`isolation: worktree` で起動される」 | （削除） |
| 「`permissions.additionalDirectories` を設定」 | （削除） |

許容される表現：

- GitHub CLI コマンド（`gh issue create` 等）— エージェントツールではないため中立
- git コマンド、docker コマンド — 同上
- ファイルパスの指定、issueテンプレートの書式指定

### 7.2. `CLAUDE.md` → `AGENTS.md` の中立化

プロジェクトの `CLAUDE.md` にはCLI固有記述が混ざるため、マーカーで区分する。

```markdown
## 実行方法
<!-- vendor:claude-only -->
`/dev-workflow:run #123` で自律実装を開始する。
<!-- /vendor:claude-only -->
<!-- vendor:codex-only -->
`dev-workflow-run` スキルに Epic issue 番号を渡して開始する。
<!-- /vendor:codex-only -->

## コーディング規約
（マーカー無し = 両方に出力される）
```

生成時の決定論的な置換ルール：

| 置換前 | 置換後 |
| --- | --- |
| `CLAUDE.md` | `AGENTS.md` |
| `.claude/rules/` | `.codex/rules/` |
| `.claude/settings.json` | `.codex/config.toml` |

マーカーが無い既存プロジェクト向けには、初回のみ挿入を提案するモードを用意する（第9章 Phase D）。

---

## 8. 将来の拡張

### 8.1. 新ベンダーの追加

新たなコーディングエージェントCLIに対応する場合、以下で対応できる。

1. `adapters/<vendor>/overlays/` と `build.sh` を作成
2. 当該CLIのマニフェスト・指示ファイル名・設定ディレクトリに合わせて生成ロジックを記述
3. スキルのベンダー別バリアントが必要なら追加

`core/` 以下のベンダー中立コンテンツは一切変更不要。

### 8.2. 不採用としたアプローチの記録

#### 8.2.1. 共通Skill抽象基盤＋スキーマ変換アダプター＋自前オーケストレーター

Python等で `BaseSkill` 抽象クラスを定義し、`to_anthropic_tool()` / `to_openai_tool()` で
スキーマ変換、自前の実行ループでAPI直接制御を行うアプローチ。

**不採用理由：**
- 各CLIが既にファイル操作・コマンド実行のツールを内蔵しており、外部に再実装する意味がない
- 自前オーケストレーターでは各CLIのリッチなUX（差分プレビュー、承認フロー、セッション管理）を全て失う
- 実装・運用コストに対してリターンが見合わない

#### 8.2.2. 単純CLIランチャー（タスク前モデル選択方式）

タスクの性質に応じてCLI起動コマンドを切り替えるだけのシェルスクリプト。

**不採用理由：**
- ルーティングにはなるが、ワークフロー定義・開発ルール・スキルの共通化という本来の価値が得られない
- フェイルオーバーではなく単なる選択であり、課題解決に至らない

#### 8.2.3. Codex 側を「逐次モード」に degrade させる案

Codex にはサブエージェント起動もフックも無いという前提のもと、1エージェントが3役を順に演じる
逐次モードを用意し、多エージェント自律ループの再現を諦める案。

**不採用理由：**
- **前提が事実誤認だった。** `multi_agent` は stable / 有効、フックもイベント・スキーマ・
  探索パスが揃っており、`codex exec` にはモデル・サンドボックス・作業ディレクトリの
  起動オプションがある
- degrade する必要がないため、そもそもこの案の存在理由がなくなった

この誤認は、インストール済みCLIを確認せず記憶に基づいて設計したことが原因である。
**新ベンダー追加時は、必ず当該CLIの実機（`--help` / 機能フラグ / 公式マニュアル）を確認してから
設計に入る。**

#### 8.2.4. `agents/*.md` を core/ 参照のラッパーにする案

詳細と不採用理由は 4.3.1 を参照。

---

## 9. 改修作業の手順

各フェーズは独立して価値を持ち、途中で止めても機能する。

### Phase A: core/ の抽出（完了）

Claude Code側の挙動を一切変えずに、ベンダー中立な内容を単一の正本に集約する。

- [x] `agents/*.md` から中立な内容とClaude Code固有の内容を分離・洗い出し
- [x] `core/instructions.md` の作成
- [x] `core/roles/{planner,generator,evaluator}.md` の作成
- [x] `adapters/claude/overlays/*.md` の作成
- [x] `adapters/claude/build.sh` の実装（include展開・`--check` モード）
- [x] `agents/*.md` を生成物に置き換え、`--check` が通ることを確認
- [x] 重要ルールが生成物に残っていることを検証
- [x] v0.7.2 として配信
- [ ] 実プロジェクトで `/dev-workflow:plan` / `/dev-workflow:run` が改修前と同等に動作することを確認

### Phase B: フックの両CLI対応（完了）

- [x] `scripts/check-readability.sh` を3契約対応にする
      （Claude Code: `exit 2` + stderr / Codex: `exit 0` + stdout JSON / git: `exit 1` + stderr）
- [x] 実行中のCLIの判定を実装（`DEV_WORKFLOW_HOOK_VENDOR` > `PLUGIN_ROOT` > 入力JSONの `turn_id`）
      ※ `permission_mode` は両CLIに存在するため判定に使えない。`turn_id` / `PLUGIN_ROOT` が Codex 固有
- [x] フック入力の読み取りを冒頭に集約し、tty のときは読まない（手動実行時のブロック回避）
- [x] `--staged` モードの追加（pre-commit 用にステージ済み変更のみを検査）
- [x] `Notification` イベントの Codex 側の扱いを決定（`hooks/hooks.codex.json` に分離。上記4.5参照）
- [x] `scripts/resolve-sandbox.sh` の実装（環境変数を正本にサンドボックス設定を解決）
- [x] `adapters/common/install-git-hooks.sh` の実装（pre-commit への二重化。追記方式・冪等・アンインストール対応）
- [x] 3契約すべての回帰確認（違反あり／なし／`READABILITY_GUARD=off`／JSON妥当性／
      `file_path` 抽出／pre-commit のブロック・通過・バイパス・冪等・アンインストール）
- [ ] 実プロジェクトで Claude Code のフックが従来どおり動作することを確認（セッション再起動が必要）

### Phase C: Codex アダプタ（実装完了・実機検証待ち）

- [x] `.codex-plugin/plugin.json` の作成（`skills: ./skills-codex/` / `hooks: ./hooks/hooks.codex.json`）
- [x] `hooks/hooks.codex.json` の作成（`Notification` を除外。`apply_patch` を PostToolUse の matcher に追加）
- [x] `adapters/lib/expand-includes.sh` に include 展開を共通化（Claude/Codex 両 build から source）
- [x] `adapters/codex/overlays/*.toml` の作成（evaluator は `sandbox_mode = "read-only"`）
- [x] `adapters/codex/build.sh` の実装（→ `codex-agents/*.toml`、`--check` 対応、
      TOML リテラル文字列の終端 `'''` 混入検出つき）
- [x] `adapters/codex/install-agents.sh` の実装（→ `<project>/.codex/agents/`、
      `--check` とモデル指定の環境変数に対応）
- [x] `skills-codex/install-codex-agents/SKILL.md` の作成
- [x] `skills-codex/dev-workflow-run/SKILL.md` の作成（サブエージェントによるループ）
- [x] `skills-codex/dev-workflow-plan/SKILL.md` / `dev-workflow-goal/SKILL.md` の作成
- [x] `adapters/codex/run-loop.sh` の実装（`codex exec` による無人ループ。
      反復上限・dry-run・前提の事前検証つき）
- [x] `adapters/codex/schemas/evaluator-verdict.json` の作成（`--output-schema` 用）
- [x] 生成物の TOML 妥当性検証（`tomllib` で必須3フィールドを確認）
- [x] `install-agents.sh` の結合テスト（未設置検出／設置／`--check`／モデル指定の反映）
- [x] `run-loop.sh` のエラー経路テスト（引数なし／前提未達で worktree を作らずに落ちる）
- [x] README に Codex での導入手順・無人実行・Claude Code との差分表を追記
- [x] marketplace リポジトリに `.agents/plugins/marketplace.json` を追加（`git-subdir` + `policy` + `category`）
- [x] 配信フローを2ファイルのSHA更新に対応（`.claude-plugin/` と `.agents/plugins/` の両方）
- [x] **実機で導入を検証**（`codex plugin marketplace add` → `codex plugin add`。
      `.agents/plugins/marketplace.json` が読まれ、`git-subdir` とSHAが正しく解決された）
- [x] `codex-dev-workflow@personal` を削除（スキル名が3件衝突していたため必須の作業だった）
- [ ] 実プロジェクトで planner → generator → evaluator の1サイクルが回ることを確認
- [ ] プラグイン同梱フックの信頼付与フローを実機で確認
- [ ] `codex-dev-workflow` リポジトリのアーカイブ（ユーザー判断待ち）

#### 実装時に判明した設計上の判断

- **`model` は既定で指定しない。** 利用可能なモデルの階層（どれが実装向き／レビュー向きか）を
  確証をもって決められないため、既定では親セッションまたは `[agents] default_subagent_model` から
  継承させ、`DEV_WORKFLOW_CODEX_{PLANNER,GENERATOR,EVALUATOR}_MODEL` で任意に指定できるようにした。
  オーバーレイにはコメントアウトした `# model = "..."` を置いてある
- **スキルは `skills/` を共有せず `skills-codex/` に分けた。** 同一ディレクトリを両マニフェストが
  指すと、Codex が Claude 固有構文（`$ARGUMENTS`、`@agent` 記法、`` !`command` ``）を含む
  `run` / `goal` を読んでしまう。共有できるのは中立な `core/` であり、スキルは薄い起動役に留める
- **`PostToolUse` の matcher に `apply_patch` を追加した。** Codex のファイル編集ツール名が
  Claude Code の `Write` / `Edit` と異なるため。実機で正確なツール名を確認して調整する余地がある

#### Phase C の配布作業（方式は 3.6 で確定済み）

- [ ] marketplace リポジトリに `.agents/plugins/marketplace.json` を追加
      （`source: git-subdir` + `policy.installation` / `policy.authentication` / `category`）
- [ ] `.claude-plugin/marketplace.json` がCLIでもレガシー互換パスとして読まれるかを実測
      （読まれるなら二重管理を廃止できる）
- [ ] 配信スクリプトを2ファイルのSHA更新に対応させる（3.6.4）
- [ ] `codex plugin marketplace add` → `codex plugin add dev-workflow@<name>` で導入確認
- [ ] `codex plugin marketplace upgrade` で更新が反映されることを確認
- [ ] README に Codex 側の導入手順を追記

### Phase D: プロジェクト指示ファイルの生成

- [ ] `scripts/sync-agents.sh` の実装（マーカー処理 + 決定論的置換）
- [ ] `skills/sync-agents/SKILL.md` の作成
- [ ] マーカー未導入の既存 CLAUDE.md 向けの `--init` モード（挿入提案）
- [ ] ドリフト検出（`SessionStart` で不一致を警告）
- [ ] 実プロジェクトで生成した `AGENTS.md` を Codex で読ませて動作確認

### Phase E: 仕上げ

- [ ] Windows（Git Bash / PowerShell）で全スクリプトが動作することを確認
- [ ] README.md にマルチベンダー対応の使用方法とフェイルオーバー手順を追記
- [ ] Codex 側で緩む点（`maxTurns` 相当なし、worktree分離なし、`sandbox_mode` の粒度が粗い）を明記
- [ ] marketplace リポジトリ側のコピーとSHAを更新して配信

### Phase F: サンドボックスの分離単位是正（Epic #3, 完了）

v0.10.0 実運用で、期待（epic単位で分離）と実装（worktree単位で分離＋リポジトリ単位でキャッシュ共有）が
ずれていたことが判明した（詳細は `epic/epic3/sandbox-epic-scope` のEpic本文を参照）。

- [x] `tests/run-tests.sh`（Docker非依存）・`Dockerfile.dev`・`--print-plan` の骨格を追加
- [x] バインドマウントをリポジトリルートに固定し、コンテナを epic 単位にする
      （`dw-sandbox-<repo>[-<epic>]`。worktree数に依存しない）
- [x] docker label（`dev-workflow.managed` 等）による後片付け（`--ls` / `--down` / `--down --all`）
- [x] `--reset-cache` に列挙表示・running検出のガードと `--force` を追加
      （キャッシュ volume はリポジトリ単位のまま。作用範囲が epic ではないための誤爆防止）
- [x] イメージのビルド責務を `sandbox-exec.sh` に集約（`dev-sandbox:<repo>-<hash8>`、
      イメージID差分によるコンテナ再作成、`--rebuild`）
- [x] compose モードの修正（`-p` / `--project-directory` をリポジトリルート基準に固定、
      自動 `up -d`、`container_name` / 固定ホストポートの検出警告）
- [x] `check-readability.sh` の非対話ハング修正（引数指定時はstdinを読まない、
      非tty時は `READABILITY_STDIN_TIMEOUT` で読み取りタイムアウト）
- [x] `check-prerequisites.sh` にCRLF警告（非ブロッキング）を追加
- [x] `.gitattributes` に `*.toml` / 自己参照の `eol=lf` を追加（`*.sh` は既存）。
      既存ワーキングツリーの再正規化（`git rm --cached -r . && git reset --hard`）が必要になった
      実障害を踏まえ、README にも明記
- [x] 両 run スキル（`skills/run/SKILL.md` / `skills-codex/dev-workflow-run/SKILL.md`）から
      `docker build` / `docker compose up` の直接記述を削除し `sandbox-exec.sh` に一本化
- [x] `core/instructions.md` のサンドボックス方針を `sandbox-exec.sh` 集約に合わせて修正
      （`agents/generator.md` / `codex-agents/generator.toml` を再生成）
- [x] README.md のサンドボックス節を全面更新（分離単位の表、`--print-plan`、ライフサイクル操作、
      `--reset-cache` の作用範囲、`--rebuild` の使いどころ、compose の既知の限界、CRLF注意）
- [x] `plugin.json`（両CLI）を v0.11.0 に更新

### Phase G: タスク並列化（Epic #14, 完了）

`--ff-only` が兼ねていた「ベース逸脱の検出」と「履歴の直線性の強制」を分離し、
Task issue の `- 前提: #N` が作る依存グラフに基づくウェーブ単位の並列実行に切り替えた。
あわせて generator 1タスクあたりの固定オーバーヘッド（同じ情報を毎タスク読み直す冗長性）を削った。

- [x] `scripts/plan-waves.sh` の新規実装（依存グラフとウェーブ分解・サブバッチ割当・
      宣言漏れ／循環依存／Epic外参照／スキップ伝播の検出・`--print` ドライラン・`--from-file`）
- [x] `scripts/merge-lane.sh` の新規実装（merge-base 完全一致検証・`git merge --no-edit`・
      競合時 `--abort`・成功／ベース逸脱／競合を終了コードで区別）
- [x] `core/roles/generator.md` の同期手順を是正
      （`fetch`/`checkout`/`pull` を廃止し、渡された `WAVE_BASE` への検証1回に一本化）
- [x] `core/instructions.md` に並列実行の共通仕様を規定
      （`- 前提:` の必須化、ウェーブの概念、merge-base 検証、`--ff-only` 廃止、スキップの伝播、
      Codex は `lanes=1` 固定であること）
- [x] `core/roles/planner.md` に依存宣言の必須化と Task issue の自己完結化を規定
- [x] `skills/run/SKILL.md` をウェーブ実行の本体に書き換え
      （`--lanes` とサブバッチ、WAVE_BASE の記録、レーンの並列起動、wave ブランチ経由の統合、
      統合ゲート、リカバリ、ウェーブ所要時間の計測表示）
- [x] `skills-codex/dev-workflow-run/SKILL.md` / `adapters/codex/run-loop.sh` を
      `lanes=1` 固定の縮退版として同じ統合手順に合わせる
- [x] プロジェクト固有準備の Epic 開始時集約（Epic issue 本文の `## 準備コマンド` 節を
      run が Epic 開始時の `--warm` に1回だけ渡す。generator はタスクごとに再実行しない）
- [x] `tests/run-tests.sh` に新規2スクリプトのケースを追加し決定論を固定
- [x] README.md / 本ドキュメントに並列実行の節・対応表を追加、両 `plugin.json` を `v0.12.0` に更新

**完了条件に含めなかったもの**: 実 Epic の並列完走（Tessera 等での実機検証は PR マージ後に
人間が行う）。

### 調査済みの事項（初版の未確認リスト）

| 項目 | 結論 | 対応 |
| --- | --- | --- |
| `maxTurns` 相当の設定があるか | **無い。** 近いのは `features.rollout_budget` だが under development・既定オフ・トークン予算 | オーケストレーター側で反復回数を制御し、打ち切り条件はプロンプト規約で担保（3.3.4） |
| サブエージェントを worktree に隔離できるか | **不可。** セッション単位の worktree は第一級機能だが、エージェント設定に作業ディレクトリのキーがない | generator の並行実行を諦め、Epicごと1 worktreeで逐次、またはシェルループが `codex exec -C` で割り当て（3.3.3） |
| Codex marketplace の `source` に git 系があるか | **ある。** `git-subdir` / `url` / `npm` / `local`。`git-subdir` は現行の Claude Code 形式と同形 | 既存の marketplace リポジトリを両CLI共用にする（3.6） |

### 残る未確認事項

| 項目 | 影響 |
| --- | --- |
| `.claude-plugin/marketplace.json` をCLIもレガシー互換パスとして読むか | 読むなら Codex 用マーケットプレイスファイルの二重管理が不要になる（マニュアルの記述はデスクトップアプリの文脈） |
| `.claude-plugin/plugin.json` のローカル配布時の正規化変換の有無 | `claude_format_normalized` は公開ポータル提出経路の記述。ローカルでも働くなら `.codex-plugin/plugin.json` が不要になる（安全側に倒して明示的に用意する方針） |

### フェーズをまたぐ不変条件

- **`core/` を編集したら各アダプタの `build.sh` を実行し、生成物をコミットに含める**
- **`agents/*.md` と `codex-agents/*.toml` を直接編集しない**（生成物）
- 両CLIのプラグイン構造（`.claude-plugin/`, `.codex-plugin/`, `skills/`, `hooks/`）を壊さない
- 生成物には必ず「自動生成ファイル。編集しないこと」ヘッダーと再生成コマンドを埋め込む
- **新ベンダー対応時は実機確認を先に行う**（8.2.3の教訓）
