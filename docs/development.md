# 開発手順

調査・変更・検証・PR を、一つの作業単位として進める手順。製品仕様ではなく、[AGENTS.md](../AGENTS.md) の規約を、具体的な運用に結び付ける。

## 正本と開始時の読取り順

| 対象 | 正本・役割 |
|---|---|
| 製品要件・受け入れ条件・実装の状態・未決事項 | [SPEC.md](../SPEC.md) が唯一の正本 |
| 作業規約・操作権限・不変条件 | [AGENTS.md](../AGENTS.md)。本書は、その派生手順であり、追加の実施許可ではない |
| Issue の現在の状態・Report | mikan（[下記](#mikan-の-issue-進行)）。文書に Status の写しを維持しない |
| 構成・観測方法・証拠 | [構成説明](architecture.md)、[検証手順と記録](verification.md) |

1. 依頼の対象と、SPEC の該当節（機能要件・受け入れ条件と状態・未決事項）を読む。
2. AGENTS と本書を読み、変更範囲・許可された操作・確認方法を特定する。既存の利用者の変更を保持する。
3. [構成説明](architecture.md) の該当 Module と、実際のソース・`Package.swift` を読む。

## 作業単位と最小の経路

一回の作業を、利用者に見える一つの成果と、それを観測する方法で定義する。文書量・テスト件数・部品数を、完成の基準にしない。許可された範囲の**最小で安全な端から端までの経路**を早く確かめ、周辺の抽象化や将来対応を先行させない。

- 調べて分かる環境の前提は、先に読む。設定・権限・鍵・認証を変えて、前提不足を補わない。
- **実機でしか確かめられないこと（マイク・画面・権限・実アプリ）は、小さな試作（CLI・自作ウィンドウ）で、先に確かめる。** 試行の前に、仮説・結果を区別できる観測・停止条件を決める。
- プロンプトの文面（選択肢の説明・言語モデルへの指示）を変えたら、**測定**（`just eval`）で、効果を確かめる。印象で直さない。結果を見て文面・コーパスを直したら、記録に書く（[検証手順と記録](verification.md#コーパスの扱い)）。
- 利用者が報告した結果は、事実として扱う。同じ失敗を確認するだけの再試行や、根拠のない推測の修正はしない。

## 環境

macOS 26 以降・Apple silicon・Swift 6.2 以降（Xcode または Command Line Tools）。外部の Swift パッケージはない。実行時の外部ツール：[agent-desktop](https://github.com/vercel-labs/agent-desktop)（`npm install -g agent-desktop`。`agent-desktop permissions` で、アクセシビリティの許可を確認）、[just](https://github.com/casey/just)（任意。なければ `scripts/` を直接実行）。

## ビルドと実行

`just` で入口を一覧できる（[justfile](../justfile)）。

| レシピ | 内容 |
|---|---|
| `just build` | リリースビルド（`.build/release/vc`・`Fixture`）。Command Line Tools だけの環境で出る、リンカの `search path … not found` の警告（無害）は、表示しない |
| `just test` | 単体テスト（Swift Testing）。画面・音声・モデルは使わない |
| `just package` | 配布用の tar.gz と SHA-256 を `dist/` に作り、検査する（リリースのワークフローと同じ手順） |
| `just install` | ソースからビルドした `vc` を `~/.local/bin` へコピー（`BIN_DIR` で場所）。リポジトリの `models/tiny-jev-0.6b`（開発用。`tokenizer.json` と `model.safetensors` がそろっているもの）があり、`~/.voice-control/models/tiny-jev-0.6b` がなければ、複製せず、そこへシンボリックリンクを張る（1.2 GB を取り直さない）。以前の `~/Library/Application Support/voice-control/models` に、この script が張ったリンクがあれば、取り除く |
| `just uninstall` | `vc` とモデルのリンクを取り除く。モデルの本体・各種の許可には触れない |
| `just eval` | 「操作の依頼か」の判定（当てはまるスキルがないとき、既定スキルに回すか）の当たり率（`vc eval-gate corpus/gate.tsv`。Tiny-Jev のモデルが要る。実機は操作しない） |
| `just fixture [--ja\|--many N\|--dup]` | 検証用の自作ウィンドウを起動（`just fixture-stop` で終了） |
| `just vc <args>` | ビルドして `vc` を呼ぶ |

- ターゲットは `VCCore`・`VCDecision`・`VCSpeech`・`VCSkill`（ライブラリ）と、`vc`・`Fixture`（実行ファイル）、テスト専用の `TestSupport`。依存の向き（下向きだけ）は `Package.swift` で宣言し、コンパイラが強制する。宣言にない `import` を差分ビルドでも失敗させるには、`--explicit-target-dependency-import-check=error` を付ける（上の入口は付けている。素の `swift build` は、警告だけのことがある）。テストもターゲットごと（`Tests/VCCoreTests` など。`@testable import` で、対応するターゲットの `internal` を使う。実行ファイルの `vc` も、`Tests/vcTests` が `@testable import vc` で、引数の読み方とコマンドの一覧を試す）。1 つのターゲットだけを試すには `./scripts/test.sh --filter VCSkillTests`。
- テストは `./scripts/test.sh`。Command Line Tools だけの環境では、Swift Testing のマクロのプラグインのパスを、明示して渡す必要があり、素の `swift test` は失敗する。
- テストの置き場所：**ターゲットごと**（`Tests/<ターゲット>Tests/`。`vc` は `Tests/vcTests`）、**責務別**（1 ファイル 1 領域で、ファイル名はスイート名：`ChooserTests.swift`・`SettingsTests.swift`・`CommandPolicyTests.swift` など。目安は 250 行以下で、超えるなら領域で分ける）。**偽の実装は別のファイル（そのスイートでしか使わない数行の偽物は、スイートの中でよい）**（`VoiceLoopFakes.swift`・`SkillRunnerFakes.swift` のように、使うスイートの名前を付ける）。複数のターゲットで使う偽物は、**`Tests/TestSupport/`**（テスト専用の `.target`。`OptionScorer` の偽物＝`TargetScorer`・`OptionSpy`・`SkillScorer`、集める道具＝`Collected`・`plain`）に、用途ごとに 1 つずつ置く。作りは次のとおり：公開 API だけを使う（`@testable` が要る偽物、たとえば `SkillExecuting` の偽の実行者は、そのテストターゲットに残す）／インスタンスで状態を持ち、グローバルの状態は持たない（CI は、全ターゲットのテストを 1 つのプロセスで並行に動かすため）／依存するのはテストターゲットだけ。本番のターゲットは `TestSupport` に依存せず、参照もしない。素の `swift build` は `TestSupport` もビルドするが、`vc` には入らない（`scripts/package.sh` は `--product vc`）。
- **CI は、全ターゲットのテストを 1 つのプロセスで並行に動かす**（`release.yml` の `swift test --explicit-target-dependency-import-check=error`。2026-11-03 の CI のログで `Test run with 186 tests in 41 suites` が 1 回）。ローカル（Swift 6.4）の `just test` は、ターゲットごとに別の実行として出る（`Test run with …` が 6 回。41・28・47・46・8・16 件で、合計 186 件・41 スイート。2026-11-04 に確認。PC 操作の廃止のあとは 5 回：34・28・47・9・16 件で、合計 134 件・25 スイート。理由は、調べていない）。並列度が違うので、全体の並行の下では、テストの時間・スレッドが競合して、失敗することがある：実際に、`ProcessRunner` のテストが、CI で、出力が終わらず時間の上限に達して失敗した（原因は、共有のスレッドの枯渇と**推定**。直接の証拠は未取得。[構成説明](architecture.md#時間と並行)）。CI の結果も、確かめる。
- CI のツールチェーンは、ローカルと違うことがある：この記録の時点で、ローカルは Swift 6.4（macOS 27）、CI は Xcode 26.6・Swift 6.3.3（macOS 26.6.2。2026-11-03 の CI のログ）。CI のログに、警告が出たことがある（`SaySpeaker` の `nonisolated(unsafe)` が不要・`SkillRunnerTests` の `NSLock` を async の文脈で使っている、の 2 種。直したあとの CI のログは、警告 0）。変更のあとは、CI のログの `warning:` も見る。
- `Fixture` は `nohup` で起動する。サブシェルの `( … &)` で起動すると、agent-desktop が TIMEOUT する（実測）。`just fixture` は、そうしている。
- 検証中に、環境変数（`VC_HOME`・`BIN_DIR`・`MODEL_LINK`）を、シェルに残さない。残ったまま `just install` を実行すると、意図しない場所に入る（実際に起きた）。
- モデルの取得は `vc model download`（`~/.voice-control/models/tiny-jev-0.6b`。版を固定・SHA-256 の検証・再開）。確認は `vc model status [--verify]`。
- モデルの探し方：`--model`、`VC_MODEL_DIR`、`~/.voice-control/models/tiny-jev-0.6b`、`./models/tiny-jev-0.6b`（開発用）の順。

## コマンドの足し方

`vc <name>` を足すには、次を、同じ変更で行う（構造は [構成説明](architecture.md#vc-のコマンドの構造)）。

1. `Sources/vc/Commands/<Name>.swift` に、`Command` を実装した型を置く：`static let info`（名前・グループ・使い方・説明・オプション・例。`vc --help`・`vc <name> --help` は、ここから作られる）と、`run(_ arguments: Arguments, _ context: CommandContext)`。`run` の中では、自分のオプションを `var arguments = arguments` に写して `option`・`flag` で取り除き、位置引数は `arguments.positionals`（コマンド名を除く）、共通のオプション（`--model`・`--floor`・`--yes` など）は `context.options`、モデルは `context.loadJev()`、設定は `context.currentSettings()`、スキルは `context.loadSkills()` から使う。失敗は `fail`（終了コード 1）、使い方の誤りは `usageError`（2）。Tiny-Jev のモデルを読むコマンドは、`Help.modelUsers` に名前を足す（共通のオプションを案内する）。
2. `Commands.all`（`Sources/vc/Command.swift`）に、型を足す。**この並びが、`vc --help` の表示順**（グループの中）になる。
   - モデルを使うコマンドなら、`Help.modelUsers`（`Sources/vc/Help.swift`）に名前を足す（`vc <name> --help` に、共通のオプションが出る）。
3. テストを足す：引数の読み方に関わるなら `Tests/vcTests/ArgumentsTests.swift`（共通のオプションは `CommonOptionsTests.swift`）。コマンドの一覧とヘルプは `CommandRegistryTests.swift` が確かめる（名前の重複・グループごとの表示）。スキルの実行の流れ（判断）は `Tests/VCSkillTests/SkillRunnerTests.swift`、その出来事の表示（`TerminalReporter`・`HUDReporter`）は `Tests/vcTests/TerminalReporterTests.swift`・`HUDReporterTests.swift`。声の流れ（`vc listen --hotkey` の調整：Esc・待ち行列・録音）は `Tests/VCSpeechTests/VoiceLoopTests.swift`（録音・文字起こし・トリガー・Esc の偽物は `VoiceLoopFakes.swift`。マイク・音声認識は使わない）。出力は、変更の前後の `vc` を、`NO_COLOR=1`・一時の `VC_HOME` で動かして、比べる。

## 変更の進め方

1. 守る振る舞いを確かめるテストがあるか見る（なければ、利用者に見える振る舞いを確かめるテストを、先に足す）。
2. 変更して、`just test`。プロンプト（選択肢の説明・「操作の依頼か」の判定）に触れたら、`just eval`。
3. 実機の挙動に関わるなら、自作ウィンドウ（`just fixture`）で、実際の経路を動かして観測する。
4. 構成・要件・検証の記録に影響するなら、同じ変更で、文書を更新する（[AGENTS.md](../AGENTS.md#文書とツールの保守)）。

## mikan の Issue 進行

**初期化済み**。Issue の ID は mikan が採番する。進め方は、meeting-analyzer の運用に倣う。

- `.mikan/` 全体は Git 管理外（`.git/info/exclude`）のローカル作業状態であり、別の clone へ Issue やボード設定は引き継がれない。配下を直接参照・編集せず、文書のリンク対象にも含めない。Issue の読取り、Status 更新、Report 追加は mikan MCP だけで行う。
- 使える機能は、`search_tools` で発見し、`get_tool_details` で schema と分類を確認する。読取り専用と分類されたものだけを `call_read_tool`、更新または未分類を `call_write_tool` から呼ぶ（`get_board` のように、読むだけでも、未分類のものは `call_read_tool` に拒否される。読むだけと確かめてから、`call_write_tool` を使う）。
- 実装 Issue は **`backlog → ready → active → completed`** の順で進める。各遷移の直前に、現在の Status を再読取りし、期待する前状態に一致することを確認する。

| Status | 扱い |
|---|---|
| `backlog` | 候補。Issue があるだけでは着手許可にならない |
| `ready` | 対象範囲、前提・依存、SPEC の条件と今回の操作権限を確認済み |
| `active` | 実装直前に移す。同時に active の実装 Issue は最大 1 件 |
| `blocked` | 未承認、前提不足、検査失敗、未解決レビュー、merge・同期・受け入れの阻害などを理由付きで記録する |
| `completed` | 必要な検証・レビュー・受け入れ、PR の normal merge、workspace 同期、Report が揃った後にだけ移す |

- 通常の流れ：実装 → 対象と失敗ケースの検証 → 全体検査（`just test`・必要なら `just eval`）→ 独立レビュー → 指摘修正 → PR → `main` へ normal merge → **GitButler 同期（`but pull`。毎回）** → Report → Status を再読取りして `completed`。
- 検査失敗・未解決レビュー・未マージ・同期の未完了・受け入れの不足は、`active` または理由付き `blocked` に残し、完成を宣言して次の実装 Issue を開始しない。**人間の確認（マイクの実録音・声の「はい」・実アプリでの動作・許可の流れ）は、別の判断として残る**。Issue の完了は、製品全体の受け入れではない。
- Report に、対象と SPEC 節、実行した検査（単体テスト・`just eval`）と結果、独立レビューと指摘対応、PR・merge commit、同期結果、受け入れの範囲、未実施事項を記録する。詳細な実機の証拠は [検証記録](verification.md) へリンクする。
- **Issue・Report・Status にも、発話・画面の内容・個人の情報を書かない**（[AGENTS.md](../AGENTS.md#安全とプライバシーこの製品の不変条件)）。

## Git・GitHub・GitButler

リポジトリは GitHub の公開リポジトリ（`takemo101/voice-control`）。基本のブランチは **`main`**。**GitButler で進める**：`main` を target（`origin/main`）にし、作業ツリーは `gitbutler/workspace` ブランチ（`but setup`）。

- **Git の書込みは `but`**。raw Git の `add`・`commit`・`checkout`・`merge`・`rebase`・`push` で書き込まない（読取りは可）。変更は、専用の branch に `but commit -b <branch> -m <message> <ids…>`。`main` へ直接 commit しない。
- 変更の確認：`but diff`（未コミットの差分と ID）、`but status`（branch・commit の概観）。ID は、直前の出力からそのまま写す。
- 同期：`but pull`（target の更新を、workspace に取り込む）。先に確認したいときは `but pull --check`。
- **PR を merge したら、毎回、すぐに同期する**：`but pull` → `but status`（base が merge 後の `main`、統合された branch が消えている）。`but pull --check` で、先に衝突の有無を見てもよい。衝突した commit は、`but resolve` で、古いものから直す。同期が済むまで、次の作業・PR を始めない。
- PR：`but pr new <branch> -F <message-file>`（push を含む）。PR を依頼されたときだけ作る。PR の target・head・差分を確かめてから、`main` へ normal merge する。admin・force・保護の迂回・`but land` による PR 回避をしない。
- push・公開・リリース・認証は、利用者の依頼があるときだけ。**秘密・個人の情報（トークン・API キー・実際の発話・画面の内容・個人のパス）をコミットしない**（コミットの前に確かめる）。
- コミットの作者は、リポジトリの設定（`user.name`・`user.email`）のまま。
- `but unapply <branch>` は、その stack のファイルを作業ツリーから外す（commit は残る）。唯一の stack を unapply すると、ソースが消えたように見える。

コミットの粒度：利用者に見える一つの変更（実装・必要なテスト・文書）を、まとめて 1 commit。無関係な変更を混ぜない。メッセージは、何を・なぜ変えたかを、1 行目に短く。

## リリース

配布は **GitHub Releases**（バイナリの tar.gz と SHA-256）。タグ `vX.Y.Z` の push で、[release.yml](../.github/workflows/release.yml) が、macOS 26 のランナー（Xcode 26）でビルドして、Release に添付する。リリースは、**利用者の依頼があるときだけ**行う。

配布物：`vc-<版>-macos-arm64.tar.gz`（中身：`vc`・`LICENSE`・`README.md`・`skills/voice-control-skill-author/`）と、`.sha256`。**Tiny-Jev のモデルは含めない**（ライセンスの条件が未確認。利用者が `vc model download` で取得する）。署名は ad-hoc（Developer ID の署名・公証は、利用者の判断で、secrets と手順を決めてから）。

**利用者向けの入れ方**：リポジトリ直下の [install.sh](../install.sh)（`curl -fsSL https://raw.githubusercontent.com/takemo101/voice-control/main/install.sh | bash`）。最新の Release（`/releases/latest` の転送先のタグ）の tar.gz と `.sha256` を取得して照合し、取り出した `vc` を実行して版を確かめ（通らなければ、いまの `vc` を置き換えない）、`~/.local/bin` へ置き、`vc model download` を実行する。https だけで取得する。`--no-model`・`--version <版>`・`--bin-dir <場所>`。変更したら、**Release を作ったあとの版で**、一時の `--bin-dir` に入れて確かめる（`VC_RELEASE_BASE_URL` で取得元を差し替えて、SHA-256 の不一致も試せる）。`main` の install.sh が、最新の Release を入れるので、Release の tar.gz の構成（`vc-<版>-macos-arm64/vc`）を変えるときは、一緒に直す。

**手順**

1. `Sources/vc/Version.swift` の版を、新しい版へ上げて、PR で `main` に入れる。`but pull` で同期する（[PR の merge 後の同期](#gitgithubgitbutler)）。
2. `main` の commit にタグを付けて、push する：`git tag vX.Y.Z <mainのcommit> && git push origin vX.Y.Z`（タグは、`main` が `origin/main` と同期している状態で付ける）。
3. ワークフローは、タグの push のとき、**タグの commit が `main` に含まれること**を最初に確かめ、単体テスト → ビルドと tar.gz・`.sha256` の作成（`scripts/package.sh`）→ **ビルドした `vc --version` がタグと一致すること** → 検査（`verify-package.sh`）→ アップロード、と進む。別のジョブが、`.sha256` を照合してから、Release を作る。どれかが失敗したら、Release は作らない。
4. 変更点は、Release の自動生成の説明（`--generate-notes`）。必要なもの・インストール手順・Gatekeeper の回避・注意の定型文が、その前に付く。

**確認**

- Release を作らない確認：Pull Request（リリースに関わるファイルを変えたとき）または Actions タブ → release → Run workflow。tar.gz をアーティファクトに残し、ダウンロードして SHA-256 を照合するところまで確かめる。
- ローカルで同じ配布物を作る：`just package`（`dist/` に tar.gz と `.sha256`。作ったものを `verify-package.sh` で検査する）。
- 検査の内容：SHA-256・中身・arm64・署名（`codesign --verify --strict`。署名は ad-hoc）・OS 標準以外のライブラリに依存していないこと・`vc --version`・`vc --help`・`vc run --help`・モデルなしで動く `vc skills`・`vc model status`・`vc hotkey set`（と、`vc hotkey` が設定を返すこと）。
- **ワークフローの実行環境（macOS 26）には、Apple Intelligence も Tiny-Jev のモデルもない**。そこで確認できるのは、ビルド・単体テスト・モデルを使わないコマンドまで。`vc run`・`just eval` は、人間が実機で確かめる（[検証手順と記録](verification.md)）。
- **macOS ランナーの容量の都合で、ジョブが始まらないことがある**：ステップが 1 つも始まらずに `cancelled` になり、注記に `The job was not acquired by Runner of type hosted even after multiple attempts`（と、macOS arm64 のランナーは、容量の制約で待ちが長くなることがある、という知らせ）が出る（2026-11-03 の `workflow_dispatch` の 1 件で確認）。コードの失敗ではなく、インフラの都合なので、Actions タブ → release → Run workflow で、もう一度起動する。ステップが失敗している（`Unit tests` など）場合は、別の問題として、ログを読む。
