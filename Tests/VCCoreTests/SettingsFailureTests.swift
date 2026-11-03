import Foundation
import Testing
@testable import VCCore

/// 壊れた settings.json を、黙って空にしない（そのあとの保存が、信頼・無効化の設定を消すため）。
@Suite struct SettingsFailureTests {
    private func tempFile(_ contents: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        if let contents { try Data(contents.utf8).write(to: file) }
        return file
    }

    @Test func missingFileIsAnEmptySettingsNotAnError() throws {
        let file = try tempFile(nil)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(try Settings.load(from: file) == Settings())
        #expect(Settings.loadOrDefault(from: file).problem == nil)
    }

    @Test func corruptFileIsReportedAndReadsAsNoTrust() throws {
        let file = try tempFile("{ this is not json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(throws: Settings.Unreadable.self) { try Settings.load(from: file) }

        let (settings, problem) = Settings.loadOrDefault(from: file)
        #expect(problem != nil)
        #expect(settings == Settings())                                   // 読み取りだけなら、空の設定で続ける
        #expect(!settings.isTrusted(project: file.deletingLastPathComponent()))   // 信頼は、なし（安全側。空の設定でも保証する）
    }

    @Test func saveRefusesToOverwriteACorruptFileAndLeavesItUntouched() throws {
        let broken = "{ trusted: oops"
        let file = try tempFile(broken)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        var settings = Settings()
        settings.setEnabled("a", false)
        #expect(throws: Settings.Unreadable.self) { try settings.save(to: file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)   // 元のファイルは、そのまま
    }

    @Test func saveRefusesWhileBrokenThenWorksOnceTheFileIsFixed() throws {
        let file = try tempFile("{ broken")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        var pending = Settings()
        pending.setEnabled("b", false)
        #expect(throws: Settings.Unreadable.self) { try pending.save(to: file) }   // 壊れている間は、保存できない

        try Data(#"{"disabledSkills":["keep"]}"#.utf8).write(to: file)   // 利用者が直した
        var settings = try Settings.load(from: file)
        settings.setEnabled("b", false)
        try settings.save(to: file)
        #expect(try Settings.load(from: file).disabledSkills == ["b", "keep"])   // 直したファイルの中身を、消さずに足せた
    }
}
