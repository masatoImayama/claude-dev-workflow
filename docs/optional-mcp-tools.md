# 任意依存として結線する外部 MCP ツール

Epic #66 の Phase 1（#67）で実測した、プラグイン宣言 MCP サーバーの未導入時挙動の記録。
Phase 3（#71 context7）・Phase 4（#73 code-review-graph）はこの結果に乗る。

## 対象ツール

| ツール | パッケージ | 起動コマンド（上流で確認した値） | 導入手順（上流で確認した値） |
|---|---|---|---|
| context7 | `@upstash/context7-mcp`（npm, v3.2.5時点で確認） | `npx -y @upstash/context7-mcp`（`bin.context7-mcp = dist/index.js`。既定は stdio。`--transport http` は `npm run start` 用のスクリプトであり MCP サーバーの既定起動には使わない） | `npx ctx7 setup` で OAuth 認証・APIキー発行・スキル導入まで一括で行う方式が現在の上流の主流（README 記載）。手動で MCP クライアントに登録する場合はホスト型サーバー `https://mcp.context7.com/mcp` を使う案内が前面に出ているが、ローカルで動かす npm パッケージ `@upstash/context7-mcp` は現在も配布されている |
| code-review-graph | `code-review-graph`（PyPI, Python 3.10+） | `code-review-graph serve`（stdio既定。`code-review-graph mcp` はエイリアス。`code-review-graph serve --http` でHTTP切替可） | `pip install code-review-graph`（または `pipx install` / `uvx`）→ `code-review-graph install --platform claude-code` でMCP設定を自動生成 → `code-review-graph build` でグラフを構築 |

**上流の想定との差分（実測して確認した値）:**

- Epic #66 本文は context7 のMCPツール名を `resolve-library-id` / `get-library-docs` の2つと想定していたが、
  上流 README（`upstash/context7`, 2026-08-05時点の `master`）を確認したところ実際のツール名は
  `resolve-library-id` / **`query-docs`** だった（`get-library-docs` ではない）。
  Phase 3（#71・#72）で正確な名前を使うこと。
- code-review-graph のMCPツール数は上流 `docs/COMMANDS.md` の `#### \`...\`` 見出し数を数えて **30個**と確認した
  （Epic本文の「30ツール」という記載と一致）。

## 実測手順

Claude Code CLI（`claude`, v2.1.222）が使える環境だったため、実際に起動して観測した。
一時ディレクトリを作り、存在しないコマンドを `command` に指定した `.mcp.json`（プロジェクトスコープのMCP設定。
`.claude-plugin/plugin.json` の `mcpServers` フィールドとスキーマは同じ）を置いて `claude -p`（非対話モード）で
起動した。作業ディレクトリはプロジェクト外の一時ディレクトリに限定し、リポジトリを汚さなかった。

```bash
TMPDIR_EXP="$(mktemp -d)"
cat > "${TMPDIR_EXP}/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "does-not-exist": {
      "command": "dev-workflow-nonexistent-binary",
      "args": []
    }
  }
}
JSON

cd "${TMPDIR_EXP}"
time claude -p "Bashツールでecho check-ok を実行し、最後にDONE_MARKERとだけ出力してください。" \
  --mcp-config .mcp.json --strict-mcp-config --allowedTools "Bash" \
  --permission-mode bypassPermissions --debug-file debug.log --output-format json
```

サブエージェント起動の確認には `--agents` でアドホックなエージェントを定義し、`tools:` に存在しない
MCPツール名（`mcp__does-not-exist__some_nonexistent_tool`）を含めて `Task` ツールから起動させた。

起動遅延（タイムアウト待ち）の確認には、コマンドは実在するが MCP ハンドシェイクに一切応答しない
プロセス（`sleep 60`）を `command` に指定した別の `.mcp.json` を用意し、同様に計測した。

`--output-format stream-json --verbose` で起動すると、非デバッグモードでも `system init` イベントに
`mcp_servers` フィールドとして各サーバーの接続状態（`status: "failed"` 等）が出ることも確認した。

## 実測結果

### 1. セッションは起動するか

起動する。存在しないコマンドを宣言しても `claude -p` は正常に完走した（`is_error: false`,
`terminal_reason: "completed"`, `stop_reason: "end_turn"`, `exit_code: 0`）。

### 2. 警告は出るか。どこに出るか

出る。実出力（`--debug-file` で得たログの該当行。個人環境固有の情報は除いた抜粋）:

