import Foundation
import TestSupport
import Testing
@testable import VCSkill

/// `vc translate`（F52。実験）：翻訳先は、コードが依頼の文から決める。文章はクリップボードから。
@Suite struct TextTranslationTests {
    private func plan(_ request: String, _ text: String) throws -> (source: String, target: String) {
        let planned = try TextTranslation.plan(request: request, text: text).get()
        return (planned.source.code, planned.target.code)
    }

    @Test func theLastLanguageNamedIsTheTarget() throws {
        let ja = "明日の会議は三時に始まります。資料の準備をお願いします。"
        #expect(try plan("コピーした文章を英語に翻訳して", ja).target == "en")
        #expect(try plan("コピーした日本語の文章を英語にして", ja).target == "en")   // 先に書かれた「日本語」ではなく、最後の「英語」
        #expect(try plan("これを韓国語に訳して", ja).target == "ko")
        #expect(try plan("コピーしたものをフランス語にして", ja).target == "fr")
        let en = "The meeting will start at three o'clock tomorrow. Please prepare the documents."
        #expect(try plan("英語の文章を日本語にして", en).target == "ja")
    }

    @Test func aLanguageFollowedByKaraIsTheSourceNotTheTarget() throws {
        let en = "The meeting will start at three o'clock tomorrow. Please prepare the documents."
        let planned = try plan("英語から日本語に翻訳して", en)
        #expect(planned.source == "en" && planned.target == "ja")
        // 翻訳元を言えば、文章の判定より優先する（短い文で、判定が外れても、使える）
        #expect(try plan("英語から日本語に翻訳して", "OK").source == "en")
    }

    @Test func withoutALanguageJapaneseGoesToEnglishAndOthersToJapanese() throws {
        #expect(try plan("コピーした文章を翻訳して", "明日の会議は三時に始まります。").target == "en")
        #expect(try plan("これを訳して", "The meeting will start at three o'clock tomorrow.").target == "ja")
    }

    @Test func traditionalAndSimplifiedChineseAreTold() throws {
        let ja = "明日の会議は三時に始まります。"
        #expect(try plan("中国語に翻訳して", ja).target == "zh-Hans")
        #expect(try plan("繁体字の中国語に翻訳して", ja).target == "zh-Hant")   // 字体があれば、ただの「中国語」は数えない
        #expect(try plan("簡体字にして", ja).target == "zh-Hans")
    }

    @Test func translatingIntoTheSameLanguageIsReported() {
        guard case let .failure(failure) = TextTranslation.plan(request: "日本語に翻訳して", text: "明日の会議は三時に始まります。") else { Issue.record("失敗するはず"); return }
        #expect(failure.message.contains("すでに日本語"))
    }

    @Test func emptyOrHugeTextIsRefusedBeforeTranslating() {
        #expect(throws: TextTranslation.Failure.self) { try TextTranslation.translate("  \n ", request: "英語に翻訳して") }
        #expect(throws: TextTranslation.Failure.self) { try TextTranslation.translate(String(repeating: "あ", count: TextTranslation.maxCharacters + 1), request: "英語に翻訳して") }
    }

    /// 実際の翻訳（この Mac の中。言語パックが要る）。CI の VM では、動かさない。
    @Test(.disabled(if: RunEnvironment.isCI, "翻訳の言語パックが、CI の VM にない"))
    func translatesLinesAndKeepsBlankLines() throws {
        let result = try TextTranslation.translate("明日の会議は三時に始まります。\n\n資料の準備をお願いします。", request: "英語に翻訳して")
        #expect(result.sourceName == "日本語" && result.targetName == "英語")
        let lines = result.text.components(separatedBy: "\n")
        #expect(lines.count == 3 && lines[1].isEmpty && !lines[0].isEmpty && !lines[0].contains("会議"))
    }
}

/// `vc translate` の、コマンドとしての動き：引数なし・文章はクリップボード・答えはウィンドウ・失敗は理由つき。
@Suite struct VcTranslateCommandTests {
    private func commands(clipboard: String?, request: String = "英語に翻訳して", translator: @escaping @Sendable (String, String) throws -> TextTranslation.Translated) -> InternalCommands {
        var c = InternalCommands(request: request, scorer: nil, memory: OptionMemory())
        c.clipboardText = { clipboard }
        c.translator = translator
        return c
    }

    @Test func showsTheTranslationInAWindowWithTheDirection() {
        let c = commands(clipboard: "こんにちは") { _, _ in .init(sourceName: "日本語", targetName: "英語", text: "Hello") }
        let output = c.run(["vc", "translate"])
        #expect(output.exitCode == 0 && output.document?.contains("日本語 → 英語") == true && output.document?.hasSuffix("Hello") == true)
    }

    @Test func passesTheClipboardTextAndTheRequestToTheTranslator() {
        let seen = Collected<String>()
        let c = commands(clipboard: "こんにちは", request: "フランス語に翻訳して") { text, request in seen.add("\(text)|\(request)"); return .init(sourceName: "日本語", targetName: "フランス語", text: "Bonjour") }
        _ = c.run(["vc", "translate"])
        #expect(seen.values == ["こんにちは|フランス語に翻訳して"])
    }

    @Test func argumentsAreRefused() {
        let c = commands(clipboard: "こんにちは") { _, _ in Issue.record("呼ばれないはず"); return .init(sourceName: "", targetName: "", text: "") }
        #expect(c.run(["vc", "translate", "こんにちは"]).exitCode == 2)
    }

    @Test func missingClipboardAndTranslatorFailuresAreReportedWithAReason() {
        #expect(commands(clipboard: nil) { _, _ in .init(sourceName: "", targetName: "", text: "") }.run(["vc", "translate"]).text.contains("コピーした文章がありません"))
        let failing = commands(clipboard: "こんにちは") { _, _ in throw TextTranslation.Failure(message: "言語が入っていません") }
        let output = failing.run(["vc", "translate"])
        #expect(output.exitCode == 1 && output.text == "error: 言語が入っていません" && output.document == nil)
    }
}
