import Foundation
import TestSupport
import Testing
@testable import VCSkill
import VCCore
import VCDecision

@Suite struct SkillRunnerTests {
    @Test func aMatchingSkillIsExecutedWithoutAsking() async throws {
        let factory = Factory { display in display.onCommand("open -a Spotify"); display.onResult(0, "ok"); return "done: 開いた" }
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [DefaultSkill.skill, skill("spotify", spotifyDescription)], factory: factory)
            .run("次の曲", reporter: reporter, confirm: { Issue.record("確認は要らない"); return false })

        #expect(outcome == .completed)
        #expect(reporter.kinds == ["matched", "started", "command", "result", "reply"])
        guard case let .matched(matched, probability, _) = reporter.events[0] else { Issue.record("matched ではない"); return }
        #expect(matched.name == "spotify" && probability > 0.7)
        guard case let .reply(reply, _, _) = reporter.events[4] else { Issue.record("reply ではない"); return }
        #expect(reply == "done: 開いた")
        #expect(factory.made.map(\.skill) == ["spotify"] && factory.made[0].executor.requests == ["次の曲"])
    }

    @Test func noMatchFallsBackToTheDefaultSkillAndExecutes() async throws {
        let factory = Factory()
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: nil), skills: [DefaultSkill.skill, skill("spotify", spotifyDescription)], factory: factory)
            .run("電卓を開いて", reporter: reporter, confirm: { false })

        #expect(outcome == .completed)
        #expect(reporter.kinds == ["fellBack", "started", "reply"])
        guard case let .fellBack(fallback, probability, risk, _) = reporter.events[0] else { Issue.record("fellBack ではない"); return }
        #expect(fallback.name == DefaultSkill.name && probability == 0.9 && risk == 0.1)
        #expect(factory.made.map(\.skill) == [DefaultSkill.name])
    }

    @Test func conversationIsDeclinedAndNothingRuns() async throws {
        let factory = Factory()
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: nil, actionable: 0.01), skills: [DefaultSkill.skill], factory: factory)
            .run("ちょっと待ってね", reporter: reporter, confirm: { true })

        #expect(outcome == .declined(fallbackAvailable: true))
        #expect(reporter.kinds == ["declined"])
        guard case let .declined(reason, available, _) = reporter.events[0] else { Issue.record("declined ではない"); return }
        #expect(available && reason.contains("操作の依頼ではない"))
        #expect(factory.count == 0)
    }

    @Test func withoutADefaultSkillNothingIsRunAndTheOutcomeSaysSo() async throws {
        let factory = Factory()
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: nil), skills: [skill("spotify", spotifyDescription)], factory: factory)
            .run("電卓を開いて", reporter: reporter, confirm: { true })

        #expect(outcome == .declined(fallbackAvailable: false))
        #expect(reporter.kinds == ["declined"] && factory.count == 0)
    }

    @Test func aSkillThatRequiresConfirmationDoesNotRunWhenRefused() async throws {
        let factory = Factory()
        let reporter = Recorder()
        let asked = LockedBox(0)
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription, confirm: true)], factory: factory)
            .run("次の曲", reporter: reporter, confirm: { asked.mutate { $0 += 1 }; return false })

        #expect(outcome == .notConfirmed)
        #expect(reporter.kinds == ["matched", "confirmRequired", "confirmationDeclined"])
        #expect(asked.value == 1)
        guard case let .confirmRequired(asking, reason) = reporter.events[1] else { Issue.record("confirmRequired ではない"); return }
        #expect(asking.name == "spotify" && reason == SkillResolver.confirmRequiredReason)
        #expect(factory.count == 0)
    }

    @Test func aSkillThatRequiresConfirmationRunsWhenApproved() async throws {
        let factory = Factory()
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription, confirm: true)], factory: factory)
            .run("次の曲", reporter: reporter, confirm: { true })

        #expect(outcome == .completed)
        #expect(reporter.kinds == ["matched", "confirmRequired", "confirmed", "started", "reply"])
        #expect(factory.count == 1)
    }

    @Test func lowConfidenceMatchAsksBeforeRunning() async throws {
        var gate = Gate()
        gate.execute = 0.99
        let factory = Factory()
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription)], gate: gate, factory: factory)
            .run("次の曲", reporter: reporter, confirm: { false })

        #expect(outcome == .notConfirmed)
        guard case let .confirmRequired(_, reason) = reporter.events[1] else { Issue.record("confirmRequired ではない"); return }
        #expect(reason == "確信度が高くないので、確認します")
        #expect(factory.count == 0)
    }

    @Test func aRiskyRequestOnTheDefaultSkillAsksBeforeRunning() async throws {
        let factory = Factory()
        let reporter = Recorder()
        let denied = try await runner(SkillScorer(routedDescription: nil, destructive: 0.9), skills: [DefaultSkill.skill], factory: factory)
            .run("ファイルを全部削除して", reporter: reporter, confirm: { false })

        #expect(denied == .notConfirmed)
        #expect(reporter.kinds == ["fellBack", "confirmRequired", "confirmationDeclined"])
        guard case let .confirmRequired(_, reason) = reporter.events[1] else { Issue.record("confirmRequired ではない"); return }
        #expect(reason == "取り消しにくい操作かもしれないので、確認します")
        #expect(factory.count == 0)

        let approved = try await runner(SkillScorer(routedDescription: nil, destructive: 0.9), skills: [DefaultSkill.skill], factory: factory)
            .run("ファイルを全部削除して", reporter: Recorder(), confirm: { true })
        #expect(approved == .completed && factory.count == 1)
    }

    @Test func aForcedSkillSkipsRoutingButStillConfirms() async throws {
        let factory = Factory()
        let reporter = Recorder()
        // 選ぶ段階がないので、スコアラーは使わない（使えば失敗する）
        let outcome = try await SkillRunner(selection: .forced(skill("spotify", spotifyDescription, confirm: true)), dryRun: false, makeExecutor: factory.factory)
            .run("次の曲", reporter: reporter, confirm: { true })

        #expect(outcome == .completed)
        #expect(reporter.kinds == ["forced", "confirmRequired", "confirmed", "started", "reply"])

        let plain = Recorder()
        _ = try await SkillRunner(selection: .forced(skill("spotify", spotifyDescription)), dryRun: false, makeExecutor: factory.factory)
            .run("次の曲", reporter: plain, confirm: { Issue.record("確認は要らない"); return false })
        #expect(plain.kinds == ["forced", "started", "reply"])
    }

    @Test func dryRunIsPassedToTheExecutorAndTheRunnerStillReportsEverything() async throws {
        let factory = Factory { display in display.onCommand("open -a Spotify"); return "done: 確認だけ" }
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription)], dryRun: true, factory: factory)
            .run("次の曲", reporter: reporter, confirm: { true })

        #expect(outcome == .completed)
        #expect(factory.made.map(\.dryRun) == [true])
        #expect(reporter.kinds == ["matched", "started", "command", "reply"])
    }

    @Test func cancelledBeforeExecutionNeverCallsTheExecutor() async throws {
        let token = CancelToken()
        let factory = Factory()
        let reporter = Recorder()
        // 確認の待ちの間に、Esc で取りやめられた（返事は「はい」）
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription, confirm: true)], cancel: token, factory: factory)
            .run("次の曲", reporter: reporter, confirm: { token.cancel(); return true })

        #expect(outcome == .cancelled)
        #expect(reporter.kinds == ["matched", "confirmRequired", "confirmed", "started", "cancelled"])
        #expect(factory.made.allSatisfy { $0.executor.requests.isEmpty })
    }

    @Test func cancelledDuringExecutionIsCancelledNotFailed() async throws {
        let token = CancelToken()
        // 実行者は、取りやめられると、別のエラーで止まることもある（コマンドが止められた、など）
        struct Interrupted: Error {}
        let factory = Factory { display in display.onCommand("open -a Spotify"); token.cancel(); throw Interrupted() }
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription)], cancel: token, factory: factory)
            .run("次の曲", reporter: reporter, confirm: { true })

        #expect(outcome == .cancelled)
        #expect(reporter.kinds == ["matched", "started", "command", "cancelled"])
    }

    @Test func aCancellationErrorWithoutATokenIsAlsoCancelled() async throws {
        let factory = Factory { _ in throw CancellationError() }
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription)], factory: factory)
            .run("次の曲", reporter: reporter, confirm: { true })
        #expect(outcome == .cancelled && reporter.kinds.last == "cancelled")
    }

    @Test func anExecutorFailureBecomesAFailedEvent() async throws {
        struct ModelDown: Error, CustomStringConvertible { var description: String { "言語モデルが使えない" } }
        let factory = Factory { display in display.onCommand("open -a Spotify"); throw ModelDown() }
        let reporter = Recorder()
        let outcome = try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription)], factory: factory)
            .run("次の曲", reporter: reporter, confirm: { true })

        #expect(outcome == .failed)
        #expect(reporter.kinds == ["matched", "started", "command", "failed"])
        #expect(reporter.events.last == .failed("言語モデルが使えない"))
    }

    @Test func selectionAndConfirmationErrorsAreThrownNotReported() async throws {
        let factory = Factory()
        let reporter = Recorder()
        await #expect(throws: SkillScorer.Broken.self) {
            try await runner(SkillScorer(routedDescription: spotifyDescription, fails: true), skills: [skill("spotify", spotifyDescription)], factory: factory)
                .run("次の曲", reporter: reporter, confirm: { true })
        }
        #expect(reporter.events.isEmpty)

        struct NoAnswer: Error {}
        await #expect(throws: NoAnswer.self) {
            try await runner(SkillScorer(routedDescription: spotifyDescription), skills: [skill("spotify", spotifyDescription, confirm: true)], factory: factory)
                .run("次の曲", reporter: reporter, confirm: { throw NoAnswer() })
        }
        #expect(reporter.kinds == ["matched", "confirmRequired"] && factory.count == 0)
    }
}
