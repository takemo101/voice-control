import Foundation
import Testing
import VCDecision
@testable import VCSkill

/// スクリーンショットも、コピーした画像も、あるとき：Tiny-Jev の選び方。決められなければ、言葉の決め方に戻る。**片方しかなければ、聞かない**。
@Suite struct ImageSourceChoiceTests {
    private final class Counting: OptionScorer, @unchecked Sendable {
        var calls = 0
        let result: [Double]
        init(_ result: [Double]) { self.result = result }
        func score(state: String, question: String, options: [String]) throws -> [Double] { calls += 1; return result }
    }
    private let both: (ImageSource) -> ImageSource.Missing? = { _ in nil }
    private let onlyScreenshot: (ImageSource) -> ImageSource.Missing? = { $0 == .clipboard ? .clipboardEmpty : nil }

    @Test func itPicksOnlyWhenConfidentAndNeverTheUndecidedOption() {
        #expect(ImageSourceChoice.decide([0.8, 0.1, 0.1]) == .screenshot)
        #expect(ImageSourceChoice.decide([0.1, 0.8, 0.1]) == .clipboard)
        #expect(ImageSourceChoice.decide([0.1, 0.1, 0.8]) == nil)       // 「決められない」が、最も高い
        #expect(ImageSourceChoice.decide([0.5, 0.4, 0.1]) == nil)       // 確信が、しきい値に届かない
        #expect(ImageSourceChoice.decide([0.6, 0.3, 0.1]) == .screenshot)
    }

    @Test func theScorersOptionOrderIsMappedToScreenshotThenClipboard() throws {
        // 選択肢の並び（コピー・画面・決められない）と、返す順（スクリーンショット・コピー・決められない）が、入れ替わる
        let fake = Counting([0.7, 0.2, 0.1])   // 先頭＝「コピー」の手がかり
        #expect(try ImageSourceChoice(scorer: fake).probabilities(request: "x") == [0.2, 0.7, 0.1])
        #expect(ImageSourceChoice(scorer: fake).choose(request: "x") == .clipboard)
    }

    @Test func theJudgeDecidesOnlyWhenBothImagesExistAndOtherwiseWordsDecide() {
        var asked = 0
        let judge: (String) -> ImageSource? = { _ in asked += 1; return .clipboard }
        #expect(ImageSource.any.resolve(for: "貼り付ける画像を小さくして", unavailable: both, judge: judge) == .clipboard)   // 「コピー」の言葉がなくても
        #expect(asked == 1)
        #expect(ImageSource.any.resolve(for: "この画面を説明して", unavailable: onlyScreenshot, judge: judge) == .screenshot)   // 片方しかない：聞かない
        #expect(asked == 1)
        #expect(ImageSource.any.resolve(for: "コピーした画像を要約して", unavailable: both, judge: { _ in nil }) == .clipboard)    // 決められない：言葉に戻る
        #expect(ImageSource.any.resolve(for: "この画像を要約して", unavailable: both, judge: { _ in nil }) == .screenshot)
        #expect(ImageSource.screenshot.resolve(for: "コピーした画像", unavailable: both, judge: judge) == .screenshot)           // 取り先が決まっているときは、聞かない
        #expect(asked == 1)
    }

    @Test func theInstalledJudgeRemembersTheLastRequestAndIsEmptyUntilInstalled() {
        let judge = ImageSourceJudge()
        #expect(judge.pick("x") == nil)
        let fake = Counting([0.1, 0.8, 0.1])
        judge.install(fake)
        #expect(judge.pick("画面を説明して") == .screenshot && judge.pick("画面を説明して") == .screenshot)
        #expect(fake.calls == 1)   // 同じ依頼は、続けて聞かない（パネル・見る・加工の 3 か所から呼ばれる）
        _ = judge.pick("別の依頼")
        #expect(fake.calls == 2)
        judge.install(nil)
        #expect(judge.pick("画面を説明して") == nil)
    }
}
