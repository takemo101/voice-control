import Foundation
import VCCore

/// 翻訳の表の**登録**：言語ごとの表（日本語の文 → その言語の文）。**言語を足したら、ここに、その言語の表を足す**（`switch` は、全部の言語が要る：足し忘れは、コンパイルで分かる）。
/// 日本語は、鍵そのもの（表は、要らない）。英語は、すべての言語の**もう 1 つの引き先**（その言語の表にない文は、英語で出る）なので、**英語の表は、抜けなく**保つ（`scripts/check-l10n.py`）。
enum L10nTables {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .ja: return [:]
        case .en: return EnglishTables.all
        }
    }
}

/// 言語の設定を、アプリ・端末の `vc` に反映する（起動の最初と、設定を変えたとき）。
enum AppLocalization {
    /// 表を入れて、言語を決める（起動の最初に、1 回）。
    static func bootstrap(settings: Settings) {
        for language in AppLanguage.allCases { L10n.shared.install(L10nTables.table(for: language), for: language) }
        apply(settings)
    }

    /// 設定の言語（表示言語・答えの言語）を、いまの言語にする。設定を変えたときも、これ（言語の決め方は、ここ 1 か所）。
    static func apply(_ settings: Settings) {
        L10n.shared.use(settings.displayLanguage)
        L10n.shared.useAnswerLanguage(settings.recognitionLanguageOrDefault)
    }
}
