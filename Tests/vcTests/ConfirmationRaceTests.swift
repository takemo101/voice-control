import Foundation
import Testing
@testable import vc
import TestSupport

/// 確認の答えを、パネルのボタンと声の返事の両方で待つ：先に答えたほうが決まり、もう一方は取りやめる。
@Suite struct ConfirmationRaceTests {
    /// 取りやめられるまで、答えを返さない声（取りやめられたかを、記録する）。
    private final class SilentVoice: @unchecked Sendable {
        private let lock = NSLock(); private var cancelled = false
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func listen() async throws -> Bool {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    // 取りやめの合図が来るまで、止まる（スレッドも、タイマーも、使わない）
                    lock.lock(); resume = c; lock.unlock()
                }
            } onCancel: {
                lock.lock(); cancelled = true; let c = resume; resume = nil; lock.unlock()
                c?.resume()
            }
            return false
        }
        private var resume: CheckedContinuation<Void, Never>?
    }

    @Test func aButtonPressedFirstDecidesAndStopsListening() async throws {
        let panel = PanelAnswer(), voice = SilentVoice()
        Task { try? await Task.sleep(nanoseconds: 50_000_000); panel.resolve(true) }
        #expect(try await ConfirmationRace.decide(panel: panel) { try await voice.listen() } == true)
        #expect(voice.wasCancelled)   // 声を待っていた処理は、止まる（次の発話を、横取りしない）
    }

    @Test func theNoButtonDeclines() async throws {
        let panel = PanelAnswer()
        panel.resolve(false)
        #expect(try await ConfirmationRace.decide(panel: panel) { try await SilentVoice().listen() } == false)
    }

    @Test func aSpokenYesDecidesAndTheButtonIsNoLongerWaited() async throws {
        let panel = PanelAnswer()
        #expect(try await ConfirmationRace.decide(panel: panel) { true } == true)
        panel.resolve(false)   // そのあとの押下は、答えに影響しない（すでに決まっている）
    }

    @Test func aFailureOfTheVoicePathIsThrownWhenNoButtonWasPressed() async {
        struct Broken: Error {}
        await #expect(throws: Broken.self) { try await ConfirmationRace.decide(panel: PanelAnswer()) { throw Broken() } }
    }

    @Test func theFirstPressWinsAndLaterPressesAreIgnored() async {
        let panel = PanelAnswer()
        panel.resolve(true); panel.resolve(false)
        #expect(await panel.wait() == true)
    }

    @Test func waitingForAButtonEndsWithNilWhenCancelled() async {
        let panel = PanelAnswer()
        let task = Task { await panel.wait() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func buttonsAreDeliveredOnlyWhileAConfirmationIsListening() {
        let route = AnswerRoute()
        let got = Collected<Bool>()
        route.deliver(true)   // つないでいない：何も起きない
        route.set { got.add($0) }
        route.deliver(false)
        route.set(nil)
        route.deliver(true)
        #expect(got.values == [false])
    }
}
