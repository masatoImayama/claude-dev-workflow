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

### 4.1. 目標ディレクトリ構成

```
dev-workflow/
├── core/
│   ├── instructions.md            # ベンダー中立のハーネス本体（指示・ルール）
│   ├── planner.md                 # Plannerの役割定義・手順
│   ├── generator.md               # Generatorの役割定義・手順
│   ├── evaluator.md               # Evaluatorの役割定義・手順
│   └── skills/                    # Agent Skills標準準拠のスキル群
│       ├── planner/
│       │   └── SKILL.md
│       ├── generator/
│       │   └── SKILL.md
│       └── evaluator/
│           └── SKILL.md
├── adapters/
│   ├── claude/
│   │   └── install.sh             # Claude Code向けインストーラー
│   └── codex/
│       └── install.sh             # Codex CLI向けインストーラー
├── setup.sh                       # アダプター選択の統合エントリーポイント
└── README.md
```

### 4.2. core/ ― ベンダー中立の本体

#### 4.2.1. instructions.md

現在 `CLAUDE.md` に直接記述している開発ルールの基礎部分のうち、ベンダー中立な内容をすべてここに集約する。

含むべき内容：
- ワークフロー全体の概要（planner → generator → evaluator）
- GitHub Issueベースの作業管理ルール
- コーディング規約の基礎部分
- コミットメッセージ規約
- ブランチ戦略
- レビュー基準

**含めない内容**（ベンダー固有）：
- Claude Code固有のスラッシュコマンドの使用指示
- Codex CLI固有の操作指示
- 各CLIのツール名への直接参照

#### 4.2.2. skills/

Agent Skills標準に従って記述する。`SKILL.md` のYAMLフロントマター（name, description, trigger条件）と本体のMarkdown指示は、そのまま両CLIで利用可能。

スキル内でCLI固有のツール名（例：Claude Codeの `Bash` ツール vs Codexの `shell` ツール）を参照する必要がある場合は、汎用的な表現（「ターミナルでコマンドを実行する」「ファイルに書き込む」）で記述し、具体的なツール呼び出しは各CLIの判断に委ねる。

### 4.3. adapters/ ― ベンダー固有の変換・配置

#### 4.3.1. claude/install.sh の処理内容

```bash
#!/bin/bash
set -euo pipefail

PROJECT_ROOT="${1:-.}"
DEV_WORKFLOW_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# 1. CLAUDE.md の生成
#    - core/instructions.md の内容をベースに
#    - プロジェクト側に PROJECT_RULES.md があればマージ
#    - Claude Code固有のヘッダーや補足があれば付加
CLAUDE_MD="${PROJECT_ROOT}/CLAUDE.md"

echo "# ハーネス共通ルール（dev-workflow）" > "$CLAUDE_MD"
echo "" >> "$CLAUDE_MD"
cat "${DEV_WORKFLOW_DIR}/core/instructions.md" >> "$CLAUDE_MD"

if [ -f "${PROJECT_ROOT}/PROJECT_RULES.md" ]; then
    echo "" >> "$CLAUDE_MD"
    echo "---" >> "$CLAUDE_MD"
    echo "" >> "$CLAUDE_MD"
    echo "# プロジェクト固有ルール" >> "$CLAUDE_MD"
    echo "" >> "$CLAUDE_MD"
    cat "${PROJECT_ROOT}/PROJECT_RULES.md" >> "$CLAUDE_MD"
fi

# 2. Skills の配置（シンボリックリンク）
mkdir -p "${PROJECT_ROOT}/.claude/skills"
for skill_dir in "${DEV_WORKFLOW_DIR}/core/skills"/*/; do
    skill_name=$(basename "$skill_dir")
    ln -sfn "$skill_dir" "${PROJECT_ROOT}/.claude/skills/${skill_name}"
done

echo "[claude] インストール完了: ${PROJECT_ROOT}"
```

#### 4.3.2. codex/install.sh の処理内容

```bash
#!/bin/bash
set -euo pipefail

PROJECT_ROOT="${1:-.}"
DEV_WORKFLOW_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# 1. AGENTS.md の生成
AGENTS_MD="${PROJECT_ROOT}/AGENTS.md"

echo "# ハーネス共通ルール（dev-workflow）" > "$AGENTS_MD"
echo "" >> "$AGENTS_MD"
cat "${DEV_WORKFLOW_DIR}/core/instructions.md" >> "$AGENTS_MD"

if [ -f "${PROJECT_ROOT}/PROJECT_RULES.md" ]; then
    echo "" >> "$AGENTS_MD"
    echo "---" >> "$AGENTS_MD"
    echo "" >> "$AGENTS_MD"
    echo "# プロジェクト固有ルール" >> "$AGENTS_MD"
    echo "" >> "$AGENTS_MD"
    cat "${PROJECT_ROOT}/PROJECT_RULES.md" >> "$AGENTS_MD"
fi

# 2. Skills の配置
#    Codex CLIのスキル配置先に合わせる
#    （プロジェクトローカルに .codex/skills/ を作成）
mkdir -p "${PROJECT_ROOT}/.codex/skills"
for skill_dir in "${DEV_WORKFLOW_DIR}/core/skills"/*/; do
    skill_name=$(basename "$skill_dir")
    ln -sfn "$skill_dir" "${PROJECT_ROOT}/.codex/skills/${skill_name}"
done

echo "[codex] インストール完了: ${PROJECT_ROOT}"
```

#### 4.3.3. setup.sh ― 統合エントリーポイント

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${2:-.}"

case "${1:-}" in
    claude)
        bash "${SCRIPT_DIR}/adapters/claude/install.sh" "$PROJECT_ROOT"
        ;;
    codex)
        bash "${SCRIPT_DIR}/adapters/codex/install.sh" "$PROJECT_ROOT"
        ;;
    both)
        bash "${SCRIPT_DIR}/adapters/claude/install.sh" "$PROJECT_ROOT"
        bash "${SCRIPT_DIR}/adapters/codex/install.sh" "$PROJECT_ROOT"
        ;;
    *)
        echo "使用法: ./setup.sh {claude|codex|both} [プロジェクトパス]"
        exit 1
        ;;
esac
```

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

## 9. チェックリスト：改修作業の手順

- [ ] 現在のCLAUDE.mdから、ベンダー中立な内容とClaude Code固有の内容を分離・洗い出し
- [ ] `core/instructions.md` の初版を作成
- [ ] 既存スキルの見直し：Claude Code固有のツール名参照がないか確認し、汎用表現に置換
- [ ] `adapters/claude/install.sh` の実装
- [ ] `adapters/codex/install.sh` の実装
- [ ] `setup.sh` の実装
- [ ] 既存プロジェクトで `setup.sh claude` を実行し、現行と同等の動作を確認
- [ ] 同プロジェクトで `setup.sh codex` を実行し、Codex CLIでの動作を確認
- [ ] `PROJECT_RULES.md` のテンプレートを作成
- [ ] README.md にマルチベンダー対応の使用方法を追記
