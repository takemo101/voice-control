import Foundation
import VCCore

/// 英語の翻訳の表（日本語の文 → 英語の文）。**画面の言葉すべて**が対象（`tr`。モデルへの指示・照合の語・開発用のコマンドを除く）。領域ごとに、別のファイル（`English<領域>.swift`：設定・会話・モデル・ダイアログ・共通・システム・会話の画面・パネル・端末）。
/// 鍵は、コードの `tr("…")` の文と、同じ形（補間は `%@`）。足りない鍵は、日本語のまま出る（`scripts/check-l10n.py` が、抜けを見つける）。
enum EnglishTables {
    /// 全部の表。**同じ鍵に、違う訳があれば、あとの表が勝つ**（`scripts/check-l10n.py` が、そういう鍵を、問題として報告する：置き方で、訳が変わらないように）。
    static let all: [String: String] = [general, chat, models, dialogs, shared, system, chatui, panels, cli].reduce(into: [:]) { $0.merge($1) { _, new in new } }
}

/// 言語の設定を、アプリ・端末の `vc` に反映する（起動の最初と、設定を変えたとき）。
enum AppLocalization {
    /// 表を入れて、言語を決める（起動の最初に、1 回）。
    static func bootstrap(settings: Settings) {
        L10n.shared.install(english: EnglishTables.all)
        apply(settings)
    }

    /// 設定の言語（表示言語・答えの言語）を、いまの言語にする。設定を変えたときも、これ（言語の決め方は、ここ 1 か所）。
    static func apply(_ settings: Settings) {
        L10n.shared.use(settings.displayLanguage)
        L10n.shared.useAnswerLanguage(settings.recognitionLanguageOrDefault)
    }
}
