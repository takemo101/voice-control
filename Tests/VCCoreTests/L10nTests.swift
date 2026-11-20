import Testing
@testable import VCCore

/// 表示言語：日本語のときは、鍵のまま（補間を入れて）。英語のときは、表の英語（なければ、日本語のまま）。
/// **グローバルの言語（`L10n.shared`）は、動かさない**：ほかのテストが、同じプロセスで、日本語の文を確かめている。テストごとに、自分の `L10n` を作る。
@Suite struct L10nTests {
    private func english() -> L10n {
        let l10n = L10n()
        l10n.install(["保存しました": "Saved", "%@ 件を読み込みました": "Loaded %@ items", "%@ を %@ に移しました": "Moved to %2$@ from %1$@"], for: .en)
        return l10n
    }
    private func translate(_ l10n: L10n, _ text: L10nKey) -> String { l10n.translate(text.key, args: text.args) }

    @Test func japaneseKeepsTheKeyAndEnglishUsesTheTableWithFallback() {
        let l10n = english()
        #expect(translate(l10n, "保存しました") == "保存しました")
        l10n.use(.en)
        #expect(translate(l10n, "保存しました") == "Saved")
        #expect(translate(l10n, "表にない文") == "表にない文")   // 欠けても、読める
        l10n.use(nil)
        #expect(translate(l10n, "保存しました") == "保存しました")
    }

    @Test func interpolationsBecomeNumberedOrSequentialSlots() {
        let l10n = english()
        let count = 3, from = "a.md", to = "b.md"
        #expect(translate(l10n, "\(count) 件を読み込みました") == "3 件を読み込みました")   // 日本語でも、補間が入る
        l10n.use(.en)
        #expect(translate(l10n, "\(count) 件を読み込みました") == "Loaded 3 items")
        #expect(translate(l10n, "\(from) を \(to) に移しました") == "Moved to b.md from a.md")   // 語順が変わる言語のために、番号で入れられる
    }

    @Test func settingsLanguagesDefaultToJapaneseAndTheSttOneReportsATypo() {
        var settings = Settings()
        #expect(settings.displayLanguage == .ja)
        #expect((try? settings.recognitionLanguage.get()) == .ja)
        settings.uiLanguage = "EN"; settings.sttLanguage = "en"
        #expect(settings.displayLanguage == .en && (try? settings.recognitionLanguage.get()) == .en)
        settings.uiLanguage = "zz"; settings.sttLanguage = "zz"
        #expect(settings.displayLanguage == .ja)                          // 画面は、書き間違いでも、読める
        #expect((try? settings.recognitionLanguage.get()) == nil)         // 認識は、黙って日本語にしない
    }

    @Test func promptsFollowTheAnswerLanguageOnlyWhenItIsNotJapanese() {
        let l10n = L10n()
        let prompt = "Answer in Japanese, briefly. Reply: done: <one short sentence in Japanese>."
        #expect(l10n.inAnswerLanguage(prompt) == prompt)
        l10n.useAnswerLanguage(.en)
        #expect(l10n.inAnswerLanguage(prompt) == "Answer in English, briefly. Reply: done: <one short sentence in English>.")
    }

    @Test func placeholdersAreFilledStrictlyAndOddTextIsLeftAlone() {
        // `%` が、置き換えの印でないとき・番号が足りないとき・引数がないとき：壊さずに、そのまま
        #expect(L10n.fill("完了率 100%", ["x"]) == "完了率 100%")
        #expect(L10n.fill("%@ と %3$@", ["a"]) == "a と %3$@")
        #expect(L10n.fill("%@ と %@", ["a"]) == "a と %@")
        #expect(L10n.fill("そのまま %@", []) == "そのまま %@")
        #expect(L10n.fill("%2$@ %1$@ %2$@", ["a", "b"]) == "b a b")   // 同じ番号を、何度でも
    }

    @Test func runtimeTextIsLookedUpAsItIsAndFallsBackToItself() {
        let l10n = english()
        l10n.use(.en)
        #expect(l10n.translate("保存しました", args: []) == "Saved")
        #expect(l10n.translate("表にない、実行時の文", args: []) == "表にない、実行時の文")
    }

    @Test func autoSpeechLanguageFollowsTheMacAndGivesNoCodeToTheModel() {
        #expect(SpeechLanguage.auto.resolved(systemLanguages: ["ja-JP", "en-US"]) == .ja)
        #expect(SpeechLanguage.auto.resolved(systemLanguages: ["en-JP"]) == .en)
        #expect(SpeechLanguage.auto.resolved(systemLanguages: []) == .en)
        #expect(SpeechLanguage.auto.whisperCode == nil && SpeechLanguage.en.whisperCode == "en")
        var settings = Settings(); settings.sttLanguage = "AUTO"
        #expect((try? settings.recognitionLanguage.get()) == .auto)
    }

    @Test func automaticAnswerLanguageAsksForTheUsersOwnLanguage() {
        let l10n = L10n()
        l10n.useAnswerLanguage(.auto)
        #expect(l10n.inAnswerLanguage("Answer in Japanese, briefly.") == "Answer in the user's language, briefly.")
    }

    @Test func aLanguageFallsBackToEnglishThenToTheJapaneseKeyAndAnEmptyValueMeansUntranslated() {
        let tables: [AppLanguage: [String: String]] = [.en: ["a": "English A", "b": "English B"], .ja: ["a": "", "c": "その言語の C"]]
        // 日本語以外の言語の引き方（日本語は、鍵のまま：`translate` が先に返す）。その言語の表 → 英語の表 → 鍵
        #expect(L10n.lookup("c", in: .ja, tables: tables) == "その言語の C")      // その言語の表
        #expect(L10n.lookup("a", in: .ja, tables: tables) == "English A")          // 値が空：未訳 → 英語
        #expect(L10n.lookup("b", in: .ja, tables: tables) == "English B")          // 表にない → 英語
        #expect(L10n.lookup("zzz", in: .ja, tables: tables) == "zzz")              // どちらにもない → 鍵のまま
        #expect(L10n.lookup("b", in: .en, tables: [:]) == "b")                     // 表がまったくない言語でも、落ちない
    }
}

