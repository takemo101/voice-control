# ドキュメント案内

voice-control の補助文書の入口。製品要件・受け入れ条件・対象外の唯一の正本は、ルートの [SPEC.md](../SPEC.md)。`docs/` は、仕様を別管理する場所ではなく、構成の理解・開発手順・検証・書き方のために使う。

## 文書の役割

| 文書 | 答えること | 管理しないこと |
|---|---|---|
| [README](../README.md) | どんなツールか、いま何ができるか、どう使うか | 詳細な要件・測定の数値 |
| [SPEC](../SPEC.md) | 何を満たすか・何を対象にしないか、受け入れ条件と実装の状態、未決事項 | 検証の成功証拠 |
| [開発規約](../AGENTS.md) | どう調査・変更・検証・文書更新するか、守る不変条件 | 製品仕様の複製・作業履歴 |
| [開発手順](development.md) | ビルド・テスト・インストール・mikan の Issue 進行・GitButler・PR を、どう進めるか | 追加の実施権限・Issue 状態の複製 |
| [構成説明](architecture.md) | Module の責務・状態の所有・時間と並行・失敗・信頼の境界はどう関係するか | 確定 API・測定の数値 |
| [コーディング指針](coding-guidelines.md) | クリーンなコードの具体的な規則（境界・型・失敗・並行・外部コマンド・プロンプト・テスト） | 製品要件 |
| [参考にした設計原則](references.md) | どの設計原則を選び、何を選ばなかったか。調べた外部の機能と確認の状況 | 製品要件・原則の全文 |
| [リファクタリングの観点](refactoring.md) | 動作を変えずに見直すときの観点と進め方 | 製品要件・実施権限・スコア化 |
| [検証手順と記録](verification.md) | 条件をどう観測し、何をいつ確認したか、何が人間の確認待ちか | 新しい合格条件・未実施の成功 |
| [スキル](skills.md) | スキルの書き方・`allowed-commands` の仕様・コマンド・表示・安全 | 製品要件（正本は SPEC F1〜F6） |
| [PC 操作の流れ](pc-control.md) | 候補の作り方・ゲート・複数の手・文脈・音声入力の設計と限界（試作） | 製品要件（正本は SPEC F7・F8）・測定の数値 |
| [スキルを作るスキル](../skills/voice-control-skill-author/SKILL.md) | エージェントが、`~/.voice-control/skills` のスキルを、正しい形で作る手順 | スキルの形の要件（正本は SPEC F1） |

文書間で矛盾を見つけたら、派生文書を根拠に製品要件を変更しない。SPEC の該当節と利用者の判断を確認し、必要な修正を、関係する文書へ反映する。

## 読む順序

- **ツールを知る**：README → SPEC の位置づけ・機能要件・対象外 → [スキル](skills.md)。
- **作業を始める**：SPEC の対象節と §6・§7 → [開発規約](../AGENTS.md)・[開発手順](development.md) → [構成説明](architecture.md)の該当 Module → [コーディング指針](coding-guidelines.md) → 実際のソース。
- **設計を判断する**：[参考にした設計原則](references.md) → [構成説明](architecture.md)。見直すときは、[リファクタリングの観点](refactoring.md)。
- **動作を確かめる**：SPEC の受け入れ条件 → [検証手順と記録](verification.md)。設計の説明だけで、動作確認を済ませない。
- **結果を判断する**：検証記録 → SPEC の受け入れ条件。自動の観測と、人間の確認を区別する。

## 配置

