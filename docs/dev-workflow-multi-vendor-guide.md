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

### 3.1. 指示ファイル・設定ディレクトリの対照表

| 項目                   | Claude Code                          | Codex CLI                                      |
| ---------------------- | ------------------------------------ | ----------------------------------------------- |
| プロジェクト指示ファイル | `CLAUDE.md`（プロジェクトルート）     | `AGENTS.md`（プロジェクトルート）                |
| 個人用指示ファイル      | `~/.claude/CLAUDE.md`                | `~/.codex/AGENTS.md`                            |
| 設定ディレクトリ        | `.claude/`                           | `.codex/`                                       |
| スキル                 | `.claude/skills/xxx/SKILL.md`        | Agent Skills標準に準拠（同一フォーマット）        |
| カスタムコマンド        | `.claude/commands/xxx.md`            | `~/.codex/prompts/xxx.md`（非推奨→skills推奨）   |
| ルール                 | `.claude/rules/*.md`                 | `~/.codex/rules/*.md`                           |
| セッション             | `~/.claude/projects/`                | `~/.codex/sessions/`                            |
| 設定ファイル            | `.claude/settings.json`              | `~/.codex/config.toml`                          |

### 3.2. 重要な共通点：Agent Skills オープンスタンダード

両CLIとも Agent Skills オープンスタンダードに準拠している。`SKILL.md` の構造（YAMLフロントマター＋Markdown本体＋オプショナルなscripts/references/assetsディレクトリ）は共通であり、**スキルの中身自体は変換不要**である。差異は配置先のパスのみ。

---

## 4. dev-workflowの改修設計

### 4.0. 前提：dev-workflowはClaude Code pluginである

改修設計の出発点として、現状の配布形態を正しく押さえる必要がある。

dev-workflowは単なるgitプロジェクトではなく、**Claude Code plugin**として実装・配布されている。

- `.claude-plugin/plugin.json` — プラグインマニフェスト（`name`, `version`, `userConfig` 等）
- `.claude-plugin/marketplace.json` — マーケットプレイス定義
- `agents/*.md` — Claude Codeのサブエージェント定義
- `skills/*/SKILL.md` — Claude Codeのスキル（スラッシュコマンド）
- `hooks/hooks.json` — Claude Codeのフック定義
- 配布は別リポジトリ `claude-dev-workflow-marketplace` 経由（プラグイン本体のコピー＋SHA更新）

インストール先は `~/.claude/plugins/...` 配下であり、**ユーザーがリポジトリのパスを直接指定して
スクリプトを実行することは想定できない。** したがって「各プロジェクトから `setup.sh` を叩く」方式を
Claude Code側にも適用すると、plugin配布とスクリプト配布の2系統を保守することになり破綻する。

**設計原則: plugin構造は壊さない。Claude Code側は現行のplugin機構をそのまま使い、
`setup.sh` はplugin機構を持たないCLI（Codex CLI等）専用とする。**

### 4.1. 目標ディレクトリ構成

```
dev-workflow/
├── .claude-plugin/                 # Claude Code plugin マニフェスト（現状維持）
│   ├── plugin.json
│   └── marketplace.json
├── core/                           # ★ベンダー中立の正本
│   ├── instructions.md             #   ハーネス共通ルール（ワークフロー・規約・安全ルール）
│   └── roles/                      #   3役割の中立な役割定義
│       ├── planner.md
│       ├── generator.md
│       └── evaluator.md
├── adapters/
│   ├── claude/                     # ★Claude Code向け
│   │   ├── overlays/               #   frontmatter + Claude固有の補足 + include指示
│   │   │   ├── planner.md
│   │   │   ├── generator.md
│   │   │   └── evaluator.md
│   │   └── build.sh                #   overlays + core → agents/*.md を生成
│   └── codex/                      # （Phase C）Codex CLI向け
│       └── install.sh              #   AGENTS.md を生成し、逐次モード文書を配置
├── agents/                         # ★生成物（コミットする。直接編集禁止）
│   ├── planner.md
│   ├── generator.md
│   └── evaluator.md
├── skills/                         # Claude Codeスキル（スラッシュコマンド）
│   ├── plan/SKILL.md
│   ├── run/SKILL.md
│   └── ...
├── hooks/hooks.json                # Claude Codeフック定義
├── scripts/*.sh                    # フック実装・通知（大部分はベンダー中立）
└── README.md
```

