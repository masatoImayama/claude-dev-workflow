# dev-workflow プラグインへの申し送り（Tessera Epic #573 実行時に判明した構造的問題）

- **発信元**: Tessera リポジトリ（`NousLagus/tessera`）
- **観測時のプラグイン版**: dev-workflow **v0.14.1**（`dev-workflow-marketplace` / commit `d79a8318`）
- **観測日**: 2026-08-06
- **契機**: `/dev-workflow:run 573`（Epic #573「Stylus 応答遮断（Sanitizer）の全廃」、全7タスク・lanes=3）
- **status**: 発見のみ。dev-workflow 側は未修正。Tessera 側の run では run 実行者が都度回避している

以下は、いずれも「このリポジトリ固有の設定ミス」ではなく **dev-workflow の設計・実装に起因し、
どのプロジェクトで実行しても再現する**と考えられる事象である。深刻度順に記す。

---

## H1【重大】isolation worktree が WAVE_BASE ではなくメインリポの HEAD から作られる

### 症状

ウェーブ2以降の generator が、実装に着手する前にベース検証で必ず停止する。

```
$ git merge-base --is-ancestor 73e152f1e880c719be49d316bcad0b60831e699a HEAD && echo ANCESTOR_OK || echo ANCESTOR_FAIL
ANCESTOR_FAIL

$ git log --oneline -1 HEAD
7141295 Merge pull request #572 ...        ← main の tip
$ git log --oneline -1 epic/epic573/sanitizer-removal
73e152f Merge branch '...' into wave/epic573/1   ← 渡した WAVE_BASE
```

### 原因

`skills/run/SKILL.md` の Step 3 は、generator へ次の2点を同時に指示する。

- 「WAVE_BASE から分岐している」ことを前提として伝える
- 「**`git fetch` / `git checkout` / `git pull` は実行しないこと**」

しかし **isolation worktree を作るのはハーネス**であり、その分岐元は
**メインリポの現在のチェックアウト（通常 `main`）**である。run は
「メインリポのチェックアウトを epic ブランチに切り替えてはならない」と明記しているため、
メインリポは `main` に留まり続ける。結果として:

| ウェーブ | WAVE_BASE | isolation worktree の HEAD | 一致するか |
|---|---|---|---|
| 1 | epic ブランチ tip（= 分岐直後なので `main` と同一） | `main` tip | **偶然一致** |
| 2 以降 | epic ブランチ tip（ウェーブ1の成果を含む） | `main` tip（変わらない） | **必ず不一致** |

**ウェーブ1で成功するため問題が見えにくいが、2ウェーブ目で必ず破綻する。**
Epic が1ウェーブで終わる場合のみ顕在化しない。

### 影響

- ウェーブ2以降のすべてのレーンが停止する（generator の指示遵守は正しい）
- 停止せず実装に進んだ場合はさらに悪く、**先行タスクの成果を含まないベース上で実装され、
  `merge-lane.sh` が exit 10（ベース逸脱）で差し戻す**か、競合として現れる
- 依存関係のある Epic（＝ほとんどの Epic）は自律完走できない

### Tessera 側での回避

run 実行者が generator プロンプトに次を追加した（変更ゼロの新規 worktree なので安全）。

```
git status --short          # 空であることを確認（空でなければ実装せず停止）
git reset --hard <WAVE_BASE>
git merge-base --is-ancestor <WAVE_BASE> HEAD && echo BASE_OK
git log --oneline -1
```

### 提案

`SKILL.md` の Step 3 のプロンプト雛形に上記のベース合わせ手順を組み込むのが最小の修正と思われる。
「`fetch`/`checkout`/`pull` 禁止」は維持したまま、`reset --hard <WAVE_BASE>` のみを
明示的に許可する形が、現在の禁止意図（＝リモート同期をレーンにさせない）とも矛盾しない。
（対象コミットは worktree 間で共有されるオブジェクトストアに既に存在するため、ネットワークアクセスは不要）

---

## H2【重大】生成物（wasm 等）が isolation worktree に無く、大量 SKIP が「緑」に見える

### 症状

同一ウェーブの同一パッケージに対し、レーンごとに矛盾した報告が出た。

