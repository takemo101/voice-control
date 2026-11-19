import Foundation
import VCCore

/// 英語の翻訳の表（日本語の文 → 英語の文）。**設定ウィンドウとダイアログだけ**が対象（`tr`）。領域ごとに、別のファイル（`English<領域>.swift`）。
/// 鍵は、コードの `tr("…")` の文と、同じ形（補間は `%@`）。足りない鍵は、日本語のまま出る（`scripts/check-l10n.py` が、抜けを見つける）。
enum EnglishTables {
    static let all: [String: String] = [:]
        .merging(general) { $1 }
        .merging(chat) { $1 }
        .merging(models) { $1 }
        .merging(dialogs) { $1 }
        .merging(shared) { $1 }
}

/// 言語の設定を、アプリ・端末の `vc` に反映する（起動の最初と、設定を変えたとき）。
enum AppLocalization {
    /// 表を入れて、表示言語を決める。
    static func bootstrap(settings: Settings) {
        L10n.shared.install(english: EnglishTables.all)
        L10n.shared.use(settings.displayLanguage)
    }
}
