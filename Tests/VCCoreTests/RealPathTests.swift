import Foundation
import Testing
@testable import VCCore

/// 場所の、実際の形：リンクを解く・まだない場所も扱う・`/var` と `/private/var` を取り違えない。
@Suite struct RealPathTests {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vc-realpath-\(UUID().uuidString)")   // /var/folders/…（実際は /private/var/…）
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func existingPlacesAreResolvedAndMissingOnesAreNil() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let resolved = try #require(RealPath.existing(base.path))
        #expect(resolved.hasPrefix("/private/var/") || resolved.hasPrefix("/private/"))   // /var は、/private/var へ
        #expect(RealPath.existing(base.appendingPathComponent("missing").path) == nil)
    }

    @Test func aPlaceThatDoesNotExistYetIsResolvedThroughItsExistingParent() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let parent = try #require(RealPath.existing(base.path))
        #expect(RealPath.eventual(base.appendingPathComponent("new/deep/a.txt").path) == parent + "/new/deep/a.txt")   // これから作る場所：親は実際の形・残りは、つなぐ
        #expect(RealPath.eventual(base.path + "/x/../y.txt") == parent + "/y.txt")                                      // `..` は、整える
    }

    @Test func symlinksAreFollowedAndInsideMeansTheRealLocationIsUnderTheRoot() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let work = base.appendingPathComponent("work"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("link"), withDestinationURL: outside)
        let root = try #require(RealPath.existing(work.path))
        #expect(RealPath.isInside(RealPath.eventual(work.appendingPathComponent("a.txt").path), root: root))
        #expect(!RealPath.isInside(RealPath.eventual(work.path + "/link/b.txt"), root: root))   // リンク越しの外は、外
        #expect(RealPath.isInside(root, root: root) && !RealPath.isInside(root + "x", root: root))   // 前方一致の取り違え（`/a/work` と `/a/workx`）をしない
    }
}