### 4.2. core/ ― ベンダー中立の正本

#### 4.2.1. instructions.md

ベンダー中立な指示・ルールを集約する。

含む内容：

- ワークフロー全体の概要（planner → generator → evaluator）
- **状態はGitHub issueとgitに置く**という原則
- GitHub issueベースの作業管理ルール（ラベル、タスク粒度、タスク選定順序）
- ブランチ戦略
- コミットメッセージ規約
- 可読性原則
- レビュー基準（重要度3段階・判定・Epic単位でまとめる理由）
- サンドボックス方針
- 安全ルール
- プロジェクト固有ルールの参照方法

**含めない内容**（ベンダー固有）：

- 各CLIのツール名（`Bash` / `Read` / `Write` 等）への直接参照
- スラッシュコマンドの使用指示
- サブエージェント記法（`@generator` 等）
- フック・パーミッション・worktree isolation など各CLIの機構への依存

#### 4.2.2. roles/

3役割の**役割定義と手順**を中立に記述する。ここは「何をやるか」だけを書き、
「どのツールでやるか」「どう起動されるか」は書かない。

なお、Agent Skills標準の `SKILL.md` 形式では**書かない**。理由は 4.4 を参照。

### 4.3. adapters/claude/ ― ビルドによる生成

#### 4.3.1. なぜ「参照」ではなく「生成」なのか

当初、`agents/*.md` を「core/ を読みに行く薄いラッパー」にする案を検討したが**不採用**とした。

- `agents/*.md` はClaude Codeがサブエージェントのシステムプロンプトとして読み込むため、
  内容を実行時に外部ファイルから取得させると、読み込み失敗が役割定義の欠落に直結する
- 参照先パスの解決に使える `${CLAUDE_PLUGIN_ROOT}` は**フック実行時にのみ注入される**環境変数であり、
  サブエージェントの `Bash` 実行時には未設定である（実測で確認済み）
- 毎回の起動でファイル読み込みのターンを1つ消費する

したがって、**core/ を正本とし、ビルド時に内容を展開して `agents/*.md` を生成する。**
生成物はリポジトリにコミットするため、**実行時の挙動は改修前と変わらない**（追加の読み込みも発生しない）。

#### 4.3.2. overlays/ の構造

オーバーレイは「frontmatter」「include指示」「ベンダー固有の補足」の3要素で構成する。

```markdown
---
name: generator
model: sonnet
tools: Read, Grep, Glob, Bash, Write, Edit
disallowedTools: AskUserQuestion
maxTurns: 50
effort: high
color: blue
isolation: worktree
---

<!-- 自動生成ファイル。編集しないこと。 -->
<!-- 再生成: bash adapters/claude/build.sh -->

<!-- include: core/roles/generator.md -->

<!-- include: core/instructions.md -->

## Claude Code 固有の補足

### ツールの使い分け
（`Read` / `Write` / `Edit` / `Bash` の役割分担、`AskUserQuestion` 禁止）

### worktree クリーンアップ時の注意
（`isolation: worktree` 前提。node_modules symlink の解除）

### 可読性原則はフックで強制される
（`PostToolUse` / `Stop` フックによる決定論的ブロック）
```

frontmatter（`model`, `tools`, `maxTurns`, `effort`, `isolation` 等）は**すべてClaude Code固有**であり、
core/ には置かない。ここがベンダー間で最も差が大きい部分である。

#### 4.3.3. build.sh の処理内容

`<!-- include: <リポジトリルートからの相対パス> -->` 行を、そのファイルの内容で置き換えるだけの
単純なテキスト展開器とする（includeの入れ子はしない）。

```bash
bash adapters/claude/build.sh          # agents/*.md を生成する
bash adapters/claude/build.sh --check  # 生成物が core/ と一致するか検証（差分があれば exit 1）
```

`--check` は生成物のドリフト（`agents/*.md` を直接編集してしまう事故）を検出するためのもので、
core/ を編集する開発時に実行する。**プラグイン利用者のセッションでは実行しない**
（利用者は core/ を編集しないため、フックには組み込まない）。

### 4.4. オーケストレーション層 ― アダプタごとに別実装が必要

**「SKILL.md は両CLIでそのまま使える」は役割定義には成立するが、オーケストレーションには成立しない。**

現状の `skills/run/SKILL.md` と `skills/goal/SKILL.md` は、単なる手順書ではなく
**多エージェント制御そのもの**である。

