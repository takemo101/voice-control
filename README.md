# voice-control（試作）

Mac を、依頼文や声で操作する試作。**依頼に合うスキルを Tiny-Jev（オンデバイスの小さな選択モデル）が選び、Apple の言語モデル（FoundationModels）が、スキルの指示に従って、コマンドを実行する。** 実行するコマンドは、スキルが許可したものだけで、すべて画面に表示される。音声・画面の内容・依頼文は、この Mac の外へ出さない。

いまは CLI（`vc`）。どの使い道が成り立つかを、測定で確かめる段階で、完成した製品ではない。

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
| **スキル**（`vc skills`・`vc run`） | 自作ウィンドウで確認（「設定ボタンを押して」6/6）。**実アプリ・複数スキルの取り違えは未確認** |
| 声の入力（`vc listen`。ホットキー・マイク） | 実装済み（聞こえた文は、スキルの流れで実行する。ホットキーは `vc hotkey` で変更でき、押している間は画面に「録音中」が出る）。**マイクの実録音は未確認** |

PC 操作は、2026-11-04 に廃止し、既定スキルに一本化した（[SPEC](SPEC.md)）。詳細な要件と状態は [SPEC](SPEC.md)、測定と未確認は [検証手順と記録](docs/verification.md)。

## 必要なもの

