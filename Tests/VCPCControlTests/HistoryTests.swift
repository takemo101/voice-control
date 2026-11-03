import Foundation
import Testing
@testable import VCPCControl

@Suite struct HistoryTests {
    private let area = UIElement(ref: "@a:e1", role: "scrollarea", name: "notes", actions: ["Scroll"])

    @Test func inversesPairUp() {
        #expect(Step.scroll(.down, area).inverse == .scroll(.up, area))
        #expect(Step.window(.maximize, app: "A").inverse == .window(.restore, app: "A"))
        #expect(Step.window(.restore, app: "A").inverse == .window(.maximize, app: "A"))
        #expect(Step.press(Shortcut.all.first { $0.combo == "cmd+z" }!).inverse == .press(Shortcut.all.first { $0.combo == "cmd+shift+z" }!))
        #expect(Step.openApp("A").inverse == nil)
    }

    @Test func reboundFindsTheSameElementInANewSnapshot() {
        let old = UIElement(ref: "@old:e3", role: "button", name: "Save", actions: ["Click"])
        let fresh = UIElement(ref: "@new:e9", role: "button", name: "Save", actions: ["Click"])
        let snapshot = Snapshot(app: "A", elements: [UIElement(ref: "@new:e1", role: "button", name: "Cancel", actions: ["Click"]), fresh])
        #expect(Step.click(old).rebound(to: snapshot) == .click(fresh))
        #expect(Step.click(UIElement(ref: "@old:e4", role: "button", name: "Gone", actions: ["Click"])).rebound(to: snapshot) == nil)
        #expect(Step.type(text: "secret", into: old).rebound(to: snapshot) == nil)   // 入れる文字は、繰り返さない
    }

    @Test func dropsOldEntriesAndKeepsTheNewest() {
        let now = Date()
        let step = Step.openApp("A")
        let entries = [Executed(step: step, at: now.addingTimeInterval(-500))] + (0..<5).map { Executed(step: .openApp("B\($0)"), at: now.addingTimeInterval(Double(-$0))) }.reversed()
        let recent = History.recent(entries, now: now)
        #expect(recent.count == History.maxCount)
        #expect(!recent.contains { $0.step == step })
        #expect(recent.last?.step == .openApp("B0"))
    }
}
