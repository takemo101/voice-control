import Foundation
import Testing
@testable import VCSpeech
import VCCore

/// 聞き取りに自信がないとき（確信度が、しきい値未満）、実行の前に、確かめる（`Uncertainty`。`vc recheck`）。
@MainActor @Suite struct RecheckTests {
    @Test func theMeanConfidenceIsWeightedByCharacters() {
        #expect(Transcription.meanConfidence([]) == nil)
        #expect(Transcription.meanConfidence([(characters: 0, confidence: 0.5)]) == nil)
        let mean = Transcription.meanConfidence([(characters: 9, confidence: 1.0), (characters: 1, confidence: 0.0)])
        #expect(mean != nil && abs(mean! - 0.9) < 1e-9)   // 長い語の確信度が、重い（短い 1 語の低さに、引きずられすぎない）
    }

    private func harness(threshold: Double, confirm: @escaping @Sendable (String, Double) async -> Bool, handled: Mailbox<String>) -> Harness {
        let h = Harness { utterance, _, _, _ in handled.put(utterance) }
        h.loop.uncertainty = Uncertainty(threshold: threshold) { text, confidence, _, _, _ in await confirm(text, confidence) }
        return h
    }

    @Test func aConfidentUtteranceGoesStraightToTheHandler() async {
        let handled = Mailbox<String>(), asked = Counter()
        let h = harness(threshold: 0.9, confirm: { _, _ in _ = asked.next(); return true }, handled: handled)
        h.transcriber.confidence("a1", 0.97)
        h.speak("a1")
        #expect(await handled.take() == "text-a1")
        #expect(asked.next() == 1)   // 確認は、呼ばれていない（ここで数えるのが 1 回目）
    }

    @Test func anUnsureUtteranceIsConfirmedAndRunsOnlyIfApproved() async {
        let handled = Mailbox<String>(), seen = Mailbox<String>()
        let h = harness(threshold: 0.9, confirm: { text, confidence in seen.put("\(text)@\(confidence)"); return true }, handled: handled)
        h.transcriber.confidence("a1", 0.62)
        h.speak("a1")
        #expect(await seen.take() == "text-a1@0.62")
        #expect(await handled.take() == "text-a1")
    }

    @Test func aDeclinedUtteranceNeverReachesTheHandler() async {
        let handled = Mailbox<String>(), asked = Mailbox<Void>()
        let h = harness(threshold: 0.9, confirm: { _, _ in asked.put(()); return false }, handled: handled)
        h.transcriber.confidence("a1", 0.5)
        h.speak("a1")
        await asked.take()
        h.transcriber.confidence("a2", 0.99)
        h.speak("a2")
        #expect(await handled.take() == "text-a2")   // a1 は、ハンドラに届かず、次の a2 だけが届く
    }

    @Test func withoutAConfidenceNothingIsConfirmed() async {
        let handled = Mailbox<String>(), asked = Counter()
        let h = harness(threshold: 0.9, confirm: { _, _ in _ = asked.next(); return false }, handled: handled)
        h.speak("a1")   // 確信度なし（Whisper など）
        #expect(await handled.take() == "text-a1")
        #expect(asked.next() == 1)
    }

    @Test func withoutTheFeatureNothingChanges() async {
        let handled = Mailbox<String>()
        let h = Harness { utterance, _, _, _ in handled.put(utterance) }   // `uncertainty` なし（`vc recheck off`）
        h.transcriber.confidence("a1", 0.1)
        h.speak("a1")
        #expect(await handled.take() == "text-a1")
    }
}