- macOS 26 以降・Apple silicon。ソースからビルドするときは、Swift 6.2 以降（Xcode または Command Line Tools）。
- [agent-desktop](https://github.com/vercel-labs/agent-desktop)（`npm install -g agent-desktop`）。アクセシビリティの許可が要る（`agent-desktop permissions`）。
- Apple Intelligence（FoundationModels）が使える Mac。**オンにしておく**：システム設定 > Apple Intelligence と Siri（オンにすると、言語モデルのダウンロードが始まる）。オフ・準備中・非対応のとき、`vc run`・`vc listen` は、理由と手順を示して終わる。
- Tiny-Jev 0.6B のモデル（約 1.2 GB。`vc model download` で `~/.voice-control/models/` に取得）。[just](https://github.com/casey/just) は任意。

## はじめかた

**コマンド 1 つで入れる**（最新の [Release](https://github.com/takemo101/voice-control/releases)。ビルドは要りません）：

```sh
curl -fsSL https://raw.githubusercontent.com/takemo101/voice-control/main/install.sh | bash
```

Release の tar.gz を取得して SHA-256 を照合し、`vc` を `~/.local/bin` へ置き、Tiny-Jev のモデル（約 1.2 GB）を `~/.voice-control/models` に取得し、`vc doctor` で環境（Apple Intelligence など）を確かめる（[install.sh](install.sh)。中身は短いので、実行前に読める）。設定・スキル・許可には触れない。オプション：`--no-model`（モデルを取得しない）・`--version 0.1.0`（版を指定）・`--bin-dir <場所>`。例：`curl -fsSL …/install.sh | bash -s -- --no-model`。`~/.local/bin` が PATH にないときは、そう知らせる。

**手で入れる**（[v0.1.0](https://github.com/takemo101/voice-control/releases/tag/v0.1.0) の例）：

```sh
V=0.1.0
curl -fsSLO https://github.com/takemo101/voice-control/releases/download/v$V/vc-$V-macos-arm64.tar.gz
curl -fsSLO https://github.com/takemo101/voice-control/releases/download/v$V/vc-$V-macos-arm64.tar.gz.sha256
shasum -a 256 -c vc-$V-macos-arm64.tar.gz.sha256      # SHA-256 を照合
tar -xzf vc-$V-macos-arm64.tar.gz
mkdir -p ~/.local/bin && install -m 755 vc-$V-macos-arm64/vc ~/.local/bin/vc   # ~/.local/bin を PATH に入れておく
vc model download     # Tiny-Jev を ~/.voice-control/models に取得（SHA-256 を検証。途中からの再開ができる）
vc --help
```

署名は ad-hoc（Developer ID の署名・公証なし）。ブラウザでダウンロードして Gatekeeper に止められたら、`xattr -dr com.apple.quarantine ~/.local/bin/vc`。上の `curl` なら、止められない。取り除くとき：`rm ~/.local/bin/vc`（モデル・設定・スキルは `~/.voice-control` に残る）。

**ソースから入れる**（リポジトリを clone して。Swift 6.2 以降が要る）：

```sh
just install          # vc を ~/.local/bin へ入れる
vc model download
just test             # 単体テスト
```

配布物の作り方：[開発手順](docs/development.md#リリース)。

スキルを置いて、使う：

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
vc run "Safariを開いて" --dry-run             # 何を実行しようとするかだけ見る
vc run "Safariを開いて"                       # 実行
vc skills disable open-app                   # 選択肢から外す（enable で戻す）
```

| コマンド | 内容 |
|---|---|
| `vc skills [list]` | スキルの一覧（name・置き場所・description・有効／無効） |
| `vc skills show <name>` | 許可するコマンド・確認の要否・置き場所・場所 |
| `vc skills enable <name>` / `disable <name>` | Tiny-Jev の選択肢にするか（既定は有効） |
| `vc skills trust` / `untrust` | このプロジェクト（`vc` を起動した場所）の `.voice-control/skills` を、読み込んでよいか |
| `vc run "<依頼>" [--skill <name>] [--dry-run] [--yes]` | スキルを選び、実行する |
| `vc doctor` | 動かすのに必要なもの（Apple Intelligence・Tiny-Jev・agent-desktop・許可・設定ファイル）が、そろっているかを確かめ、使えないものは直す手順を示す（必須が使えなければ、終了コード 1） |
| `vc model [status\|download\|path]` | Tiny-Jev のモデルの確認・取得（`~/.voice-control/models`） |
| `vc hotkey [show\|set <キー>\|reset]` | 押している間だけ聞くトリガーの確認・変更（既定：Shift の長押し。例：`vc hotkey set ctrl+opt+space`）。押している間は、画面の上に「録音中」が出る |
| `vc listen [--hotkey] [--trigger <キー>] [--dry-run] [--yes]` | マイクから聞いて、スキルで実行する（既定：Enter で録音。`--hotkey`：押している間だけ録音。[声の入力](docs/skills.md#声の入力vc-listen)） |

ヘルプ：`vc --help`（コマンドの一覧・共通のオプション・環境変数）、`vc <コマンド> --help`（使い方・オプション・例）。出力は、端末なら色つき（`NO_COLOR=1` で無効）。

**プロジェクトのスキル**：`<プロジェクトのルート>/.voice-control/skills/<name>/SKILL.md` にも置ける（ルートは、`vc` を起動した場所。同じ名前なら、プロジェクトが、グローバルを上書きする）。外から来るリポジトリのスキルは、許可したコマンドを実行できるので、**`vc skills trust` したプロジェクトだけ**読み込む（既定は未信頼）。詳しくは [スキル](docs/skills.md#置き場所)。

**既定スキル**：どのスキルにも当てはまらない依頼は、組み込みの `default` スキルが、Apple の言語モデルで、`agent-desktop` と基本のコマンド（`open`・`say`・`ls`・`pwd`・`date`）を使って実行する。会話・独り言は実行せず、取り消しにくい依頼（削除・送信・購入など）は確認する。許可を広げるなら、同じ名前（`default`）のスキルを置く（シェルは許可できない）。使わないなら `vc skills disable default`。詳しくは [スキル](docs/skills.md#既定スキルdefault)。

**Esc で取りやめ**（`vc listen --hotkey`）：録音中は録音を捨て、認識中・実行中・確認の待ちは処理（実行中のコマンドも）を止める。Esc を受けるのは、その間だけ。録音中（Shift を押している間）の Esc には、アクセシビリティの許可が要る。

スキルの書き方・`allowed-commands` の仕様・表示は [スキル](docs/skills.md)。スキルをエージェントに作らせるときは、[スキルを作るスキル](skills/voice-control-skill-author/SKILL.md)。

## 安全

- 実行は**シェルなし**。コマンドは、スキルの `allowed-commands` に一致したものだけ。シェル・`sudo`・`env` などは、許可できない。
- 言語モデルの出力・画面の内容・依頼文は、非信頼のデータとして扱う。取り消しにくい操作は、確認を挟む。
- `allowed-commands` は、言語モデルの暴走への歯止め。許可したコマンドの中身（`rm` を許可すれば `rm` が動く）までは、守らない。
- 発話・画面の内容・入れた文字を、ファイルやログに残さない（画面にだけ表示する）。

## ドキュメント

[docs/README.md](docs/README.md) が索引。

| 文書 | 内容 |
|---|---|
| [SPEC](SPEC.md) | 要件・受け入れ条件・対象外・未決事項（正本） |
| [AGENTS.md](AGENTS.md) | 開発規約・不変条件 |
| [開発手順](docs/development.md) | ビルド・テスト・GitButler・PR |
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