| 依存している機構 | 該当箇所 | Codex CLIでの等価物 |
|---|---|---|
| サブエージェント起動（`@generator` / `@evaluator`） | run/SKILL.md の各ステップ | なし |
| `isolation: worktree`（エージェント専用worktree） | agents/generator.md の frontmatter | なし |
| `model` / `maxTurns` / `effort` のエージェント別指定 | agents/*.md の frontmatter | なし |
| `$ARGUMENTS` / `argument-hint` / `disallowed-tools` | 各SKILL.md の frontmatter・本文 | なし |
| `` !`command` `` によるスキル読み込み時の事前実行 | run/SKILL.md 冒頭 | なし |
| `permissions.additionalDirectories` によるパス許可 | run/SKILL.md のパーミッション節 | 別のモデル |
| `${CLAUDE_PLUGIN_ROOT}` によるスクリプト参照 | run/SKILL.md・goal/SKILL.md | なし |

**`run/SKILL.md` の約3分の1はClaude Code固有の記述であり、第7章の置換表（ツール名の言い換え）では
処理できない。**

したがってオーケストレーションは以下の2層に分ける。

- **中立層**（`core/instructions.md` に含む）— タスク選定順序、Epicブランチ同期、機械的ゲートの合否基準、
  Epic単位レビューの巡回回数と打ち切り条件、完了条件
- **アダプタ層** — 上記を「どう実行するか」
  - Claude Code: 現行の `skills/run/SKILL.md`（多エージェント並行・自律ループ）
  - Codex CLI: `core/orchestration-sequential.md`（**単一セッション逐次モード**。1つのエージェントが
    3役を順に演じ、issueとgitで状態を引き継ぐ）

Codex側は**意図的にdegradeさせる**設計とする。多エージェント自律ループを再現しようとすると
自前オーケストレーターが必要になり、第1章で不採用とした方針に逆戻りする。

### 4.5. 強制点（フック）の移植 ― 何が緩むかを明示する

ドキュメント初版で欠落していた最重要項目。現状のハーネスは**フックによる決定論的強制**に依存している。

| フック | 実装 | 役割 |
|---|---|---|
| `SessionStart` | `scripts/check-prerequisites.sh` | gh / Docker / gitリポジトリの前提チェック |
| `PostToolUse`（Write/Edit/MultiEdit） | `scripts/check-readability.sh` | **可読性ガード。`exit 2` で編集をブロック** |
| `Stop` | `scripts/check-readability.sh --git` | 差分全体への可読性ガード |
| `Stop` | `scripts/check-stop-review.sh` | 差分がある場合のレビュー促し |
| `Notification` / `Stop` | `scripts/notify-slack.sh` | Slack通知 |

**Codex CLIには編集をブロックできるフック相当の機構がない**（`config.toml` の `notify` は通知のみ）。
さらに `check-readability.sh` は stdin のフックJSONから `file_path` を抽出し `exit 2` で
ブロックする実装であり、これはClaude Codeのフックプロトコル契約そのものである。

`agents/generator.md` が「可読性ガードによって決定論的に強制される」と明記している中核ルールが、
Codex側では**強制されなくなる**。

対策（Phase B）：**強制点をgit側に二重化する。**

- `check-readability.sh --git` を **pre-commit hook** として呼べるようにする
- git hookはCLIに依存しないため、どのベンダーで作業してもコミット時にブロックがかかる
- Claude Code側の `PostToolUse` フックは即時フィードバックとして残す（二重化であり置き換えではない）

`--git` モードは既に実装済みなので、必要なのは pre-commit hook のインストール手段のみ。

### 4.6. userConfig の移植

`plugin.json` の `userConfig` はClaude Code plugin固有の機構であり、他CLIに等価物がない。

| 設定項目 | Claude Code | 他CLI |
|---|---|---|
| `default_generator_model` | plugin userConfig | 各CLIの設定ファイル（Codex: `config.toml`）で指定 |
| `docker_image` | plugin userConfig | 環境変数 `DEV_WORKFLOW_DOCKER_IMAGE` |
| `docker_compose_file` | plugin userConfig | 環境変数 `DEV_WORKFLOW_DOCKER_COMPOSE_FILE` |

中立層のスクリプトは**環境変数を先に見て、未設定なら既定値にフォールバックする**実装とし、
Claude Code側のアダプタが userConfig の値を環境変数に流し込む形にする。

### 4.7. adapters/codex/ ― Codex CLI向け（Phase C）

#### 4.7.1. 実装前に確認すべき前提

第3章の対照表には、**実機確認が済んでいない行がある**。設計を確定する前に検証すること。

| 項目 | 確度 |
|---|---|
| `AGENTS.md`（プロジェクトルート） | 確実 |
| `~/.codex/AGENTS.md`（個人用） | 確実 |
| `~/.codex/config.toml`（設定） | 確実 |
| **プロジェクトローカルの `.codex/skills/` を読むか** | **未確認。要検証** |
| **`~/.codex/rules/*.md` を読むか** | **未確認。要検証** |
| **Agent Skills標準への準拠範囲** | **未確認。要検証** |

`.codex/skills/` が読まれないことが判明した場合、スキル配置ロジックは無効になり、
**すべての指示を `AGENTS.md` に集約する**設計に切り替える必要がある。

#### 4.7.2. install.sh の処理内容

```bash
#!/bin/bash
set -euo pipefail

PROJECT_ROOT="${1:-.}"
DEV_WORKFLOW_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENTS_MD="${PROJECT_ROOT}/AGENTS.md"

# 1. AGENTS.md の生成（共通層 + 逐次オーケストレーション + プロジェクト固有層）
{
  echo "<!-- 自動生成ファイル。編集しないこと。 -->"
  echo "<!-- 再生成: dev-workflow/setup.sh codex . -->"
  echo ""
  cat "${DEV_WORKFLOW_DIR}/core/instructions.md"
  echo ""
  cat "${DEV_WORKFLOW_DIR}/core/orchestration-sequential.md"
  echo ""
  for role in planner generator evaluator; do
    cat "${DEV_WORKFLOW_DIR}/core/roles/${role}.md"
    echo ""
  done

  if [ -f "${PROJECT_ROOT}/PROJECT_RULES.md" ]; then
    echo "---"
    echo ""
    echo "# プロジェクト固有ルール"
    echo ""
    cat "${PROJECT_ROOT}/PROJECT_RULES.md"
  fi
} > "$AGENTS_MD"

# 2. pre-commit hook として可読性ガードを設置（強制点のベンダー非依存化）
bash "${DEV_WORKFLOW_DIR}/adapters/common/install-git-hooks.sh" "$PROJECT_ROOT"

echo "[codex] インストール完了: ${PROJECT_ROOT}"
```

**シンボリックリンクは使わない。** 理由は 4.8 を参照。

### 4.8. Windows対応 ― symlinkを使わない

初版設計の `ln -sfn` によるスキル配置は**Windowsで動作しない**。

- Windowsでのシンボリックリンク作成には Developer Mode の有効化または管理者権限が必要
- Git Bash環境では `ln` が実体コピーにフォールバックする場合があり、挙動が環境依存になる
- 開発環境がWindowsの場合、これは実質的なブロッカーである

したがって配置は**すべてファイル生成（連結・コピー）で行う**。
更新は `setup.sh` の再実行で反映する方式とし、リンクによる自動追従は諦める。

生成物には必ず「自動生成ファイル。編集しないこと」ヘッダーと再生成コマンドを埋め込み、
直接編集による差分消失を防ぐ。

---

## 5. 各プロジェクト側のファイル構成

### 5.1. レイヤー構造

各プロジェクトのCLI向け指示ファイル（`CLAUDE.md` / `AGENTS.md`）は以下の2層構造で構成される。

| レイヤー | 内容 | 管理元 |
|---------|------|--------|
| 共通層  | planner/generator/evaluatorの役割定義、issueベースのワークフロー手順、コーディング規約の基礎 | dev-workflow（install.shが生成時に差し込む） |
| 固有層  | 使用言語・フレームワーク、ディレクトリ構成、プロジェクト特有のルール・注意事項 | プロジェクト側で手書き（`PROJECT_RULES.md`） |

### 5.2. プロジェクト側のディレクトリ構成例

```
my-project/
├── CLAUDE.md                  # ← install.shが生成（共通層 + 固有層をマージ）
├── AGENTS.md                  # ← install.shが生成（同上、Codex用）
├── PROJECT_RULES.md           # プロジェクト固有のルール（手書き、git管理）
├── .claude/
│   ├── settings.json
│   └── skills/                # ← dev-workflowからシンボリックリンク
│       ├── planner/
│       ├── generator/
│       └── evaluator/
├── .codex/
│   └── skills/                # ← dev-workflowからシンボリックリンク
│       ├── planner/
│       ├── generator/
│       └── evaluator/
├── .gitignore                 # CLAUDE.md, AGENTS.md は生成物として除外推奨
└── src/
```

### 5.3. PROJECT_RULES.md の記述方針

プロジェクト固有のルールはベンダー中立に記述する。特定CLIのツール名やコマンドへの直接参照は避ける。

```markdown
## 技術スタック
- 言語: TypeScript
- フレームワーク: Next.js (App Router)
- DB: Supabase
- テスト: Vitest

## ディレクトリ構成
- src/app/ - ページ・ルーティング
- src/components/ - UIコンポーネント
- src/lib/ - ユーティリティ・DB接続

## プロジェクト固有ルール
- APIルートでは必ずエラーハンドリングを入れること
- コンポーネントはServer Componentをデフォルトとし、Client Componentは最小限に
```

---

## 6. フェイルオーバー手順

### 6.1. Claude Code → Codex CLI への切り替え

```bash
# Claude Codeが障害で利用不能になった場合

cd my-project

# Codex用の指示ファイル・スキルを配置（未実施の場合）
./path/to/dev-workflow/setup.sh codex .

# Codex CLIを起動 ― そのまま作業を継続
codex
```

- ファイル状態・git履歴はそのまま引き継がれる
- Plannerが作成済みのGitHub Issueはそのまま参照可能
- GeneratorやEvaluatorの作業途中からでも継続できる

### 6.2. 事前準備（推奨）

障害発生時に即座に切り替えられるよう、平常時に `setup.sh both` を実行して両方のCLI向け指示ファイルを生成しておくことを推奨する。

```bash
./path/to/dev-workflow/setup.sh both .
```

---

## 7. instructions.md の記述ガイドライン

core/instructions.md をベンダー中立に保つための注意事項。

### 7.1. 避けるべき表現

| 避けるべき表現 | 代替表現 |
|---------------|---------|
| 「`Bash` ツールを使って」 | 「ターミナルでコマンドを実行して」 |
| 「`Read` ツールでファイルを読み」 | 「ファイルの内容を確認して」 |
| 「`Write` ツールで書き込み」 | 「ファイルに書き込んで」 |
| 「`/review` コマンドを実行」 | 「レビューのスキルを呼び出して」 |
| 「Claude Codeの承認フローに従い」 | （削除。承認フローは各CLIのネイティブ機能に委ねる） |

### 7.2. 許容される表現

- GitHub CLIコマンド（`gh issue create` 等）への言及：これはCLIツールでありエージェントツールではないため、ベンダー中立
- gitコマンドへの言及：同上
- ファイルパスの指定：ベンダー中立
- issueテンプレートの書式指定：ベンダー中立

---

## 8. 将来の拡張

### 8.1. 新ベンダーの追加

新たなコーディングエージェントCLI（例：Gemini CLI）に対応する場合、以下のみで対応可能。

1. `adapters/gemini/install.sh` を新規作成
2. 当該CLIの指示ファイル名（例：`GEMINI.md`）と設定ディレクトリ（例：`.gemini/`）に合わせて配置ロジックを記述
3. `setup.sh` に `gemini` ケースを追加

core/ 以下のベンダー中立コンテンツは一切変更不要。

### 8.2. 不採用としたアプローチの記録

以下のアプローチは検討の上、不採用とした。その理由を記録として残す。

#### 8.2.1. 共通Skill抽象基盤＋スキーマ変換アダプター＋自前オーケストレーター

Python等で `BaseSkill` 抽象クラスを定義し、`to_anthropic_tool()` / `to_openai_tool()` でスキーマ変換、自前の実行ループでAPI直接制御を行うアプローチ。

**不採用理由：**
- 各CLIが既にファイル操作・コマンド実行のツールを内蔵しており、外部に再実装する意味がない
- 自前オーケストレーターでは各CLIのリッチなUX（差分プレビュー、承認フロー、セッション管理、差分表示）を全て失う
- 実装・運用コストに対してリターンが見合わない

#### 8.2.2. 単純CLIランチャー（タスク前モデル選択方式）

タスクの性質に応じてCLI起動コマンドを切り替えるだけのシェルスクリプト。

**不採用理由：**
- ルーティングにはなるが、ワークフロー定義・開発ルール・スキルの共通化という本来の価値が得られない
- フェイルオーバーではなく単なる選択であり、課題解決に至らない

---

## 9. 改修作業の手順

初版の一括チェックリストは、依存関係の整理がないまま並べられていたため実行順に破綻があった。
以下の4フェーズに分割する。**各フェーズは独立して価値を持ち、途中で止めても機能する。**

### Phase A: core/ の抽出（ベンダー移植なしでも価値がある）

Claude Code側の挙動を一切変えずに、ベンダー中立な内容を単一の正本に集約する。

- [x] `agents/*.md` から中立な内容とClaude Code固有の内容を分離・洗い出し
- [x] `core/instructions.md` の作成（ワークフロー・issue管理・ブランチ戦略・コミット規約・
      可読性原則・レビュー基準・サンドボックス方針・安全ルール）
- [x] `core/roles/{planner,generator,evaluator}.md` の作成（中立な役割定義）
- [x] `adapters/claude/overlays/{planner,generator,evaluator}.md` の作成
      （frontmatter + include指示 + Claude固有の補足）
- [x] `adapters/claude/build.sh` の実装（include展開・`--check` モード）
- [x] `agents/*.md` を生成物に置き換え、`bash adapters/claude/build.sh --check` が通ることを確認
- [x] 重要ルール（削除コマンド禁止・可読性原則・main保護・テスト安全性・レビュー重要度基準）が
      生成物に残っていることを検証
- [x] 本ドキュメント第4章・第9章を実装後の構造に合わせて改訂
- [ ] 実プロジェクトで `/dev-workflow:plan` および `/dev-workflow:run` を実行し、
      改修前と同等に動作することを確認

### Phase B: 強制点のベンダー非依存化

可読性ガードの強制点をgit側に二重化する。ここまで済ませればCodex側でも中核ルールが守られる。

- [ ] `adapters/common/install-git-hooks.sh` の実装（pre-commit hook として
      `scripts/check-readability.sh --git` を呼ぶ）
- [ ] pre-commit hook がClaude Code / 素のgit の双方でブロックすることを確認
- [ ] Claude Code側の `PostToolUse` フックは即時フィードバックとして残す（置き換えない）
- [ ] `scripts/*.sh` を環境変数フォールバック対応にする（4.6のuserConfig移植）

### Phase C: Codex CLI アダプタ

**着手前に 4.7.1 の未確認項目を実機検証すること。** 検証結果によって設計が変わる。

- [ ] Codex CLIのバージョン確認と、`.codex/skills/` / `~/.codex/rules/` の読み込み挙動を実測
- [ ] `core/orchestration-sequential.md` の作成（単一セッション逐次モード。
      1エージェントが3役を順に演じ、issueとgitで状態を引き継ぐ）
- [ ] `adapters/codex/install.sh` の実装（AGENTS.md生成 + git hook設置）
- [ ] `setup.sh` の実装（`codex` / `both` のディスパッチ。Claude Code側はplugin機構を使うため
      `setup.sh claude` は「plugin導入手順の案内のみ」とする）
- [ ] `PROJECT_RULES.md` のテンプレートを作成
- [ ] 実プロジェクトで `setup.sh codex` を実行し、Codex CLIで planner → generator → evaluator の
      1サイクルが回ることを確認
- [ ] 何が緩むか（多エージェント並行・worktree分離・即時ブロック）をREADMEに明記

### Phase D: Windows対応と配布

- [ ] symlinkを使っていないことを確認（4.8）
- [ ] Windows（Git Bash / PowerShell）で `setup.sh` が動作することを確認
- [ ] README.md にマルチベンダー対応の使用方法とフェイルオーバー手順を追記
- [ ] `claude-dev-workflow-marketplace` 側のコピーとSHAを更新して配信

### フェーズをまたぐ不変条件

以下は全フェーズを通じて崩してはならない。

- **`core/` を編集したら `bash adapters/claude/build.sh` を実行し、生成物をコミットに含める**
- **`agents/*.md` を直接編集しない**（生成物）
- Claude Code plugin構造（`.claude-plugin/`, `agents/`, `skills/`, `hooks/`）を壊さない
- 生成物には必ず「自動生成ファイル。編集しないこと」ヘッダーと再生成コマンドを埋め込む