| レーン | 報告 | 実態 |
|---|---|---|
| B | `SKIP 74件`（`WASM not found: open ../../bin/engine-v1.wasm`） | 正直な報告 |
| A | `SKIP 0件` | 数えずに `tail` で見ただけ。実際は同様に SKIP していたと推定 |
| C | `SKIP 0件` | `cd /workspace` していたため**リポジトリルート**を検証（H3 参照） |

統合ゲート（Epic worktree・wasm 配置済み）では **SKIP 0件**だったため、
**レーン内ゲートだけが、赤くなるべきテストを飛ばしたまま緑を報告していた**。

### 原因

`SKILL.md` の「プロジェクト固有の準備コマンド」は Epic 開始時に **Epic worktree に対して1回だけ**
実行される設計である。一方 isolation worktree は**その後**にタスクごとに作られるため、
準備の効果が及ばない。さらに `core/roles/generator.md` は
「**タスクごとに再実行しないこと**」と明記しており、generator が自力で補うことも抑止している。

`.gitignore` されている生成物（コンパイル済み wasm・ビルド成果物・fixture 等）を持つプロジェクトで
一般に再現する。Tessera では `bin/engine-v1.wasm` が該当し、これが無いと
wasm 依存テストは fail ではなく **skip** するため「緑」に見える。

### 影響

レーン内ゲートが検証機構として機能しない。統合ゲートが最後に拾うため最終的な安全性は保たれるが、
**失敗の検出がウェーブ末尾まで遅れ、原因レーンの特定に統合ゲート失敗時の二分探索が必要になる**。

### 提案

- 「準備コマンド」を **Epic 開始時1回**ではなく、**各 isolation worktree の初回コマンド実行時**にも
  適用する（あるいは generator に「準備コマンドは自分の worktree で1回実行せよ」と指示する）
- 併せて `generator.md` の「タスクごとに再実行しないこと」の文言を、
  worktree をまたぐケースと矛盾しないよう見直す

---

## H3【中】generator が `cd /workspace` して別ツリーを検証しうる

### 症状

レーン C が次のコマンドで「全パッケージ緑・SKIP 0件」と報告した。

```
sandbox-exec.sh --epic epic573 'cd /workspace && go build ./... && go vet ./... && go test ./...'
```

`sandbox-exec.sh --print-plan` の `workdir` は呼び出し元 cwd から解決される
（このケースなら `/workspace/.claude/worktrees/agent-XXX`）が、`cd /workspace` がそれを上書きし、
**リポジトリルート＝未変更の `main` チェックアウト**をテストしていた。
自分の変更は一切検証されていない。

（レーン C の変更は `CLAUDE.md` / `web/app.jsx` のみだったため実害は無かったが、
コード変更のレーンで起きればゲートは無意味になる）

### 原因

`SKILL.md` / `generator.md` に「作業ディレクトリを変えるな」という明示がない。
`sandbox-exec.sh` はマウント元をリポジトリルートにするため、
コンテナ内から `/workspace` は常に見えており、`cd` は容易に成功してしまう。

### 提案

generator への指示に「`cd` で作業ディレクトリを変えない」を明記する。
あるいは `sandbox-exec.sh` 側で workdir を強制する（`cd` を含むコマンドを検出して警告する等）。

---

## H4【中】`plan-waves.sh` が期待する issue 本文の書式と、`epic` skill が生成する書式が食い違う

### 症状

Epic #573（7タスク）に対して `plan-waves.sh --epic 573` を実行した結果:

```
ウェーブ 1: 298      ← Epic #266 のタスク。#573 とは無関係
ウェーブ 2: 574
...
ウェーブ 8: 580

[警告] 前提未宣言（宣言漏れ・完全逐次にフォールバック）:
  #298 #574 #575 #576 #577 #578 #579 #580
```

**(a) 他 Epic のタスクが混入**し、**(b) 依存が1件も拾えず完全逐次にフォールバック**した。

### 原因

`plan-waves.sh` が探す行と、実際の issue 本文の行が一致しない。

