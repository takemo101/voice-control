import Foundation
@testable import VCPCControl

// `PCRunnerTests` が使う偽物（偽の `Desktop`・`OptionScorer` は `TestSupport`）。

/// 出来事を、短い文字にして集める。
final class Recorder: PCReporter {
    private(set) var tags: [String] = []

    func report(_ event: PCEvent) {
        switch event {
        case .llmSplit, .llmSplitFailed: tags.append("split")
        case let .clause(i, n, _): tags.append("clause \(i)/\(n)")
        case .planned: tags.append("planned")
        case let .rejected(_, cancels): tags.append("rejected" + (cancels ? "+cancels" : ""))
        case .planOnly: tags.append("planOnly")
        case .dryRun: tags.append("dryRun")
        case .confirmRequired: tags.append("confirmRequired")
        case let .confirmAnswered(approved): tags.append("answered \(approved)")
        case let .notConfirmed(_, cancels): tags.append("notConfirmed" + (cancels ? "+cancels" : ""))
        case .executing: tags.append("executing")
        case .executed: tags.append("executed")
        }
    }
}
