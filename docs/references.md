# 参考にした設計原則

実装とレビューで使う、設計原則の選択。製品要件の正本は [SPEC](../SPEC.md)、構成は [構成説明](architecture.md)、書き方は [コーディング指針](coding-guidelines.md)。ここに書いた原則は、設計判断の根拠であり、製品要件ではない。

## 出典と扱い

- 進め方・文書の構成・検証の方法：同じ作者の meeting-analyzer（`docs/`・`AGENTS.md`）に倣い、このプロジェクトに合わせて書き直した。**規約を、そのまま引き継いでいない**（製品構成・mikan・SwiftPM の外部依存の方針などは、移していない）。
- 設計原則の元：[j5ik2o/okite-ai](https://github.com/j5ik2o/okite-ai)（meeting-analyzer が参照している）。ほかに、次を参照した。原則の全文・コード例は転載しない。
  - John Ousterhout『A Philosophy of Software Design』：**深いモジュール**（小さな口で、多くを隠す）。
  - Robert C. Martin『Clean Architecture』：依存の向き（内側へ）。
  - Alexis King, [Parse, don't validate](https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/)：境界で一度だけ型にする。
  - Gary Bernhardt, [Functional Core, Imperative Shell](https://www.destroyallsoftware.com/screencasts/catalog/functional-core-imperative-shell)：純粋な核と、外との接点を分ける。
  - [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)：プロンプトの注入・過剰な権限（Excessive Agency）・出力の不適切な扱い。
  - 最小権限の原則（Principle of Least Privilege）：実行してよいコマンドを、明示した分だけにする。
- 対象は、小さな単一プロセスの CLI。**規模に見合わない儀式は、持ち込まない。**

## 選んだ原則

| 原則 | 判断 | このプロジェクトでの適用 | レビュー質問 |
|---|---|---|---|
| 変更理由で境界を決める | 採用 | 変わる理由ごとに、SwiftPM のターゲットを分ける：共通の部品（`VCCore`）、Tiny-Jev の実行・選択・モデル（`VCDecision`）、スキル（`VCSkill`）、音声（`VCSpeech`）、見せ方・引数・流れの組み立て（`vc`）。依存は下向きだけ。向きは `Package.swift` が宣言し、コンパイラが強制する | この変更は、どの理由で変わるのか。その理由を持つ場所は 1 か所か |
| 境界で一度だけ型にする（parse, don't validate） | 採用 | SKILL.md → `Skill`、コマンド行 → トークン列、設定 → `Settings`。内側は再検証しない | 検証が内側で繰り返されていないか。不正な値が境界を越えていないか |
| 最小権限 | 採用 | スキルは、`allowed-commands` に書いた分だけ実行できる。シェルなし・禁止コマンド・`--force` 拒否。言語モデルに渡す道具は `run_command` 1 つ | 権限は、必要な最小か。許可の外へ出る経路（シェル・パス・別のコマンドの起動）がないか |
| 非信頼の入力を命令にしない | 採用 | 発話・画面の内容・言語モデルの出力は、データとして扱い、実行の前に、毎回、検査する | 外から来た文字が、検査なしに、実行・保存・表示されていないか |
| 純粋な核を先にテストする | 部分採用 | 声の「はい」の判定（`Confirmation`）、スキルの選び方（`SkillResolver`）、許可の照合、SKILL.md の解析、勝ち抜き戦を、画面・音声・モデル抜きでテストする | 規則が、OS・モデルの呼び出しと混ざっていないか |
| 回復できる失敗は型にする | 採用 | `throws`・`Result` と、小さな `enum`（`Settings.Unreadable`・`CommandPolicy.Violation`…）。見せ方を決めるのは `vc` だけ | 失敗が握り潰されていないか。成功に見える代用品になっていないか |
| 差し替えが要る所だけ protocol | 採用 | `OptionScorer`（Tiny-Jev／テストの偽物）、`PushToTalkTrigger`（2 種類のトリガー）、`SkillExecuting`（言語モデル／テストの偽の実行者）、`RunReporter`（端末／画面の上の表示／テストの記録）、`VoiceLoop` の差し込み口 `Transcribing`・`Recording`・`EscapeSource`（実機／テストの偽物）。`vc` の `Command` は、差し替えではなく、同じ形のコマンドを名前で呼ぶための例外 | 実装が 1 つで、差し替えの必要がない protocol がないか |
| 目的が同じものだけ共通化する | 採用 | 候補の選択は `Chooser` に 1 つ。外部コマンドの起動は `ProcessRunner` に 1 つ（呼び出し側ごとに違う、時間の上限・標準エラーは、引数で表す）。意味が違う起動（鳴らしながら先へ進む `say` など）は、無理に載せない（[構成説明の負債](architecture.md#既知の構造上の負債)） | 似ているだけで、目的が違うものを、共通化していないか |
| 常に有効な値 | 部分採用 | `Skill` は、検証を通ったものだけが作られる。`Settings` は、既定が有効（無効だけを記録する） | 無効な値を、作れてしまっていないか |
| 測定で決める | 採用 | プロンプト（選択肢の説明・「操作の依頼か」の判定）の変更は、`just eval` で確かめる。うまくいかなかった案も、記録に残す（[検証手順と記録](verification.md)） | 効果を、測定で確かめたか。合わせ込みを、記録したか |

## 持ち込まないもの

- **DDD の語彙と部品**（Entity・Aggregate・Bounded Context）、リポジトリ、4 層構成、UseCase クラス。
- **すべてのプリミティブのラップ**。不変条件も取り違えもない値は、素のままにする。
- **全型の protocol 化**。
- **`Result` / `Either` の外部ライブラリ**、数値の目安（凝集・結合のメトリクス、ディレクトリの深さ、ファイル数）。
- **外部の Swift パッケージ**（標準フレームワークと、固定した外部ツール（agent-desktop）で足りる間は、足さない）。
- **言語モデルへの権限の付与を、プロンプトの指示だけで守ること**（許可は、コードで検査する）。

## 調べた外部の機能（確認の状況）

実装の判断に使った、外部の機能。**確認した範囲だけを、確認済みとして書く。** 日付・環境は [検証手順と記録](verification.md#環境記録の前提)。

| 機能 | 用途 | 確認 |
|---|---|---|
| `SystemLanguageModel`（FoundationModels） | コマンドの実行を担当する言語モデル。出力の形を、動的なスキーマで固定する | **確認済み**：この Mac で利用可・日本語に対応。`@Generable` のマクロは、プラグインが無く使えない。道具の呼び出し（`Tool`）は、**英語の指示のほうが確実**（6/6 と 1/6） |
| `SpeechTranscriber`／`SpeechAnalyzer`／`AssetInventory` | オンデバイスの文字起こし（ファイル） | **確認済み**：`say` の日本語音声を解析できた。マイクの入力は、**未確認** |
| `RegisterEventHotKey`（Carbon） | Control＋Option＋Space の押した・離した | **確認済み**（合成したキー入力）。許可は要らない |
| `NSEvent.addGlobalMonitorForEvents`（修飾キー） | Shift の単独の長押し | **確認済み**（合成したキー入力）。アクセシビリティの許可が要る |
| agent-desktop（snapshot・click・type・press・scroll・maximize 等） | 画面の操作 | **確認済み**（自作ウィンドウ）。アプリ一覧に壊れた記録があると TIMEOUT する。`launch` は使えない。`toggle`（スイッチ）は拒否される。`restore` の効果は未確認 |
| Tiny-Jev（MPSGraph） | 選択肢の選択 | **確認済み**：0.6B で 1 問約 0.1 秒（入力長 1024）。選択肢は 32 個まで。確率は、誤りにも高く出る |
