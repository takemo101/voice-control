import Foundation
import Testing
@testable import VoiceControlKit
import VCCore

@Suite struct HotKeySpecTests {
    private func parsed(_ text: String) throws -> HotKeySpec { try HotKeySpec.parse(text).get() }
    private func reason(_ text: String) -> String? {
        if case let .failure(f) = HotKeySpec.parse(text) { return f.reason }
        return nil
    }

    @Test func modifierOnlyIsAHold() throws {
        let shift = try parsed("shift")
        #expect(shift.isHold && shift == .default)
        let combo = try parsed("Ctrl + Opt")
        #expect(combo.isHold)
        #expect(combo.description == "ctrl+opt")
    }

    @Test func modifiersPlusKeyIsACombination() throws {
        let spec = try parsed("cmd+shift+R")
        #expect(!spec.isHold)
        #expect(spec.keyCode != nil)
        #expect(spec.description == "shift+cmd+r")  // 正規化：ctrl・opt・shift・cmd の順
    }

    @Test func legacyDashFormAndAliases() throws {
        #expect(try parsed("ctrl-opt-space") == parsed("control+alt+space"))
        #expect(try parsed("cmd+enter") == parsed("command+return"))
    }

    @Test func functionKeyMayStandAlone() throws {
        #expect(try parsed("f5").description == "f5")
    }

    @Test func rejectsWhatWouldStealTyping() {
        #expect(reason("r") != nil)       // 修飾キーなしの文字
        #expect(reason("space") != nil)
        #expect(reason("shift+a+b") != nil)  // キーが 2 つ
        #expect(reason("ctrl+") != nil)
        #expect(reason("") != nil)
        #expect(reason("ctrl+nope") != nil)
    }

    @Test func settingsFallBackToShiftAndReportBadValues() throws {
        var s = Settings()
        #expect(try s.hotkeySpec.get() == .default)
        s.hotkey = "ctrl+opt+space"
        #expect(try s.hotkeySpec.get().description == "ctrl+opt+space")
        s.hotkey = "bogus+"
        #expect(throws: HotKeySpec.Failure.self) { try s.hotkeySpec.get() }
    }

    @Test func oldSettingsFileWithoutHotkeyStillLoads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"disabledSkills":["a"]}"#.utf8).write(to: file)
        let s = try Settings.load(from: file)
        #expect(s.disabledSkills == ["a"] && s.hotkey == nil)
        var next = s
        next.hotkey = "f5"
        try next.save(to: file)
        #expect(try Settings.load(from: file) == next)
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
