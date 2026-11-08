import Foundation
import Testing
@testable import VCCore

/// いまのスクリーンショット：自分だけが読める・1 枚だけ・古くなったら使わない・終了で消す。
@Suite struct ScreenshotStoreTests {
    private func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString)") }
    private func source(in dir: URL, _ text: String = "x") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s-\(UUID().uuidString).png")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func aNewShotReplacesTheOldOneAndOnlyTheOwnerCanRead() throws {
        let dir = temp(), scratch = temp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: scratch) }
        try ScreenshotStore.replace(with: source(in: scratch, "first"), directory: dir)
        try ScreenshotStore.replace(with: source(in: scratch, "second"), directory: dir)
        let url = try ScreenshotStore.current(directory: dir).get()
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        let file = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(file == 0o600 && folder == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)   // 元のファイルは、移した（残さない）
    }

    @Test func missingAndExpiredShotsAreNotUsed() throws {
        let dir = temp(), scratch = temp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: scratch) }
        #expect(ScreenshotStore.current(directory: dir) == .failure(.none))
        try ScreenshotStore.replace(with: source(in: scratch), directory: dir)
        #expect((try? ScreenshotStore.current(directory: dir).get()) != nil)
        let later = Date().addingTimeInterval(ScreenshotStore.timeToLive + 30)
        guard case let .failure(.expired(seconds)) = ScreenshotStore.current(now: later, directory: dir) else { Issue.record("古いはず"); return }
        #expect(seconds >= Int(ScreenshotStore.timeToLive))
    }

    @Test func clearRemovesTheShot() throws {
        let dir = temp(), scratch = temp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: scratch) }
        try ScreenshotStore.replace(with: source(in: scratch), directory: dir)
        ScreenshotStore.clear(directory: dir)
        #expect(ScreenshotStore.current(directory: dir) == .failure(.none))
    }
}
