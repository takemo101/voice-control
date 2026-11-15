import Foundation
import Testing
import VCDecision
@testable import VCSkill

/// 会話で、撮ったスクリーンショットを使うかの振り分け：添えた画像は判定しない・「コピーした〜」は判定しない・スクリーンショットがあるときだけ Tiny-Jev に聞く・判定できなければ言葉で決める。
@Suite struct ChatImageUseTests {
    private struct Fixed: OptionScorer {
        let yes: Double
        func score(state: String, question: String, options: [String]) throws -> [Double] { [1 - yes, yes] }
    }
    private final class Recorder: OptionScorer, @unchecked Sendable {
        var state = ""
        func score(state: String, question: String, options: [String]) throws -> [Double] { self.state = state; return [0.5, 0.5] }
    }
    private struct Broken: Error {}

    private func plan(_ request: String, attached: Bool = false, screenshot: Bool = true, judge: (() throws -> Double)?) -> ChatAttachments.ImagePlan {
        ChatAttachments.imagePlan(request: request, hasAttached: attached, screenshotAvailable: screenshot, judge: judge)
    }

    @Test func anAttachedImageIsUsedWithoutAskingTheJudge() {
        var asked = false
        #expect(plan("明日の天気は？", attached: true, judge: { asked = true; return 0 }) == .attached)
        #expect(!asked)
    }

    @Test func theJudgeDecidesForAShotScreenshotAndTheThresholdIsInclusive() {
        #expect(plan("これ、何？", judge: { ChatImageUse.threshold }) == .screenshot)
        #expect(plan("明日の天気は？", judge: { 0.4 }) == .skippedScreenshot(0.4))
        #expect(!ChatAttachments.ImagePlan.skippedScreenshot(0.4).usesImage && ChatAttachments.ImagePlan.screenshot.usesImage)
    }

    @Test func withoutAShotScreenshotTheJudgeIsNotAskedAndWordsDecide() {
        var asked = false
        #expect(plan("この画面を説明して", screenshot: false, judge: { asked = true; return 1 }) == .byWords)
        #expect(plan("明日の天気は？", screenshot: false, judge: { asked = true; return 1 }) == .none)
        #expect(!asked)
    }

    @Test func aFailedOrMissingJudgeFallsBackToWordsNeverToUsingTheScreenshotBlindly() {
        #expect(plan("これ、何？", judge: { throw Broken() }) == .none)               // 画像の言葉がない：使わない
        #expect(plan("この画面を説明して", judge: { throw Broken() }) == .byWords)     // 画像の言葉がある：従来どおり
        #expect(plan("この画面を説明して", judge: nil) == .byWords)
    }

    @Test func explicitCopyWordsGoToTheClipboardWithoutAskingTheJudge() {
        var asked = false
        #expect(plan("コピーした画像を要約して", judge: { asked = true; return 0 }) == .clipboard)
        #expect(plan("コピーした文章を要約して", judge: { asked = true; return 1 }) == .none)   // 文章は、画像の判定の対象外
        #expect(!asked)
    }

    @Test func theJudgeSeesThePremiseAndTheUtteranceAndReturnsTheYesSide() throws {
        let recorder = Recorder()
        _ = try ChatImageUse(scorer: recorder).probability(request: "それは、なぜ？")
        #expect(recorder.state.contains("スクリーンショットを撮った") && recorder.state.hasSuffix("発話: それは、なぜ？"))
        #expect(try ChatImageUse(scorer: Fixed(yes: 0.7)).probability(request: "x") == 0.7)
    }
}
