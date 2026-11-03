import Foundation
import TestSupport
@testable import VCSkill
import VCCore
import VCDecision

// `SkillRunnerTests` が使う偽物。

/// 届いた出来事を、順に覚える。
final class Recorder: RunReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [RunEvent] = []
    func report(_ event: RunEvent) { lock.lock(); all.append(event); lock.unlock() }
    var events: [RunEvent] { lock.lock(); defer { lock.unlock() }; return all }

    /// 時間（`elapsed`）と細部を除いた、出来事の種類の並び。
    var kinds: [String] {
        events.map { event in
            switch event {
            case .forced: "forced"
            case .matched: "matched"
            case .fellBack: "fellBack"
            case .declined: "declined"
            case .confirmRequired: "confirmRequired"
            case .confirmationDeclined: "confirmationDeclined"
            case .confirmed: "confirmed"
            case .started: "started"
            case .command: "command"
            case .result: "result"
            case .denied: "denied"
            case .reply: "reply"
            case .failed: "failed"
            case .cancelled: "cancelled"
            }
        }
    }
}

/// 偽の実行者：渡された台本を、実行者の役で動かす（コマンドを知らせ、返事を返す）。
final class FakeExecutor: SkillExecuting, @unchecked Sendable {
    let executedCommands: [String] = []
    private let display: ExecutionDisplay
    private let script: @Sendable (ExecutionDisplay) async throws -> String
    private let lock = NSLock()
    private var ran: [String] = []

    init(display: ExecutionDisplay, script: @escaping @Sendable (ExecutionDisplay) async throws -> String) {
        self.display = display; self.script = script
    }

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return ran }

    func run(request: String) async throws -> String {
        lock.withLock { ran.append(request) }
        return try await script(display)
    }
}

/// 実行者の作られ方（どのスキルで・dry-run か）と、作った実行者を覚える。
final class Factory: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(skill: String, dryRun: Bool, executor: FakeExecutor)] = []
    private let script: @Sendable (ExecutionDisplay) async throws -> String

    init(script: @escaping @Sendable (ExecutionDisplay) async throws -> String = { _ in "done: ok" }) {
        self.script = script
    }

    var made: [(skill: String, dryRun: Bool, executor: FakeExecutor)] { lock.lock(); defer { lock.unlock() }; return all }
    var count: Int { made.count }

    var factory: SkillRunner.ExecutorFactory {
        { [self] skill, dryRun, display, _ in
            let executor = FakeExecutor(display: display, script: script)
            lock.lock(); all.append((skill.name, dryRun, executor)); lock.unlock()
            return executor
        }
    }
}

/// テストの中で、値を共有する（実行者のスレッドからも触るので、ロックで守る）。
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

let spotifyDescription = "Spotify の操作"

func runner(
    _ scorer: SkillScorer, skills: [Skill], gate: Gate = Gate(), dryRun: Bool = false, cancel: CancelToken? = nil, factory: Factory
) -> SkillRunner {
    SkillRunner(selection: .resolve(skills: skills, scorer: scorer, gate: gate), dryRun: dryRun, cancel: cancel, makeExecutor: factory.factory)
}