```
2026-08-05T11:12:05.038Z [DEBUG] MCP server "does-not-exist": Starting connection with timeout of 30000ms
2026-08-05T11:12:05.300Z [ERROR] "MCP server \"does-not-exist\" Server stderr: 'dev-workflow-nonexistent-binary' は、内部コマンドまたは外部コマンド、
操作可能なプログラムまたはバッチ ファイルとして認識されていません。
2026-08-05T11:12:05.301Z [DEBUG] MCP server "does-not-exist": Connection failed after 265ms (-32000): MCP error -32000: Connection closed
2026-08-05T11:12:05.301Z [ERROR] MCP server "does-not-exist" Connection failed (-32000): MCP error -32000: Connection closed
```

この `[ERROR]` ログは `--debug-file` を指定したときのみファイルに書かれる。既定（非デバッグ）の
`claude -p` 実行では、通常の stdout / stderr には一切出ない（実測: `stderr.log` は0バイト）。

ただし `--output-format stream-json --verbose` を付けると、デバッグフラグなしでも `system init` イベントに
構造化された形で接続状態が載ることを確認した（実出力の該当部分）:

```json
{"type":"system","subtype":"init", ... ,"mcp_servers":[{"name":"does-not-exist","status":"failed"}], ...}
```

`tools` フィールドには `Task` `Bash` `Read` `Edit` 等の標準ツールが通常どおり全て列挙されており、
MCPサーバーの接続失敗がツール一覧に影響しないことも同時に確認できた。

### 3. 起動後、他のツール（Read / Bash 等）が通常どおり使えるか

使える。上記と同じセッションで `Bash` ツールに `echo check-ok` を実行させたところ、正常に完了した
（実出力: `"result":"...Bash実行結果: \`echo check-ok\` → \`check-ok\`\n\nDONE_MARKER"`）。

### 4. サブエージェントを起動できるか（`tools:` に存在しないMCPツール名を書いた場合）

できる。`--agents` で `tools: ["Bash", "mcp__does-not-exist__some_nonexistent_tool"]` を持つ
アドホックエージェント `exp-agent` を定義し、`Task` ツールから起動させたところ、正常に起動・完走した。

実出力（デバッグログ、個人環境固有の情報を除いた抜粋）:

```
2026-08-05T11:12:45.723Z [DEBUG] [API REQUEST] /v1/messages ... source=agent:custom:exp-agent
2026-08-05T11:12:51.221Z [INFO] [Stall] agent_completion agentId=a048a0de39c77bbe7 agentType=exp-agent exitPath=completed durationMs=5510 turns=2 finalStopReason=end_turn
```

最終結果（実出力）:

```
exp-agent は正常に起動し、Bash で `echo subagent-ok` を実行しました。標準出力は `subagent-ok`、
終了ステータス 0（stderr なし）。存在しない MCP ツールが定義に含まれていても、エージェントの起動と
Bash 実行は問題なく動作しました。
```

存在しないMCPツール名を `tools:` に書いても、エラーにならず単に「そのツールは呼べない（他の宣言済み
ツールだけが使える）」状態になるだけだった。

### 5. 起動に時間がかかるか（タイムアウト待ちが発生するか）

**ケースA（コマンドが存在しない・即座に失敗する場合）:** 接続試行から失敗確定まで実測 **265〜329ms**。
セッション全体の所要時間（13〜20秒、LLM応答待ちを含む）に対して無視できる差であり、体感できる遅延は無い。

**ケースB（コマンドは存在するがMCPハンドシェイクに応答しない＝ハングする場合）:** 実際に `sleep 60` を
`command` に指定して計測したところ、次のとおり **既定のタイムアウト上限（30000ms）まで待ってから**
最初のLLMリクエストが発行された（実出力、個人環境固有の情報を除いた抜粋）。

```
2026-08-05T11:13:46.087Z [DEBUG] MCP server "hangs-forever": Starting connection with timeout of 30000ms
2026-08-05T11:14:16.199Z [DEBUG] MCP server "hangs-forever": Connection timeout triggered after 30115ms (limit: 30000ms)
2026-08-05T11:14:16.203Z [DEBUG] MCP server "hangs-forever": Connection failed after 30118ms: MCP server "hangs-forever" connection timed out after 30000ms
2026-08-05T11:14:16.203Z [ERROR] MCP server "hangs-forever" Connection failed: MCP server "hangs-forever" connection timed out after 30000ms
2026-08-05T11:14:16.338Z [DEBUG] [API REQUEST] /v1/messages ... source=sdk
```

MCP接続タイムアウト確定（16.203）の135ms後に最初のAPIリクエストが発行されており、
**セッションの最初のターン開始はMCP接続試行の解決（成功 or タイムアウト）を待ってから行われる**ことを
確認した。実測の総所要時間（`real 0m36.964s`）もこれと整合する。