```text
README.md              概要・使い方
SPEC.md                製品要件・受け入れ条件（実装の状態つき）・対象外・未決事項
AGENTS.md              開発規約・不変条件
LICENSE                MIT
Package.swift          SwiftPM（macOS 26、外部の Swift パッケージなし）
justfile               開発用コマンド（build・test・install・eval・fixture）
Sources/
  vc/                  実行ファイル（main.swift：起動の流れ（`Arguments` を読み、`Commands.all` からコマンドを探して実行）。Arguments.swift：引数の読み方、Command.swift：`Command` と一覧、CommandContext.swift：コマンドが共有するもの、Commands/：`skills`・`run`・`listen`（声の流れ：`VoiceLoop` に、発話の処理と出来事の表示を渡す。スキルが選ばれなければ、`PCRunner` を呼ぶアダプター）・`plan`・`act`（PCControl.swift）・`eval`（Eval.swift）・`keys`・`hotkey`・`hotkey-check`・`hud-preview`・`model`・`eval-gate`・`llm`・`decompose`・`eval-context`、SkillSupport.swift（スキルの読み込み）・HotKeySupport.swift：コマンドが使う共通の処理、TerminalReporter.swift・HUDReporter.swift：スキルの実行の経過の表示（`SkillRunner` の出来事の受け手）、TerminalPCReporter.swift・HUDPCReporter.swift：PC 操作の経過の表示（`PCRunner` の出来事の受け手）、Help.swift：ヘルプ、Output.swift：表示の整形、HUD.swift・HUDContent.swift・HUDSession.swift：録音中などの画面表示、SaySpeaker.swift：読み上げの停止）
  Fixture/             検証用の自作ウィンドウ
  VCCore/              どのターゲットも使う小さな部品（VoiceControlHome：場所、Settings：設定、CancelToken：取りやめの合図、ProcessRunner：外部コマンドの実行）
  VCDecision/          選択と判断の土台
    Decision/          Tiny-Jev の実行（meeting-analyzer からの複製を含む）
    Choice/            選択肢の採点・勝ち抜き戦・ゲート（Gate）
    Model/             Tiny-Jev の取得・検証・置き場所（ModelStore）
  VCSkill/             SKILL.md の読込（Skill・SkillStore・FrontMatter）・許可の照合・実行（CommandRunner・OutputCompactor・RefAliases）・言語モデル（SkillAgent）・既定スキル（DefaultSkill）・実行の流れ（SkillRunner：選ぶ → 確認 → 実行 → 結果。経過は RunEvent で RunReporter へ。SkillExecuting：実行者の口）
  VCPCControl/         PC 操作の計画・実行・agent-desktop（PCRunner：計画 → 門 → 確認 → 実行 → 履歴の流れ。経過は PCEvent で PCReporter へ。PCEval：評価コーパスの部品）
  VCSpeech/            文字起こし・録音・トリガー（HotKeySpec：ホットキーの書き方・Settings+HotKey：設定の解釈）・Esc（EscapeKey）・声の流れの調整（VoiceLoop：トリガー・録音・Esc・認識の待ち行列・発話ごとの Task。差し替え口は Transcribing・Recording・EscapeSource。状態は VoiceActivity・VoiceInputQueue）
Tests/                 単体テスト（Swift Testing）。ターゲットごと（`Tests/<ターゲット>Tests/`。1 ファイル 1 領域でファイル名はスイート名）：VCCoreTests・VCDecisionTests・VCSpeechTests・VCSkillTests・VCPCControlTests（PCRunner・PCEval を含む）・vcTests（`vc` の引数の読み方・コマンドの一覧・スキルと PC 操作の実行の表示）。TestSupport は、複数のターゲットが使う偽物（`OptionScorer`・`Desktop`）のテスト専用ターゲット
corpus/                評価用の文（plans.tsv・followups.tsv・gate.tsv）と、自作ウィンドウの画面（snapshots/）
keys/                  キー操作の JSON 定義の例
skills/
  voice-control-skill-author/  スキルを作るスキル（エージェント向け）
.voice-control/
  skills/spotify/      このプロジェクトのスキルの例（Spotify の操作。AppleScript）
scripts/
  install.sh           vc を ~/.local/bin へ入れる
  uninstall.sh         入れた vc とモデルのリンクを取り除く
  test.sh              単体テスト（Swift Testing のマクロプラグインのパスを渡す）
  package.sh           配布用の tar.gz と SHA-256 を dist/ に作る
  verify-package.sh    tar.gz を展開して検査する
.github/workflows/
  release.yml          タグ vX.Y.Z の push で、vc をビルドして GitHub Release に添付する
docs/
  README.md            この索引
  development.md       ビルド・テスト・GitButler・PR
  architecture.md      構成・状態・時間と並行・失敗・信頼の境界
  coding-guidelines.md クリーンなコードの規則
  references.md        参考にした設計原則・調べた外部の機能
  refactoring.md       リファクタリングの観点と進め方
  verification.md      検証手順・記録・人間の確認待ち
  skills.md            スキルの書き方と仕様
  pc-control.md        PC 操作の流れ（試作）
```

`models/`（開発用に、Tiny-Jev の重みを置いてもよい場所。約 1.2 GB）と `.build/`・`dist/` は Git 対象外。`~/.voice-control/` は、利用者のスキル・設定・モデル（`vc model download`）で、リポジトリの外。

## 更新時の扱い

- 製品の意味・数値・範囲を変えるときは、SPEC を正本とする。補助文書に同じ値を別管理せず、必要な節へ参照する。実装が進んだら、SPEC §6 の「状態」を、同じ変更で更新する。
- 構成説明は、選択した境界と理由。検証記録は、実際の操作と観測。**説明・予定・結果を混ぜない。**
- 文書を追加・移動・削除したら、この索引と参照元を、同じ変更で更新する。見出しを変えたら、その見出しを参照するリンクも確認する。
- 未実施・失敗・限定的な成功を残す。後の修正や再試行は、別の記録として結び付け、過去の証拠を、全面的な成功へ書き換えない。
- 利用していないツールの操作手順や、架空のコマンドを案内しない。
