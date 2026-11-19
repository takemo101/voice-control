import Testing
@testable import VCCore

/// 表示言語：日本語のときは、鍵のまま（補間を入れて）。英語のときは、表の英語（なければ、日本語のまま）。
@Suite(.serialized) struct L10nTests {
    private func withEnglishTable(_ body: () -> Void) {
        let l10n = L10n.shared
        l10n.install(english: ["保存しました": "Saved", "%@ 件を読み込みました": "Loaded %@ items", "%@ を %@ に移しました": "Moved to %2$@ from %1$@"])
        defer { l10n.use(nil) }
        body()
    }

    @Test func japaneseKeepsTheKeyAndEnglishUsesTheTableWithFallback() {
        withEnglishTable {
            L10n.shared.use(nil)
            #expect(tr("保存しました") == "保存しました")
            L10n.shared.use(.en)
            #expect(tr("保存しました") == "Saved")
            #expect(tr("表にない文") == "表にない文")   // 欠けても、読める
        }
    }

    @Test func interpolationsBecomeNumberedOrSequentialSlots() {
        withEnglishTable {
            let count = 3, from = "a.md", to = "b.md"
            L10n.shared.use(nil)
            #expect(tr("\(count) 件を読み込みました") == "3 件を読み込みました")   // 日本語でも、補間が入る
            L10n.shared.use(.en)
            #expect(tr("\(count) 件を読み込みました") == "Loaded 3 items")
            #expect(tr("\(from) を \(to) に移しました") == "Moved to b.md from a.md")   // 語順が変わる言語のために、番号で入れられる
        }
    }

    @Test func settingsLanguagesDefaultToJapaneseAndTheSttOneReportsATypo() {
        var settings = Settings()
        #expect(settings.displayLanguage == .ja)
        #expect((try? settings.recognitionLanguage.get()) == .ja)
        settings.uiLanguage = "EN"; settings.sttLanguage = "en"
        #expect(settings.displayLanguage == .en && (try? settings.recognitionLanguage.get()) == .en)
        settings.uiLanguage = "fr"; settings.sttLanguage = "fr"
        #expect(settings.displayLanguage == .ja)                          // 画面は、書き間違いでも、読める
        #expect((try? settings.recognitionLanguage.get()) == nil)         // 認識は、黙って日本語にしない
    }

    @Test func promptsFollowTheAnswerLanguageOnlyWhenItIsNotJapanese() {
        defer { L10n.shared.useAnswerLanguage(.ja) }
        let prompt = "Answer in Japanese, briefly. Reply: done: <one short sentence in Japanese>."
        L10n.shared.useAnswerLanguage(.ja)
        #expect(L10n.shared.inAnswerLanguage(prompt) == prompt)
        L10n.shared.useAnswerLanguage(.en)
        #expect(L10n.shared.inAnswerLanguage(prompt) == "Answer in English, briefly. Reply: done: <one short sentence in English>.")
        #expect(!L10n.shared.inAnswerLanguage(prompt).contains("Japanese"))
    }

    @Test func placeholdersAreFilledStrictlyAndOddTextIsLeftAlone() {
        // `%` が、置き換えの印でないとき・番号が足りないとき・引数がないとき：壊さずに、そのまま
        #expect(L10n.fill("完了率 100%", ["x"]) == "完了率 100%")
        #expect(L10n.fill("%@ と %3$@", ["a"]) == "a と %3$@")
        #expect(L10n.fill("%@ と %@", ["a"]) == "a と %@")
        #expect(L10n.fill("そのまま %@", []) == "そのまま %@")
        #expect(L10n.fill("%2$@ %1$@ %2$@", ["a", "b"]) == "b a b")   // 同じ番号を、何度でも
    }

    @Test func verbatimLooksUpRuntimeTextAndFallsBackToItself() {
        withEnglishTable {
            L10n.shared.use(.en)
            #expect(tr(verbatim: "保存しました") == "Saved")
            #expect(tr(verbatim: "表にない、実行時の文") == "表にない、実行時の文")
        }
    }
}