この待ちは一度きり（セッション開始時のみ）で、他のツール呼び出し（Bash等）やサブエージェント起動を
繰り返しブロックするものではない。ただし「コマンドが存在するが応答しない」壊れた導入状態では、
セッション開始が最大約30秒遅れうる。これは「コマンドが存在しない（＝未導入）」という本来の想定
ケースには当てはまらないが、Phase 3・4でコマンドを確定する際の注意点として残す（後述）。

## 採用方式

**方式A: 宣言方式** を採用する。

根拠:

1. 起動失敗（コマンドが存在しない、最も典型的な「未導入」の形）でもセッションは正常に起動・完走する
2. 起動失敗は警告として記録されるだけで（`system init` の `mcp_servers[].status`、`--debug-file` のログ）、
   セッションをブロックしない。既定の非デバッグ実行では通常のstdout/stderrに一切出ず汚染もしない
3. 他のツール（Bash等）は接続失敗の影響を受けず、宣言時と同一セッション内で問題なく動作する
4. サブエージェントの起動、および `tools:` に存在しないMCPツール名を含めた場合でも、エラーにならず
   正常に起動・完走する
5. 起動遅延は「コマンドが存在しない」場合は無視できるレベル（実測265〜329ms）。「コマンドは存在するが
   応答しない」場合のみ最大タイムアウト（実測30115ms、既定30000ms）まで一度だけ遅延しうるが、これは
   セッションが止まる／他ツールに影響が出るという方式Bへの分岐条件には該当しない
   （起動が遅れるだけで、起動自体は成功する）

したがって「起動失敗でも続行し、他ツール・サブエージェントに影響が無い」という方式Aの採用条件を満たす。

**Phase 3・4への申し送り事項（注意点）:** 上記5のとおり、コマンドが存在するのに応答しない
（壊れた導入・ネットワーク未接続でのオンデマンド取得待ち等）状態では最大約30秒の起動遅延が発生しうる。
`#71`（context7）・`#73`（code-review-graph）でコマンドを確定する際は、フェイルファストな起動
（パッケージがローカルに無ければ即座にエラー終了する等）を優先し、ネットワーク越しのオンデマンド
取得に依存する起動コマンドを避けることが望ましい。

## MCP ツール名

方式Aを採用したため、`.claude-plugin/plugin.json` の `mcpServers`（または `.mcp.json`）で宣言する。
プラグイン由来のMCPツール名の書式は次のとおり（Claude Code公式ドキュメント準拠）。

```
mcp__plugin_<plugin-name>_<server-name>__<tool-name>
```

`<plugin-name>` は本プラグインの `.claude-plugin/plugin.json` の `name` フィールドの値（`dev-workflow`）で
固定される。`<server-name>` は `#71`（context7）・`#73`（code-review-graph）で `mcpServers` に登録する
サーバーキー名で確定するため、本タスクでは確定しない。上記「対象ツール」節で確認した実際のツール名を
使うと、想定される名前は次のとおり（`<server-name>` は仮に `context7` / `code-review-graph` とした場合の例）。

- context7: `mcp__plugin_dev-workflow_context7__resolve-library-id`,
  `mcp__plugin_dev-workflow_context7__query-docs`
  （`get-library-docs` ではなく `query-docs` である点に注意。上記「対象ツール」節参照）
- code-review-graph: `mcp__plugin_dev-workflow_code-review-graph__<tool_name>`
  （30個のツール名は上流 `docs/COMMANDS.md` の `#### \`...\`` 見出しを参照。例:
  `build_or_update_graph_tool`, `get_minimal_context_tool`, `get_impact_radius_tool` 等）

## 任意依存であることの保証

外部ツール（context7 / code-review-graph）が未導入の環境で、方式Aの宣言によって次のことは**起きない**
（実測で確認済み）:

- セッションが起動できない、または途中で落ちる
- 他のツール（Bash / Read / Edit / Task 等）が使えなくなる
- サブエージェントが起動できなくなる
- `tools:` に存在しないMCPツール名を書いたサブエージェント定義がエラーになる
- 通常のstdout/stderrにエラーメッセージが漏れてユーザー向け出力を汚す
- 体感できるほどの起動遅延（「コマンドが存在しない」ケースでは実測265〜329ms。無視できる）

一方、次の限界がある（未導入とは異なる「壊れた導入」のケースでのみ発生する。上記「実測結果 5」参照）:

- コマンドが存在するのに応答しない状態（壊れた導入・ネットワーク未接続でのオンデマンド取得待ち等）では、
  セッション開始が最大約30秒（既定タイムアウト）遅れうる。これはセッションの起動そのものを妨げるもの
  ではなく、開始が遅れるだけで、一度きり（他のツール呼び出しの繰り返しをブロックするものではない）

