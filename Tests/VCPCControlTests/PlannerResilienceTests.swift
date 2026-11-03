import Foundation
import Testing
import TestSupport
@testable import VCPCControl

@Suite struct PlannerResilienceTests {
    @Test func stillOpensAnAppWhenTheScreenCannotBeRead() throws {
        let plan = try Planner(scorer: TargetScorer(target: "アプリを開く: Spotify", others: 0.001), desktop: StaticDesktop(installedApps: ["Spotify"], snapshotError: SnapshotError.notOK(code: "INTERNAL"))).plan("Spotifyを開いて")
        #expect(plan.step == .openApp("Spotify"))
        #expect(plan.note?.contains("INTERNAL") == true)
    }
}
