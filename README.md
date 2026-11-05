# voice-control（試作）

Mac を、依頼文や声で操作する試作。**依頼に合うスキルを Tiny-Jev（オンデバイスの小さな選択モデル）が選び、言語モデルが、スキルの指示に従って、コマンドを実行する。** 実行するコマンドは、スキルが許可したものだけで、すべて画面に表示される。音声・画面の内容・依頼文は、この Mac の外へ出さない。

いまは CLI（`vc`）。どの使い道が成り立つかを、測定で確かめる段階で、完成した製品ではない。

## できること

- **スキルで動く**：`~/.voice-control/skills/<name>/SKILL.md` に、説明・許可するコマンド・指示を書く。声や文で頼むと、合うスキルが選ばれて実行される（`vc run`・`vc listen`）。
- **声で頼む**：Shift の長押し（変更できる）の間だけ録音し、離すと、文字にして実行する（`vc listen --hotkey`）。確認が要るときは、声の「はい」か、パネルの「実行する」「やめる」ボタンで答える。Esc で取りやめ。
- **コピーした文章を加工する**：文章を ⌘C でコピーして、「コピーした文章を整理して」「要約して」「英語に翻訳して」。結果は、きれいに整形した Markdown のウィンドウに出て、そのままコピーできる（`clipboard-note`・`vc show`）。
- **モデルを替えられる**：既定は Apple のオンデバイスのモデル。複雑な指示は、この Mac の Ollama・LM Studio などのモデルに替えられる（`--engine`。任意）。

