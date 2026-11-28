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

macOS 26 以降・Apple silicon・Swift 6.2 以降（Xcode または Command Line Tools）。外部の Swift パッケージは、Mermaid の図の BeautifulMermaid と elk-swift だけ（初回のビルドで取得する。版は固定）。音声認識の transcribe.cpp〔C++〕は、`scripts/build-native.sh` が、固定した commit を静的ライブラリにビルドする。`just build`・`just test`・`./scripts/test.sh`・`./scripts/package.sh` が、先に呼ぶ。ビルド済みなら何もしない。初回は、git・Command Line Tools・cmake が要る〔cmake が無ければ、`build/native/venv` に pip で入れる〕。数分かかる。`swift build` を直接呼ぶなら、先に `./scripts/build-native.sh`）。実行時の外部ツール：任意で、ローカルのモデルのサーバー（`--engine` を使うとき。Ollama：`ollama pull <モデル>`。LM Studio・llama.cpp など）、[agent-desktop](https://github.com/vercel-labs/agent-desktop)（`npm install -g agent-desktop`。`agent-desktop permissions` で、アクセシビリティの許可を確認）、[just](https://github.com/casey/just)（任意。なければ `scripts/` を直接実行）。

## ビルドと実行

`just` で入口を一覧できる（[justfile](../justfile)）。

| レシピ | 内容 |
|---|---|
| `just build` | リリースビルド（`.build/release/vc`・`Fixture`）。Command Line Tools だけの環境で出る、リンカの `search path … not found` の警告（無害）は、表示しない |
| `just test` | 単体テスト（Swift Testing）。画面・音声・モデルは使わない |
| `just app` | `build/VoiceControl.app`（メニューバーのアプリ。ad-hoc 署名。指定要件は bundle ID だけ）を作る。アプリの中の `Contents/MacOS/vc` は、CLI の `vc` と同じ実行ファイル（引数なし＝アプリ・引数あり＝CLI。`AppLaunch`） |
| `just dmg` | `dist/vc-<版>-macos-arm64.dmg` と SHA-256 を作り、`scripts/verify-dmg.sh` で検査する（dmg の整合・中身・Info.plist・arm64・OS 標準のライブラリだけ・署名の整合と指定要件・`--version`・`vc show --help`） |
| `just install` | `just app` で作ったアプリを `~/Applications` へ入れて起動する（`INSTALL_DIR` で場所・`NO_OPEN=1` で起動なし・`RESET_PERMISSIONS=1` で許可を取り消してから）。コマンド `vc` は `~/.local/bin` へリンク（`BIN_DIR`）。リポジトリの `models/tiny-jev-0.6b`（開発用。`tokenizer.json` と `model.safetensors` がある）があれば、`~/.voice-control/models/tiny-jev-0.6b` へリンク（複製しない） |
| `just uninstall` | アプリ・コマンド `vc` のリンク・モデルのリンクを取り除く（既定の場所なら、許可も取り消す）。モデルの本体・スキル・設定には触れない |
| `just reset-permissions` | このアプリの許可（マイク・アクセシビリティ・画面収録）を取り消す（設定ではオンなのに「許可されていません」と出るとき） |
| `vc eval-plan corpus/plan.tsv --set dev\|test` | 依頼を複数のステップに分ける判断（言語モデル）と、各ステップのスキルの選び方の当たり率。dev は調整用・test は最後に 1 回（Tiny-Jev のモデルと、言語モデルが要る。実行はしない） |
| `scripts/eval-skills.py [--engine apple\|ollama:<モデル>] [--rounds N] [--skill <名前>]` | **全スキルを、言語モデルで動かし、依頼から、正しいコマンドが出るか**を数える（`corpus/skills.tsv`。`--dry-run`：実行しない。一時の `VC_HOME` で、利用者の設定・クリップボードには触れない。Tiny-Jev は使わず、スキルを指定する）。スキルの本文・実行者を変えたら、これで、エンジンごとに測る |
| `just eval` | 「操作の依頼か」の判定（当てはまるスキルがないとき、既定スキルに回すか）の当たり率（`vc eval-gate corpus/gate.tsv`。Tiny-Jev のモデルが要る。実機は操作しない） |
| `vc tidy` / `vc eval-tidy corpus/tidy.tsv [--set dev\|test]` | 整理モード（F79）の、1 文の確認と、当たり率（タグ・数字・否定・長さの検査を通るか）。言語モデルは、設定のスキルを実行するモデル（Apple 以外を使うときは、`--engine`）。Apple で測るときは、空の `VC_HOME` に `{"engine":"apple"}` |
| `vc summary <会議の.txt> [--focus <テーマ>]` / `vc eval-summary corpus/summary` | 会議の要約（F82）の、1 件の確認と、作り物の会議 5 件での当たり率（`# expect:` の条件）。長い会議の分け方・テーマの絞り込みも通る |
| `vc capture-probe` | 画面収録の許可・取り込める音・音量を、短く確かめる（実機。許可が要る。自分で鳴らした音で試す） |
| `vc transcript-preview [--say <文>] [--seconds N] [--demo [--summary]]` | 会議の文字起こしの画面を、実際の経路（ショートカットと同じ）で動かす。`--demo` は、作り物の文を並べて、見た目だけを見る（取り込まない）。`--say` は、`say` で自分の音を鳴らす |
| `vc eval-route corpus/hybrid.tsv` | 発話を、スキルで実行するか・会話で答えるかに、振り分けられるかの当たり率（会話とスキルを混ぜる機能の土台の測定。`just` には入れていない。取っておいた文 `corpus/hybrid-test.tsv` は、調整に使わない。Tiny-Jev のモデルが要る。実行はしない） |
| `just fixture [--ja\|--many N\|--dup]` | 検証用の自作ウィンドウを起動（`just fixture-stop` で終了） |
| `just vc <args>` | ビルドして `vc` を呼ぶ |

- ターゲットは `VCCore`・`VCDecision`・`VCSpeech`・`VCSkill`（ライブラリ）と、`vc`・`Fixture`（実行ファイル）、テスト専用の `TestSupport`。依存の向き（下向きだけ）は `Package.swift` で宣言し、コンパイラが強制する。宣言にない `import` を差分ビルドでも失敗させるには、`--explicit-target-dependency-import-check=error` を付ける（上の入口は付けている。素の `swift build` は、警告だけのことがある）。テストもターゲットごと（`Tests/VCCoreTests` など。`@testable import` で、対応するターゲットの `internal` を使う。実行ファイルの `vc` も、`Tests/vcTests` が `@testable import vc` で、引数の読み方とコマンドの一覧を試す）。1 つのターゲットだけを試すには `./scripts/test.sh --filter VCSkillTests`。
- テストは `./scripts/test.sh`。Command Line Tools だけの環境では、Swift Testing のマクロのプラグインのパスを、明示して渡す必要があり、素の `swift test` は失敗する。
- **環境変数 `CI` が付いていると、実機でしか動かないテスト（Vision の文字認識・背景除去・HEIC・翻訳）は、飛ばされる**（`RunEnvironment.isCI`：CI の VM には、GPU・Neural Engine・言語パックがない）。作業用のシェルに `CI` が付いている場合は、`env -u CI ./scripts/test.sh` で、飛ばさずに実行する（飛ばしたものは、「全通過」に、数えない）。
- テストの置き場所：**ターゲットごと**（`Tests/<ターゲット>Tests/`。`vc` は `Tests/vcTests`）、**責務別**（1 ファイル 1 領域で、ファイル名はスイート名：`ChooserTests.swift`・`SettingsTests.swift`・`CommandPolicyTests.swift` など。目安は 250 行以下で、超えるなら領域で分ける）。**偽の実装は別のファイル（そのスイートでしか使わない数行の偽物は、スイートの中でよい）**（`VoiceLoopFakes.swift`・`SkillRunnerFakes.swift` のように、使うスイートの名前を付ける）。複数のターゲットで使う偽物は、**`Tests/TestSupport/`**（テスト専用の `.target`。`OptionScorer` の偽物＝`TargetScorer`・`OptionSpy`・`SkillScorer`、集める道具＝`Collected`・`plain`）に、用途ごとに 1 つずつ置く。作りは次のとおり：公開 API だけを使う（`@testable` が要る偽物、たとえば `SkillExecuting` の偽の実行者は、そのテストターゲットに残す）／インスタンスで状態を持ち、グローバルの状態は持たない（CI は、全ターゲットのテストを 1 つのプロセスで並行に動かすため）／依存するのはテストターゲットだけ。本番のターゲットは `TestSupport` に依存せず、参照もしない。素の `swift build` は `TestSupport` もビルドするが、`vc` には入らない（`scripts/package.sh` は `--product vc`）。
- **CI の SDK（Xcode 26）は、手元の SDK より古いことがある**：手元で、非推奨の警告を直した書き方（`GenerationOptions(samplingMode:)`）が、CI では、ビルドエラーになった（v0.3.12 のとき）。**API の呼び方を、警告のために変えたら、PR の CI の結果を見るまで、マージしない**（両方の SDK で通る書き方を選ぶ）。
- **CI は、全ターゲットのテストを 1 つのプロセスで並行に動かす**（`release.yml` の `swift test --explicit-target-dependency-import-check=error`。2026-11-03 の CI のログで `Test run with 186 tests in 41 suites` が 1 回）。ローカル（Swift 6.4）の `just test` は、ターゲットごとに別の実行として出る（`Test run with …` が 6 回。41・28・47・46・8・16 件で、合計 186 件・41 スイート。2026-11-04 に確認。PC 操作の廃止のあとは 5 回：34・28・47・9・16 件で、合計 134 件・25 スイート。理由は、調べていない）。並列度が違うので、全体の並行の下では、テストの時間・スレッドが競合して、失敗することがある：実際に、`ProcessRunner` のテストが、CI で、出力が終わらず時間の上限に達して失敗した（原因は、共有のスレッドの枯渇と**推定**。直接の証拠は未取得。[構成説明](architecture.md#時間と並行)）。CI の結果も、確かめる。
- CI のツールチェーンは、ローカルと違うことがある：この記録の時点で、ローカルは Swift 6.4（macOS 27）、CI は Xcode 26.6・Swift 6.3.3（macOS 26.6.2。2026-11-03 の CI のログ）。CI のログに、警告が出たことがある（`SaySpeaker` の `nonisolated(unsafe)` が不要・`SkillRunnerTests` の `NSLock` を async の文脈で使っている、の 2 種。直したあとの CI のログは、警告 0）。変更のあとは、CI のログの `warning:` も見る。
- `Fixture` は `nohup` で起動する。サブシェルの `( … &)` で起動すると、agent-desktop が TIMEOUT する（実測）。`just fixture` は、そうしている。
- **ACP アダプターの版を上げる**：`scripts/update-adapters.sh claude|codex [版]`（`adapters/<名前>/` の `package.json`・`package-lock.json` を作り直す）→ `Sources/VCSkill/Chat/ACP/ACPAdapter.swift` の `version` を同じ版に（テストが、一致と、lock の検査〔npm の公式・SHA-512・固定〕を照らす）→ 実際のエージェントで `vc chat-check`（確認のパネル・許可／断る）→ PR。`just app` は、固定ファイルを、アプリに同梱する（`scripts/verify-dmg.sh` が確かめる）。入れる動作の確認：`VC_HOME=/tmp/x vc adapter install claude`。
- **更新の確認（`vc update`）**：`vc update` は、GitHub の最新の Release と、いまの版を比べる。`VC_UPDATE_CURRENT=0.5.6 vc update --download-only /tmp/update-check --app build/VoiceControl.app` は、新しい版を取得して、SHA-256・ディスクイメージ・署名・指定要件まで確かめる（**いまのアプリは、入れ替えない**）。実際の入れ替えは、メニューバーのアプリ（「アプリケーション」の中）だけが行う。**Release の添付の名前（`vc-<版>-macos-arm64.dmg` と `.sha256`）と、`Version.swift` の版・タグ `vX.Y.Z` の関係は、変えない**（アプリが、この名前で探し、取得した版が、タグと同じことを確かめる）。
- **小さい画面の配置を、大きい画面で確かめる**：環境変数 `VC_VISIBLE_SIZE=幅x高さ`（例：`1100x640`）を付けて動かすと、画面の使える領域が、その大きさ（上の中央）になったものとして、パネル・ウィンドウが出る（`vc chat-check`・`vc show`・`vc hud-preview` など。開発用。不正な値は無視）。シェルには、残さない。
- 検証中に、環境変数（`VC_HOME`・`BIN_DIR`・`MODEL_LINK`）を、シェルに残さない。残ったまま `just install` を実行すると、意図しない場所に入る（実際に起きた）。
- モデルの取得は 設定ウィンドウ > モデル（`~/.voice-control/models/tiny-jev-0.6b`。版を固定・SHA-256 の検証・再開）。確認は 設定ウィンドウ > モデル。
- モデルの探し方：`--model`、`VC_MODEL_DIR`、`~/.voice-control/models/tiny-jev-0.6b`、`./models/tiny-jev-0.6b`（開発用）の順。

## コマンドの足し方

`vc <name>` を足すには、次を、同じ変更で行う（構造は [構成説明](architecture.md#vc-のコマンドの構造)）。

1. `Sources/vc/Commands/<Name>.swift` に、`Command` を実装した型を置く：`static let info`（名前・グループ・使い方・説明・オプション・例。`vc --help`・`vc <name> --help` は、ここから作られる）と、`run(_ arguments: Arguments, _ context: CommandContext)`。`run` の中では、自分のオプションを `var arguments = arguments` に写して `option`・`flag` で取り除き、位置引数は `arguments.positionals`（コマンド名を除く）、共通のオプション（`--model`・`--floor`・`--yes` など）は `context.options`、モデルは `context.loadJev()`、設定は `context.currentSettings()`、スキルは `context.loadSkills()` から使う。失敗は `fail`（終了コード 1）、使い方の誤りは `usageError`（2）。Tiny-Jev のモデルを読むコマンドは、`Help.modelUsers` に名前を足す（共通のオプションを案内する）。
2. `Commands.all`（`Sources/vc/Command.swift`）に、型を足す。**この並びが、`vc --help` の表示順**（グループの中）になる。
   - モデルを使うコマンドなら、`Help.modelUsers`（`Sources/vc/Help.swift`）に名前を足す（`vc <name> --help` に、共通のオプションが出る）。
3. テストを足す：引数の読み方に関わるなら `Tests/vcTests/ArgumentsTests.swift`（共通のオプションは `CommonOptionsTests.swift`）。コマンドの一覧とヘルプは `CommandRegistryTests.swift` が確かめる（名前の重複・グループごとの表示）。スキルの実行の流れ（判断）は `Tests/VCSkillTests/SkillRunnerTests.swift`、その出来事の表示（`TerminalReporter`・`HUDReporter`）は `Tests/vcTests/TerminalReporterTests.swift`・`HUDReporterTests.swift`。声の流れ（声の入力（メニューバーのアプリ） の調整：Esc・待ち行列・録音）は `Tests/VCSpeechTests/VoiceLoopTests.swift`（録音・文字起こし・トリガー・Esc の偽物は `VoiceLoopFakes.swift`。マイク・音声認識は使わない）。出力は、変更の前後の `vc` を、`NO_COLOR=1`・一時の `VC_HOME` で動かして、比べる。

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

リポジトリは GitHub の公開リポジトリ（`takemo101/voice-control`）。基本のブランチは **`main`**。**GitButler で進める**：`main` を target（`origin/main`）にする。**作業ツリー（HEAD）は、適用中のブランチの数で変わる**（GitButler 0.23 以降。`but setup` は不要）：0 個なら `main`・1 個ならそのブランチ・**2 個以上を並行して適用したときだけ**、GitButler が管理する `gitbutler/workspace`（複数のブランチをまとめた merge commit）に切り替わる。全部消す・統合すると、通常のブランチに戻り、`gitbutler/workspace` の ref は、GitButler が消す。この `gitbutler/workspace` は、**手で動かさない**（古く見えても、使われていない：`but pull` は、適用中のブランチがなければ「Up to date」と言うだけで、動かさない）。

- **Git の書込みは `but`**。raw Git の `add`・`commit`・`checkout`・`merge`・`rebase`・`push` で書き込まない（読取りは可）。変更は、専用の branch に `but commit -b <branch> -m <message> <ids…>`。`main` へ直接 commit しない。
- 変更の確認：`but diff`（未コミットの差分と ID）、`but status`（branch・commit の概観）。ID は、直前の出力からそのまま写す。
- 同期：`but pull`（target の更新を、適用中のブランチに取り込む）。先に確認したいときは `but pull --check`。
- **PR を merge したら、毎回、すぐに同期する**：`but pull` → `but status`（base が merge 後の `main`、統合された branch が消えている。HEAD は `main`、または適用中のブランチ）。`but pull --check` で、先に衝突の有無を見てもよい。衝突した commit は、`but resolve` で、古いものから直す。同期が済むまで、次の作業・PR を始めない。
- **積んだ PR（スタック）**：下の PR を base にした PR は、`gh pr merge` が「stack の一部なので、非同期の merge API で」と断る。`gh api -X PUT repos/<owner>/<repo>/pulls/<上の PR>/merge-async -f merge_method=merge -f sha=<CI を通した head>`（下の PR も、まとめて入る）。結果は、返った uuid を `GET …/merge-async/<uuid>` で見る。
- PR：`but pr new <branch> -F <message-file>`（push を含む）。PR を依頼されたときだけ作る。PR の target・head・差分を確かめてから、`main` へ normal merge する。admin・force・保護の迂回・`but land` による PR 回避をしない。
- push・公開・リリース・認証は、利用者の依頼があるときだけ。**秘密・個人の情報（トークン・API キー・実際の発話・画面の内容・個人のパス）をコミットしない**（コミットの前に確かめる）。
- コミットの作者は、リポジトリの設定（`user.name`・`user.email`）のまま。
- `but unapply <branch>` は、その stack のファイルを作業ツリーから外す（commit は残る）。唯一の stack を unapply すると、ソースが消えたように見える。

コミットの粒度：利用者に見える一つの変更（実装・必要なテスト・文書）を、まとめて 1 commit。無関係な変更を混ぜない。メッセージは、何を・なぜ変えたかを、1 行目に短く。

## 画面の文字を足す・直す（多言語）

設定ウィンドウとダイアログの文字は、`tr("日本語の文")` で書く。**足したら、`Sources/vc/L10n/en/English*.swift` に、英語の訳を、1 行（`"日本語の文": "English",`）足す**（英語は、**すべての言語の引き先**：英語が抜けると、`just l10n` が、問題にする。ほかの言語の訳は、足さなくてよい：その文は、英語で出る）（鍵は、`tr` の文と、同じ形。補間は `%@`）。`just l10n`（= `python3 scripts/check-l10n.py --uncovered`）が、抜け・重複・置き換えの数の違い・包まれていない日本語の文字列を、見つける（CI も、同じ）。英語の画面は、`settings.json` に `"uiLanguage": "en"` を書いた `VC_HOME` で、`vc settings-preview <フォルダ>`。ダイアログ（`NSAlert`）は、画面の外では描けない：アプリで開いて確かめる。日本語のままにする文字列には、行の終わりに `// l10n-skip`。

### 言語を足す

**言語ごとに、足すもの**は、次の 4 つだけ（足りないところは、コンパイルと `just l10n` が、教える）。日本語は、鍵そのもの（表は、要らない）。英語は、すべての言語の**引き先**（その言語の表にない文は、英語で出る）。

1. **`AppLanguage` に case を足す**（`Sources/VCCore/L10n.swift`。符号は、`fr` のような 2 文字）。→ すぐ、`LanguageProfile.swift` の `switch` が、コンパイルできなくなる。
2. **`Sources/VCCore/LanguageProfile.swift` に、その言語のデータを書く**：その言語での名前・`Locale`（`fr-FR`）・Whisper の符号・モデルへの指示に書く名前（`French`）・NaturalLanguage の符号・全角の文字か・声の確認の「はい」の言い方・つなぎ言葉・「会話を終わる」の言い方（ない言語は、空でよい。**「はい」とつなぎ言葉は、1 つ以上**：`LanguageProfileTests` が、確かめる）。**登録した全言語の語を合わせて使う**ので、どの言語で話しても、どの言語の「はい」も通る。
3. **翻訳の表を作って、登録する**：`python3 scripts/check-l10n.py --new-language fr French` が、ひな形（`Sources/vc/L10n/fr/FrenchTables.swift`：**すべての鍵を、空の値で並べ、英語を、コメントに添える**）を作る。値を埋める（**空の値は、未訳**：その文は、英語で出るので、少しずつ、訳してよい）。`Sources/vc/L10n/L10nTables.swift` の `switch` に、`case .fr: return FrenchTables.all` を足す。
4. **許可のダイアログの説明**（Mac の言語に合わせて出る）：`Resources/fr.lproj/InfoPlist.strings`（`Resources/en.lproj/` を写して、訳す）。`scripts/build-app.sh` は、`Resources/*.lproj` を、すべて、アプリへ入れる。`scripts/verify-dmg.sh` が、すべての言語に、説明があるか、検査する。

進み具合の確認：`just l10n`（問題＝英語の抜け・置き換えの数・重複。未訳は、件数だけ）／`python3 scripts/check-l10n.py --status`（言語ごとの訳の割合）／`--missing fr`（未訳の鍵を、英語つきで、一覧）。画面の確認：`VC_HOME` の `settings.json` に `"uiLanguage": "fr"` を書いて、`vc settings-preview <フォルダ> --page general`。

**足したあと、確かめること**：`just test`（言語の登録・表の整合）／設定ウィンドウの言語の選択肢に、その言語が、**その言語の名前で**出る／音声認識の言語（設定 > 音声）の選択肢にも出る（登録した言語が、そのまま選べる）。**注意**：声で頼む機能（スキルの選択・「操作の依頼か」の判定）は、日本語で作って測っている（英語も測った）。**ほかの言語は、測っていない**（`corpus/gate.tsv`・`vc eval-gate` に、その言語の文を足して、測ってから、「対応」と言う）。README の訳（`README.<言語>.md`）は、任意。

**英語の用語**（表の訳を、そろえる）：声で頼む＝Voice command（動詞句は ask by voice）・音声入力＝Dictation・声の入力＝voice input・会話＝Chat・スキル＝skill・トリガー＝trigger key（文中）・手放し＝Hands-free (double-tap)・確認／確かめる（利用者に）＝confirm・実行するモデル＝Model that runs skills（選ぶほう＝Model that picks skills）・取得＝Download（一覧は Load。Web ページは Fetch）・開き直す＝relaunch・外のエージェント＝external agent・ACP を話す＝support ACP・Finder で表示＝Show in Finder・変更点＝What's new・字幕＝live captions。件数は、"1 files" にならない書き方（`item(s)`・`Models: %@`）。引用は、画面では “ ”、端末の出力では " "。

## 製品ページ（`site/`）

利用者向けの説明ページ（インストール方法・使い方・注意点）。素の HTML・CSS・JavaScript（ビルドなし・外部の通信なし・解析なし）で、**GitHub Pages** に公開する（`https://takemo101.github.io/voice-control/`）。

- **構成**：`site/index.html`・`site/assets/`（`tokens.css`＝色・文字・余白の名前つきの値、`styles.css`、`main.js`、`video/`、`img/`）。動画（mp4・webm）と画面の静止画は、**本物の `vc` の画面を、自作の背景の上で撮った**もの（`vc hud-preview` の作り物の内容と、`vc show` のサンプル）。
- **見る**：`python3 -m http.server 8765 --bind 127.0.0.1 -d site` → <http://127.0.0.1:8765/>。
- **設定の画像を作り直す**：`scripts/site/render.sh`（`just build` のあと。ffmpeg が要る）。`vc settings-preview` が、設定のウィンドウを、**画面に出さず**（画面の外で）描くので、**画面収録の許可は、要らない**。見本のホーム（`.voice-control/skills` のスキルだけ）と、仮の `HOME` で描くので、利用者のパス・設定・スキルは、画像に入らない。`docs/images/` と `site/assets/img/` へ書く（`settings-*.png`）。
- **パネル・Markdown のウィンドウ・会話のウィンドウを撮り直す**：`scripts/site/capture.sh all`（**画面収録の許可が要る**。背景が出ていなければ撮らない。約 2 分、画面の上と中央に、自作の背景と、`vc hud-preview`・`vc show`・`vc chat-preview` の表示が出る）→ `scripts/site/encode.sh`（`site/assets/` と `docs/images/` へ。ffmpeg が要る）。撮影のとき、利用者の画面・アプリを、写さない（自作の背景だけ）。`vc` は、`VC=<パス>` で替えられる。
  - **画面収録の許可は、「そのコマンドを動かしているアプリ」に付く**。エージェントが、Tern のように、**ヘルパー（Tern Daemon.app）経由**でシェルを動かすと、責任アプリがヘルパーになり、アプリ本体に許可があっても、`screencapture` は「could not create image from rect」で失敗する（2026-11-15。左上の 8×8 だけを撮って確かめる）。ヘルパーにも許可を付けても、すぐには直らなかった。サービスの再起動（`launchctl kickstart -k gui/$(id -u)/user.tern-remote`）のあと、撮れた（再起動で直ったのか、許可の反映の遅れかは、特定していない）。
  - `screencapture` は、**出力のファイルが既にあると、上書きできずに失敗する**（`capture.sh` は、撮る前に消す）。
- **公開**：`main` に `site/**` が入ると、[pages.yml](../.github/workflows/pages.yml) が公開する。**初めに 1 回だけ**、リポジトリの Settings > Pages > Source を「GitHub Actions」にする（利用者の操作）。
- **リリースのとき**：ページの版（`site/index.html` の `<span>v…</span>`）を、新しい版へ上げる（`Sources/vc/Version.swift` と同じ変更に含める）。
- **守ること**：外部の通信・解析・外部フォントを足さない（製品の約束と合わせる）。動作例の出力は、**本物の `vc run --dry-run`** のもの（作らない）。数値は、測ったものだけ。レスポンシブは、幅 320・375・414・768・1280 で、横にはみ出さないこと。動きは、`prefers-reduced-motion` で止まること。

## リリース

配布は **GitHub Releases**（**dmg** と SHA-256）。タグ `vX.Y.Z` の push で、[release.yml](../.github/workflows/release.yml) が、macOS 26 のランナー（Xcode 26）でビルドして、Release に添付する。リリースは、**利用者の依頼があるときだけ**行う。

配布物：`vc-<版>-macos-arm64.dmg`（中身：`VoiceControl.app`・「アプリケーション」へのリンク）と、`.sha256`。アプリの中に、`vc` の実行ファイル（`Contents/MacOS/vc`）・`LICENSE`・`THIRD_PARTY_NOTICES.md`・`skills/voice-control-skill-author/` が入る。**Tiny-Jev のモデルは含めない**（ライセンスの条件が未確認。利用者が、アプリの設定 > モデル で取得する）。署名は ad-hoc だが、**指定要件を bundle ID だけ**にする（更新で、許可が無効にならないように。meeting-analyzer と同じ。この Mac で、更新後も許可が残ることは未確認）。Developer ID の署名・公証は、利用者の判断で、secrets と手順を決めてから。

**利用者向けの入れ方**：Release の dmg を開き、`VoiceControl.app` を「アプリケーション」へ入れる。ブラウザでダウンロードして Gatekeeper に止められたら、`xattr -dr com.apple.quarantine /Applications/VoiceControl.app`。CLI の `vc` は、アプリの設定 > 一般 の「コマンド vc」で、`/usr/local/bin/vc` へのリンクを張る（以前の tar.gz 版・`install.sh` は、やめた。古い `~/.local/bin/vc` が PATH で先に当たると、古い方が動く）。

**手順**

1. `Sources/vc/Version.swift` の版を、新しい版へ上げて、PR で `main` に入れる。`but pull` で同期する（[PR の merge 後の同期](#gitgithubgitbutler)）。
2. `main` の commit にタグを付けて、push する：`git tag vX.Y.Z <mainのcommit> && git push origin vX.Y.Z`（タグは、`main` が `origin/main` と同期している状態で付ける）。
3. ワークフローは、タグの push のとき、**タグの commit が `main` に含まれること**を最初に確かめ、単体テスト → ビルドと dmg・`.sha256` の作成（`scripts/dmg.sh`：`scripts/build-app.sh` で `.app` を作る）→ **ビルドした `vc --version` がタグと一致すること** → 検査（`verify-dmg.sh`）→ アップロード、と進む。別のジョブが、`.sha256` を照合してから、Release を作る。
4. 変更点は、Release の自動生成の説明（`--generate-notes`）。必要なもの・インストール手順・Gatekeeper の回避・注意の定型文が、その前に付く。

**確認**

- Release を作らない確認：Pull Request（リリースに関わるファイルを変えたとき）または Actions タブ → release → Run workflow。dmg をアーティファクトに残し、ダウンロードして SHA-256 を照合するところまで確かめる。
- ローカルで同じ配布物を作る：`just dmg`（`dist/` に dmg と `.sha256`。作ったものを `verify-dmg.sh` で検査する）。
- 検査の内容：dmg の整合・中身・Info.plist（使用目的の説明・`LSUIElement`）・版・arm64・OS 標準以外のライブラリに依存していないこと・署名（`codesign --verify --deep --strict`・指定要件が bundle ID だけ）・アプリの中の `vc --version` と `vc show --help`。
- **ワークフローの実行環境（macOS 26）には、Apple Intelligence も Tiny-Jev のモデルもない**。そこで確認できるのは、ビルド・単体テスト・モデルを使わないコマンドまで。アプリの起動・許可・`vc run`・`just eval` は、人間が実機で確かめる（[検証手順と記録](verification.md)）。
