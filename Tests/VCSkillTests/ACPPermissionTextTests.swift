import Foundation
import Testing
@testable import VCSkill

/// 確認の文（表示用）：実際の場所・コマンド・見えない文字の可視化。
@Suite struct ACPPermissionTextTests {
    private let folder = URL(fileURLWithPath: "/tmp/vc-acp-folder")

    @Test func hiddenAndDirectionChangingCharactersInAConfirmationAreMadeVisible() {
        let run = ACPToolCall(kind: "execute", command: "echo safe\u{202E}evil\u{200B}\nrm -rf x")
        #expect(ACPPermissionText.detail(run, folder: folder) == "コマンドを実行する：echo safe⟨U+202E⟩evil⟨U+200B⟩ rm -rf x")
        let long = ACPToolCall(kind: "execute", command: String(repeating: "a", count: 700))
        let lines = ACPPermissionText.detail(long, folder: folder).components(separatedBy: "\n")
        #expect(lines.count == 2 && lines[0].contains("全 700 文字") && lines[1].hasSuffix("…（残り 560 文字は、略しています）"))   // 長いコマンドは、見出しと抜粋に分け、残りの長さを示す
    }

    @Test func theConfirmationShowsTheRealPathRelativeToTheFolderAndMarksOutsidePaths() {
        func edit(_ path: String, kind: String = "edit") -> ACPToolCall { ACPToolCall(kind: kind, title: "File ../../x", path: path) }
        #expect(ACPPermissionText.detail(edit("/tmp/vc-acp-folder/notes/a.txt"), folder: folder) == "ファイルを書き込む：notes/a.txt")
        #expect(ACPPermissionText.detail(edit("/tmp/vc-acp-folder", kind: "delete"), folder: folder) == "ファイルを削除する：.")
        let outside = ACPPermissionText.detail(edit("/etc/hosts"), folder: folder)
        #expect(outside.hasPrefix("ファイルを書き込む：/") && outside.contains("etc/hosts") && outside.hasSuffix("（作業フォルダの外）"))   // 実際の場所（/private/etc/hosts）を、見せる
        #expect(ACPPermissionText.detail(edit("/tmp/vc-acp-folder/../vc-acp-other/b.txt"), folder: folder).hasSuffix("（作業フォルダの外）"))   // ../ で、外へ出る道は、外
        #expect(ACPPermissionText.detail(ACPToolCall(kind: "execute", title: "Run", command: "ls -la"), folder: folder) == "コマンドを実行する：ls -la")
        #expect(ACPPermissionText.detail(ACPToolCall(kind: "execute", title: "Run something"), folder: folder) == "コマンドを実行する：Run something")   // 場所・コマンドがなければ、題
    }

    @Test func pathsAreComparedByTheirRealLocationEvenForFilesThatDoNotExistYetAndThroughSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vc-acp-path-\(UUID().uuidString)")   // /var/folders/…（実際は /private/var/…）
        let folder = base.appendingPathComponent("work"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = "/private" + folder.path   // エージェントが返す、実際の場所（まだないファイル）
        #expect(ACPPermissionText.displayPath(real + "/new/a.txt", folder: folder) == "new/a.txt")                 // これから作る・深い場所でも、中
        #expect(ACPPermissionText.displayPath(folder.appendingPathComponent("b.txt").path, folder: folder) == "b.txt")   // /var の形でも、中
        #expect(ACPPermissionText.displayPath(folder.path + "/link/c.txt", folder: folder).hasSuffix("（作業フォルダの外）"))   // 中のリンク越しの外は、外
        #expect(ACPPermissionText.displayPath(outside.appendingPathComponent("d.txt").path, folder: folder).hasSuffix("（作業フォルダの外）"))
    }

    @Test func activitiesShowFolderSearchesAsReadsAndHideThinking() {
        #expect(ACPPermissionText.activity(ACPToolCall(kind: "think")) == nil)
        #expect(ACPPermissionText.activity(ACPToolCall(kind: "search", name: "grep", title: "foo")) == .read("foo"))      // grep：フォルダの中を読む
        #expect(ACPPermissionText.activity(ACPToolCall(kind: "search", name: "websearch", title: "swift")) == .search("swift"))
        #expect(ACPPermissionText.activity(ACPToolCall(kind: "edit", title: "a.txt")) == .write("a.txt"))
        #expect(ACPPermissionText.activity(ACPToolCall(kind: "execute", title: "ls")) == .run("ls"))
    }
}