`echo` だけを許可した使い捨てのスキルでの、実際の出力（返事の文言・秒数は、実行のたびに変わる。表示の詳細は [スキル](docs/skills.md#画面の表示)）：

```text
$ vc run テスト
model loaded 4.3s (length 1024)

▶ スキルの選択
  Tiny-Jev  echo-test   98.6%（0.1 秒）
  説明      テストを実行する
  許可      echo

▶ 実行
  $ echo test
    ✓ exit 0
    │ test
    │ 

▶ 結果
  返事      done: テストされました。
  所要      1.1 秒・実行したコマンド 1 件
```

## 状況

| 機能 | 状態 |
|---|---|
| スキル（`vc skills`・`vc run`） | 自作ウィンドウで確認。**実アプリ・複数スキルの取り違えは未確認** |
| 声の入力（`vc listen`） | 実装済み（ホットキー・Esc・確認のボタン）。**マイクの実録音・ボタンでの確認は未確認** |
| Markdown のウィンドウ（`vc show`・`clipboard-note`） | 実装済み（見た目は自作の内容で確認）。**コピーのボタン・⌘C の実機の操作は未確認** |
| `--engine`（Ollama・OpenAI 互換） | Ollama（`qwen3.5:4b`）で確認。**LM Studio・llama.cpp など、ほかのサーバーは未確認** |

PC 操作は、2026-11-04 に廃止し、既定スキルに一本化した。詳細な要件と状態は [SPEC](SPEC.md)、測定と未確認は [検証手順と記録](docs/verification.md)。

## 必要なもの

- macOS 26 以降・Apple silicon。ソースからビルドするときは、Swift 6.2 以降（Xcode または Command Line Tools）。
- [agent-desktop](https://github.com/vercel-labs/agent-desktop)（`npm install -g agent-desktop`）。アクセシビリティの許可が要る（`agent-desktop permissions`）。
- Apple Intelligence（FoundationModels）が使える Mac。**オンにしておく**：システム設定 > Apple Intelligence と Siri（オンにすると、言語モデルのダウンロードが始まる）。オフ・準備中・非対応のとき、`vc run`・`vc listen` は、理由と手順を示して終わる。
- Tiny-Jev 0.6B のモデル（約 1.2 GB。`vc model download` で `~/.voice-control/models/` に取得）。
- 任意：[just](https://github.com/casey/just)（開発用）・Ollama などのローカルのモデルのサーバー（`--engine` を使うとき）。

## インストール

**コマンド 1 つで入れる**（最新の [Release](https://github.com/takemo101/voice-control/releases)。ビルドは要りません）：

```sh
curl -fsSL https://raw.githubusercontent.com/takemo101/voice-control/main/install.sh | bash
```

Release の tar.gz を取得して SHA-256 を照合し、`vc` を `~/.local/bin` へ置き、Tiny-Jev のモデルを取得し、`vc doctor` で環境を確かめる（[install.sh](install.sh)。中身は短いので、実行前に読める）。設定・スキル・許可には触れない。

- オプション：`--no-model`（モデルを取得しない）・`--version <版>`・`--bin-dir <場所>`。例：`curl -fsSL …/install.sh | bash -s -- --no-model`
- `~/.local/bin` が PATH にないときは、そう知らせる。

<details>
<summary>手で入れる／ソースから入れる／取り除く</summary>

**手で入れる**（[v0.2.2](https://github.com/takemo101/voice-control/releases/tag/v0.2.2) の例）：

```sh
V=0.2.2
curl -fsSLO https://github.com/takemo101/voice-control/releases/download/v$V/vc-$V-macos-arm64.tar.gz
curl -fsSLO https://github.com/takemo101/voice-control/releases/download/v$V/vc-$V-macos-arm64.tar.gz.sha256
shasum -a 256 -c vc-$V-macos-arm64.tar.gz.sha256      # SHA-256 を照合
tar -xzf vc-$V-macos-arm64.tar.gz
mkdir -p ~/.local/bin && install -m 755 vc-$V-macos-arm64/vc ~/.local/bin/vc   # ~/.local/bin を PATH に入れておく
vc model download     # Tiny-Jev を取得（SHA-256 を検証。途中からの再開ができる）
vc --help
```

署名は ad-hoc（Developer ID の署名・公証なし）。ブラウザでダウンロードして Gatekeeper に止められたら、`xattr -dr com.apple.quarantine ~/.local/bin/vc`。上の `curl` なら、止められない。

**ソースから入れる**（リポジトリを clone して。Swift 6.2 以降が要る）：

```sh
just install          # vc を ~/.local/bin へ入れる
vc model download
just test             # 単体テスト
```

配布物の作り方：[開発手順](docs/development.md#リリース)。

**取り除く**：`rm ~/.local/bin/vc`（モデル・設定・スキルは `~/.voice-control` に残る）。

</details>

## 使いはじめ

```sh
vc doctor                                   # 動かすのに必要なものが、そろっているか
vc skills install spotify clipboard-note    # GitHub から、スキルを入れる（名前なしで、一覧）
vc skills                                   # 入っているスキル
vc run "次の曲にして" --dry-run              # 何を実行しようとするかだけ見る
vc run "次の曲にして"                        # 実行
vc listen --hotkey                          # 声で頼む（Shift を押している間だけ録音）
```

**コピーした文章を加工する**：文章を ⌘C でコピーしてから、`vc listen --hotkey` で「コピーした文章を整理して」（`vc run "コピーした文章を要約して"` でも）。「整理して」「書き直して」「要約して」「箇条書きにして」「解説して」「英語に翻訳して」が、安定している。

**自分でスキルを書く**：

```sh
mkdir -p ~/.voice-control/skills/open-app
cat > ~/.voice-control/skills/open-app/SKILL.md <<'EOF'
---
name: open-app
description: アプリを開く・起動する・前面に出す
allowed-commands:
  - open
---
Open the application the user named. Run: open -a "<App name>". Then reply done.
EOF

vc skills                                    # [有効] open-app  アプリを開く・起動する・前面に出す
vc run "Safariを開いて" --dry-run
vc skills disable open-app                   # 選択肢から外す（enable で戻す）
```

書き方・`allowed-commands` の仕様・表示は [スキル](docs/skills.md)。スキルをエージェントに作らせるときは、[スキルを作るスキル](skills/voice-control-skill-author/SKILL.md)。

## コマンド

ヘルプ：`vc --help`（一覧・共通のオプション・環境変数）、`vc <コマンド> --help`（使い方・オプション・例）。出力は、端末なら色つき（`NO_COLOR=1` で無効）。

**実行する**

| コマンド | 内容 |
|---|---|
| `vc run "<依頼>" [--skill <name>] [--dry-run] [--yes]` | スキルを選び、実行する |
| `vc listen [--hotkey] [--trigger <キー>] [--dry-run] [--yes]` | マイクから聞いて、スキルで実行する（既定：Enter で録音。`--hotkey`：押している間だけ録音。[声の入力](docs/skills.md#声の入力vc-listen)） |
| `vc show [--file <パス>] [--text <Markdown>] [--title <題名>] [--wait]` | Markdown を整形して、一時的なウィンドウに表示する（`pbpaste \| vc show`）。選択して ⌘C・コピーのボタン・Esc で閉じる |

`vc run`・`vc listen`・`vc doctor` の共通：`--engine <エンジン>`（スキルを実行するモデル。下の「モデルを替える」）。

**スキルを管理する**

| コマンド | 内容 |
|---|---|
| `vc skills [list]` | スキルの一覧（name・置き場所・description・有効／無効） |
| `vc skills show <name>` | 許可するコマンド・確認の要否・置き場所・場所 |
| `vc skills enable <name>` / `disable <name>` | Tiny-Jev の選択肢にするか（既定は有効） |
| `vc find [--name …] [--in …] [--ext …] [--since …]` | ファイルを探す（Spotlight。読み取りだけ）。スキル `file-search` が、`vc pick` と組み合わせて、探して開く |
| `vc pick --query … --option …` | 短い候補の中から、依頼に合うものを、Tiny-Jev で選ぶ（確信できたときだけ選ぶ。標準入力の行も可） |
| `vc skills install [<name>…] [--force] [--ref <版>]` | GitHub のスキル（`takemo101/voice-control`）を、グローバル（`~/.voice-control/skills`）へ入れる（名前なしは一覧）。リポジトリは、手元になくてよい |
| `vc skills trust` / `untrust` | このプロジェクト（`vc` を起動した場所）の `.voice-control/skills` を、読み込んでよいか |

**設定・診断**

| コマンド | 内容 |
|---|---|
| `vc doctor [--engine …]` | 動かすのに必要なもの（Apple Intelligence・Tiny-Jev・agent-desktop・許可・設定ファイル）が、そろっているかを確かめ、使えないものは直す手順を示す（必須が使えなければ、終了コード 1） |
| `vc model [status\|download\|path]` | Tiny-Jev のモデルの確認・取得（`~/.voice-control/models`） |
| `vc hotkey [show\|set <キー>\|reset]` | 押している間だけ聞くトリガーの確認・変更（既定：Shift の長押し。例：`vc hotkey set ctrl+opt+space`） |

## 仕組みのメモ

- **スキルの置き場所**：グローバル（`~/.voice-control/skills/<name>/SKILL.md`）と、プロジェクト（`<vc を起動した場所>/.voice-control/skills/<name>/SKILL.md`）。同じ名前なら、プロジェクトが、グローバルを上書きする。外から来るリポジトリのスキルは、許可したコマンドを実行できるので、**`vc skills trust` したプロジェクトだけ**読み込む（既定は未信頼）。[スキル](docs/skills.md#置き場所)
- **既定スキル**：どのスキルにも当てはまらない依頼は、組み込みの `default` スキルが、`agent-desktop` と基本のコマンド（`open`・`say`・`ls`・`pwd`・`date`）で実行する。会話・独り言は実行せず、取り消しにくい依頼（削除・送信・購入など）は確認する。使わないなら `vc skills disable default`。[スキル](docs/skills.md#既定スキルdefault)
- **確認**：確認が要るとき、パネルの「実行する」「やめる」を、ボタンで押すか、キーで選ぶか（← → で移り、Return で決める。y＝実行する、n・Esc＝やめる。最初は「やめる」にフォーカス）、声で「はい」と言う（先に答えたほうが決まる）。
- **Esc で取りやめ**（`vc listen --hotkey`）：録音中は録音を捨て、認識中・実行中・確認の待ちは処理（実行中のコマンドも）を止める。Esc を受けるのは、その間だけ。録音中（Shift を押している間）の Esc には、アクセシビリティの許可が要る。
- **結果を Markdown で見せる**：スキルのフロントマターの `result: markdown-window`（整形したウィンドウ）・`result: markdown-note`（ファイル）。[スキル](docs/skills.md#markdown-のウィンドウvc-showresult-markdown-window)
- **モデルを替える**（任意）：`--engine ollama:qwen3.5:4b`（Ollama）・`--engine openai:<モデル>@<ポート>`（LM Studio・llama.cpp など、OpenAI 互換）。通信先は、この Mac の 127.0.0.1 だけで、クラウドのモデルは使えない。許可の照合・上限・確認は、モデルに関わらず同じ。確認：`vc doctor --engine …`。[スキル](docs/skills.md#実行するモデルを替えるローカルのサーバー任意)

## 安全

- 実行は**シェルなし**。コマンドは、スキルの `allowed-commands` に一致したものだけ。シェル・`sudo`・`env` などは、許可できない。
- 言語モデルの出力・画面の内容・依頼文・コピーした文章は、非信頼のデータとして扱う。取り消しにくい操作は、確認を挟む。
- `allowed-commands` は、言語モデルの暴走への歯止め。許可したコマンドの中身（`rm` を許可すれば `rm` が動く）までは、守らない。
- 発話・画面の内容・入れた文字を、ファイルやログに残さない（画面にだけ表示する）。`result: markdown-note` のスキルだけは、結果を一時ディレクトリのファイルに残す（利用者だけが読める。消さない）。
- 通信は、スキルの取得（`vc skills install`）・モデルの取得（`vc model download`）と、この Mac の 127.0.0.1 への通信（`--engine`）だけ。

## ドキュメント

[docs/README.md](docs/README.md) が索引。

| 文書 | 内容 |
|---|---|
| [SPEC](SPEC.md) | 要件・受け入れ条件・対象外・未決事項（正本） |
| [AGENTS.md](AGENTS.md) | 開発規約・不変条件 |
| [スキル](docs/skills.md) | スキルの書き方・`allowed-commands`・表示・声の入力・Markdown のウィンドウ・モデルの切り替え |
| [開発手順](docs/development.md) | ビルド・テスト・GitButler・PR・リリース |
| [構成説明](docs/architecture.md) | Module・状態・並行・失敗・信頼の境界 |
| [コーディング指針](docs/coding-guidelines.md) | クリーンなコードの規則 |
| [参考にした設計原則](docs/references.md) | 採用・不採用の原則 |
| [リファクタリングの観点](docs/refactoring.md) | 見直しの観点と進め方 |
| [検証手順と記録](docs/verification.md) | 測定・確認した範囲・未確認 |

## 出典とライセンス

- `Sources/VCDecision/Decision/` の Tiny-Jev の実行（`BPETokenizer.swift`・`Safetensors.swift`・`QwenDecision.swift`・`OptionMarkerPrompt.swift`・`DecisionError.swift`）は、同じ作者の meeting-analyzer の複製（変更なし）。
- モデル：[lostargon/Tiny-Jev](https://huggingface.co/lostargon/Tiny-Jev)（版 `62449fb`）。**ライセンスの条件は未確認**。リポジトリには含めない。
- agent-desktop は、スキルが許可したコマンドとして、言語モデルが子プロセスで呼ぶだけ（Swift のコードは、直接は呼ばない。Apache-2.0）。
- このリポジトリのライセンスは **MIT**（[LICENSE](LICENSE)）。