| 用途 | `plan-waves.sh` が探す行 | Epic #573 のタスク issue の実際の行 |
|---|---|---|
| Epic 判定 | `- Epic: #N` | `親 Epic: #573` |
| 依存判定 | `- 前提: #N` | `先行: #575` |

Epic 判定は「行が無ければフェイルオープンで含める」設計のため、
**書式が違うと全タスクがフェイルオープンし、Epic 絞り込みが事実上無効化される**
（`#298` は `親: Epic #266 / 由来: #268 T2` と書かれており、これも一致しない）。
依存判定も同様に全滅し、7タスクが8ウェーブの完全逐次になった。

なお `#298` は `task` ラベル付き・open なので、`gh issue list --label task --state open` に必ず現れる。
**同一リポジトリで複数 Epic が並行している限り、常に混入する。**

### 影響

- 無関係な Epic のタスクが実行対象に入る（本件では run 実行者が気づいて除外した）
- 並列度が指定値によらず 1 に落ちる（本件では 5ウェーブで済むものが 8ウェーブになる計算だった）

### Tessera 側での回避

`plan-waves.sh --from-file <TSV>` に切り替え、Epic 本文に書かれた依存グラフ
（`T1 → T2 → T3 → T4 → T7`、`T5`/`T6` は独立）を run 実行者が TSV へ書き起こした。
結果、7タスク・5ウェーブへ収束した。issue 本文は変更していない。

### 提案

`plan-waves.sh` と `skills/epic/SKILL.md` のどちらが真実の源かを決め、書式を揃える。
判定を `- ` 接頭辞に依存させず、`親 Epic: #N` / `先行: #N` のような表記ゆれも
受理する（あるいは Epic skill 側のテンプレートを `- Epic:` / `- 前提:` に統一する）のが望ましい。
**書式不一致がエラーではなくフェイルオープンとして黙って劣化する**点が、
この問題を発見しにくくしている（run の他の箇所は fail loud を志向しているため、方針が非対称）。

---

## H5【小】SKIP 件数の報告が自己申告であり、数え方が指定されていない

`SKILL.md` は「SKIP されたテストがあれば件数と内容を報告に含めること」とだけ指示し、
数え方を示していない。結果、レーン A は `tail -100` の出力に `--- SKIP` が見えなかったことをもって
「SKIP 0件」と報告した（H2 のとおり実際には skip していたと推定される）。

同節が「**`ok` の有無だけで判定してはならない**」と強く書いているにもかかわらず、
その検証手段が自然言語の依頼のままである。
`go test ./... -v 2>&1 | grep -c "^--- SKIP"` のような**具体的なコマンドを指定する**か、
統合ゲート側で機械的に数える（run が実行し、レーン報告に依存しない）のが確実と思われる。

---

## H6【小】`.claude/worktrees/agent-*` が大量に残留する

観測時点で **163個**の `agent-*` worktree が登録されたまま残っていた（本 run 開始以前からの蓄積）。

`SKILL.md` のクリーンアップ節は「generator の isolation worktree はハーネスが自動整理する」
としているが、**変更を加えた（＝コミットを持つ）worktree は自動削除の対象外**と見られ、
Epic を重ねるごとに単調増加する。`git worktree list` の出力が数百行になり、
本件のような調査時に見通しが悪い。ディスク使用量も無視できない。

run の完了時に、当該 Epic で使った `agent-*` worktree を（Epic ブランチへ取り込み済みであることを
確認したうえで）片付ける導線があるとよい。

---

## 付録: 本 run での実測（参考）

| 項目 | 値 |
|---|---|
| ウェーブ1（#574 / #578 / #579 の3レーン並列） | 実装 16m23s ＋ 統合 0m10s ＋ 統合ゲート 3m26s = **20m06s** |
| ウェーブ1 レーン内訳 | A=#574 5m52s / B=#578 5m35s / C=#579 14m24s |
| generator トークン消費 | #574 218k / #578 242k / #579 178k / #575（H1 で中断）133k |

- 統合ゲート（Epic worktree・wasm 配置済み）は全パッケージ緑・**SKIP 0件**・可読性ガード通過
- H1 による #575 の中断は実装着手前だったため、成果物への影響は無い（試行1回として計上）
