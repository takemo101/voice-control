import Foundation
import Testing
@testable import VCDecision
import VCCore

/// 「target」と書かれた選択肢に確率を寄せる偽物。呼ばれた回数と、1 回の選択肢の最大数を記録する。
private final class FakeScorer: OptionScorer, @unchecked Sendable {
    let target: String?
    private(set) var calls = 0
    private(set) var widest = 0
    init(target: String?) { self.target = target }
    func score(state: String, question: String, options: [String]) throws -> [Double] {
        calls += 1
        widest = max(widest, options.count)
        let hit = options.firstIndex { $0 == target }
        var p = options.map { _ in 0.01 }
        p[hit ?? options.count - 1] = 0.9   // 該当がなければ、最後（「該当なし」）へ
        let sum = p.reduce(0, +)
        return p.map { $0 / sum }
    }
}

@Suite struct ModelStoreTests {
    private func makeSource(_ contents: [String: String]) throws -> (dir: URL, spec: ModelSpec) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [ModelFile] = []
        for (name, text) in contents.sorted(by: { $0.key < $1.key }) {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            files.append(ModelFile(name: name, bytes: Int64(text.utf8.count), sha256: try ModelStore.sha256(of: url)))
        }
        return (dir, ModelSpec(name: "test", baseURL: dir, files: files))
    }

    @Test func downloadsVerifiesAndSkipsWhatAlreadyMatches() async throws {
        let (source, spec) = try makeSource(["a.json": "{}", "b.bin": String(repeating: "x", count: 3_000_000)])
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("vc-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }

        try await ModelStore.download(spec, to: dest) { _ in }
        #expect(ModelStore.isInstalled(spec, in: dest))
        #expect(spec.files.allSatisfy { ModelStore.verify($0, in: dest) })
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("b.bin.part").path))

        // 一致しているものは、取り直さない（出どころを消しても、成功する）
        try FileManager.default.removeItem(at: source)
        try await ModelStore.download(spec, to: dest) { _ in }
    }

    @Test func corruptDownloadIsRejectedAndLeavesNothingInstalled() async throws {
        let (source, good) = try makeSource(["a.json": "hello"])
        let bad = ModelSpec(name: "test", baseURL: good.baseURL, files: [ModelFile(name: "a.json", bytes: 5, sha256: String(repeating: "0", count: 64))])
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("vc-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }

        await #expect(throws: ModelStoreError.self) { try await ModelStore.download(bad, to: dest) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.json").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.json.part").path))
    }

    @Test func replacesAWrongSizedFile() async throws {
        let (source, spec) = try makeSource(["a.json": "hello"])
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("vc-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: dest.appendingPathComponent("a.json"))
        #expect(ModelStore.state(of: spec.files[0], in: dest) == .wrongSize(9))

        try await ModelStore.download(spec, to: dest) { _ in }
        #expect(ModelStore.verify(spec.files[0], in: dest))
    }
}

@Suite struct ChooserTests {
    private let options = (0..<100).map { "option \($0)" }

    @Test func findsTheTargetAmongMoreCandidatesThanOneCallAccepts() throws {
        for target in [0, 30, 31, 62, 99] {
            let scorer = FakeScorer(target: "option \(target)")
            let pick = try Chooser(scorer: scorer, limit: 32).pick(state: "", question: "", options: options, none: "none")
            #expect(pick.index == target)
            #expect(scorer.widest <= 32)
        }
    }

    @Test func returnsNoneWhenNoCandidateMatches() throws {
        let scorer = FakeScorer(target: nil)
        let pick = try Chooser(scorer: scorer, limit: 32).pick(state: "", question: "", options: options, none: "none")
        #expect(pick.index == nil)
    }

    @Test func roundCountIsAnUpperBoundOnTheCallsMade() throws {
        for count in [1, 31, 32, 100, 961, 962] {
            let scorer = FakeScorer(target: "option 0")
            let opts = (0..<count).map { "option \($0)" }
            let chooser = Chooser(scorer: scorer, limit: 32)
            _ = try chooser.pick(state: "", question: "", options: opts, none: "none")
            #expect(scorer.calls <= chooser.rounds(for: count), "count \(count)")
            if count <= 31 { #expect(scorer.calls == 1) }
        }
    }
}

@Suite struct GateTests {
    @Test func executesOnlyConfidentHarmlessSteps() {
        let gate = Gate()
        #expect(gate.verdict(stages: [0.95], destructive: 0.1, forceConfirm: false) == .execute)
        #expect(gate.verdict(stages: [0.95, 0.60], destructive: nil, forceConfirm: false) == .confirm)
        #expect(gate.verdict(stages: [0.95, 0.30], destructive: nil, forceConfirm: false) == .reject)
    }

    @Test func riskyOrForcedStepsAlwaysNeedConfirmation() {
        let gate = Gate()
        #expect(gate.verdict(stages: [0.999], destructive: 0.9, forceConfirm: false) == .confirm)
        #expect(gate.verdict(stages: [0.999], destructive: nil, forceConfirm: true) == .confirm)
        #expect(gate.verdict(stages: [0.30], destructive: 0.9, forceConfirm: true) == .reject)
    }
}
