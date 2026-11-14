import Foundation
import Testing
@testable import vc

/// 起動の入口の判断と、コマンド `vc`（アプリへのリンク）の状態。管理者の権限は、偽物。
@Suite struct AppLaunchTests {
    private let inApp = "/Applications/VoiceControl.app/Contents/MacOS/vc"

    @Test func noArgumentsInsideTheAppMeansTheMenuBarAppAndFromATerminalItOpensTheApp() {
        #expect(AppLaunch.mode(arguments: [], executablePath: inApp, isTerminal: false) == .gui)
        #expect(AppLaunch.mode(arguments: ["-psn_0_12345"], executablePath: inApp, isTerminal: false) == .gui)
        #expect(AppLaunch.mode(arguments: [], executablePath: inApp, isTerminal: true) == .openApp(bundle: "/Applications/VoiceControl.app"))
    }

    @Test func argumentsAlwaysMeanTheCLIAndABareBinaryOutsideAnAppKeepsTheOverview() {
        #expect(AppLaunch.mode(arguments: ["show", "--title", "x"], executablePath: inApp, isTerminal: true) == .cli(["show", "--title", "x"]))
        #expect(AppLaunch.mode(arguments: ["--version"], executablePath: inApp, isTerminal: false) == .cli(["--version"]))
        #expect(AppLaunch.mode(arguments: [], executablePath: "/tmp/.build/release/vc", isTerminal: true) == .cli([]))   // ビルドしたままの vc：これまでどおり（一覧を出す）
        #expect(AppLaunch.mode(arguments: [], executablePath: nil, isTerminal: false) == .cli([]))
    }

    @Test func theBundlePathComesFromTheOutermostAppInThePath() {
        #expect(AppLaunch.bundlePath(forExecutable: "/Users/a/My Apps/VoiceControl.app/Contents/MacOS/vc") == "/Users/a/My Apps/VoiceControl.app")
        #expect(AppLaunch.bundlePath(forExecutable: "/usr/local/bin/vc") == nil)
    }

    // MARK: コマンド vc

    private func makeDirs() throws -> (link: String, target: String, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        let app = dir.appendingPathComponent("Apps/VoiceControl.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let target = app.appendingPathComponent("vc")
        try Data("x".utf8).write(to: target)
        return (bin.appendingPathComponent("vc").path, target.resolvingSymlinksInPath().path, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test func installingLinksToTheAppAndUninstallRemovesOnlyOurLink() throws {
        let d = try makeDirs(); defer { d.cleanup() }
        let tool = CommandLineTool(linkPath: d.link, target: d.target, runAsAdministrator: { _ in "管理者は、呼ばれないはず" })
        #expect(tool.state == .notInstalled)
        #expect(tool.install() == nil)
        #expect(tool.state == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: d.link) == d.target)
        #expect(tool.uninstall() == nil)
        #expect(tool.state == .notInstalled)
    }

    @Test func anotherThingAtTheLinkPathIsNeverOverwrittenOrRemoved() throws {
        let d = try makeDirs(); defer { d.cleanup() }
        try Data("old".utf8).write(to: URL(fileURLWithPath: d.link))   // 以前の vc（tar.gz で入れたもの）
        let tool = CommandLineTool(linkPath: d.link, target: d.target, runAsAdministrator: { _ in nil })
        #expect(tool.state == .other(d.link))
        #expect(tool.install()?.contains("上書きしません") == true)
        #expect(tool.uninstall() == nil)
        #expect(FileManager.default.contents(atPath: d.link) == Data("old".utf8))
    }

    @Test func aLinkToAMovedAppIsStaleAndGetsReplaced() throws {
        let d = try makeDirs(); defer { d.cleanup() }
        try FileManager.default.createSymbolicLink(atPath: d.link, withDestinationPath: "/Applications/Gone.app/Contents/MacOS/vc")
        let tool = CommandLineTool(linkPath: d.link, target: d.target, runAsAdministrator: { _ in nil })
        #expect(tool.state == .stale("/Applications/Gone.app/Contents/MacOS/vc"))
        #expect(tool.install() == nil && tool.state == .installed)
    }

    @Test func withoutAStableAppLocationNothingCanBeInstalled() {
        let tool = CommandLineTool(linkPath: "/tmp/never", target: nil, runAsAdministrator: { _ in nil })
        #expect(tool.state == .unavailable)
        #expect(tool.install()?.contains("アプリケーション") == true)
    }

    @Test func anUnwritableDirectoryAsksForAdministratorWithAQuotedScript() throws {
        let received = Box()
        let tool = CommandLineTool(linkPath: "/nonexistent-dir/it's/vc", target: "/Applications/VoiceControl.app/Contents/MacOS/vc", runAsAdministrator: { received.script = $0; return nil })
        #expect(tool.install() == nil)
        #expect(received.script == "mkdir -p '/nonexistent-dir/it'\\''s' && ln -s '/Applications/VoiceControl.app/Contents/MacOS/vc' '/nonexistent-dir/it'\\''s/vc'")
    }

    private final class Box: @unchecked Sendable { var script = "" }
}