## Phase 4: code-review-graph の結線（#73）

上記「採用方式」（方式A: 宣言方式）に従い、code-review-graph を **evaluator にのみ**結線した。
planner / generator には与えない（Epic #66 決定4）。

### 上流の起動コマンド（上流 README で確認した値）

`code-review-graph serve`（`args: ["serve"]`）。ホストの `PATH` 上の `code-review-graph`
コマンドをそのまま `command` に指定する（`pip install code-review-graph` 等で導入されていれば
解決される。未導入なら「コマンドが見つからない」という、上記「実測結果」で確認済みの
最も典型的な未導入ケースに落ちる）。

### Claude Code側: サーバー単位のツール許可

`.claude-plugin/plugin.json` の `mcpServers` に `code-review-graph` を宣言し、
`adapters/claude/overlays/evaluator.md` の frontmatter `tools:` に
`mcp__plugin_dev-workflow_code-review-graph`（`mcp__<server>` パターン。個別ツール名の
`__<tool-name>` を付けずサーバー名までで止める）を追加した。これは Claude Code 公式ドキュメント
（`sub-agents.md`）に明記された「MCPサーバー単位のパターンはサーバーの全ツールを一括で
許可/除外する」という仕様に基づく。

上流 `docs/COMMANDS.md` を確認したところ、code-review-graph のMCPツールは実際に30個
（`#### \`...\`` 見出し30件）であり、Epic本文の記載と一致した。30個を個別に列挙せずサーバー単位で
許可したのは、列挙の手間を惜しんだからではなく、Epic本文が明記する「ツールが多いから絞る、という
理由で恣意的に間引かない」という方針に従い、evaluatorに全30ツールへのアクセスを一括で与えるためである
（個別列挙してもサーバー単位許可しても、結果として与えるツールの集合は同じ30個になる）。

### Codex側: エージェント単位の `mcp_servers` 宣言

Codex はサブエージェント定義自体をプラグインで配布できない
（`docs/dev-workflow-multi-vendor-guide.md` 3.3.4）。したがって `.codex-plugin/plugin.json` の
`mcpServers`（セッション全体に効くグローバル宣言）は使わず、代わりに
`adapters/codex/overlays/evaluator.toml` に直接 `[mcp_servers.code-review-graph]` テーブルを
宣言した。config.toml のキー（`mcp_servers` を含む）はエージェント定義に併記でき、
省略した場合のみ親セッションから継承される（同ガイド 3.3.2）。`planner.toml` / `generator.toml`
には何も追加していないため、code-review-graph はグローバルにもそれらのエージェントにも渡らない。
Claude Code側の「セッション全体に宣言し、サブエージェント単位のツール許可で絞る」方式とは
機構が異なるが、**「evaluatorだけが使える」という結果は同じであり、機能差は無い。**

Codex公式の設定リファレンス（`mcp_servers.<id>.required`）によれば、`required` を明示しない
MCPサーバーは既定で非必須接続であり、起動できなくてもエージェントの起動をブロックしない。
これは Claude Code側で実測した「起動失敗でもセッションが継続する」という挙動と整合する。
ただし、この既定挙動は公式ドキュメント記載を根拠にしたものであり、Claude Code CLIのように
実際に起動して観測してはいない（#67の実測はClaude Code CLIのみを対象にしている）。将来
Codex側でも同様の実測を行う場合は、この記述を実測結果で更新すること。

### `.gitignore`

code-review-graph の生成物（SQLiteグラフDB・キャッシュ）は `.code-review-graph/` に置かれる
（上流READMEで確認済み）。`.gitignore` に追加した。

### evaluator にのみ与えることの検証

`agents/planner.md` / `agents/generator.md` / `codex-agents/planner.toml` /
`codex-agents/generator.toml` に `code-review-graph` という文字列が一切現れないことを
`tests/run-tests.sh` で検査する。

### dev-workflow 自身では発火しないのが正常

code-review-graph は Tree-sitter による AST 解析が中核であり、dev-workflow 自身のロジックの大半は
`core/*.md` と `skills/*/SKILL.md`（markdown）および bash に載っている。したがって
**dev-workflow自身の開発では、code-review-graphの呼び出しグラフからほとんど情報が出ず、
発火しないのが正常である。** この限界は `core/roles/evaluator.md` の
「## 任意ツール: code-review-graph」節にも明記した。効果が出るのは dev-workflow が駆動する側の
プロジェクト（実コードを持つプロジェクト）である。
