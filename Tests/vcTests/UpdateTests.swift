import Foundation
import Testing
@testable import vc

/// 更新の、画面・通信から分けて確かめられる規則：版の比べ方・リリースの読み方・取得先の検査・SHA-256 の取り出し・入れてよい場所・入れ替え。
@Suite struct UpdateTests {
    // MARK: 版

    @Test func versionsCompareNumericallyAndPadMissingParts() {
        #expect(AppVersion("0.5.10")! > AppVersion("0.5.9")!)             // 文字列ではなく、数で比べる
        #expect(AppVersion("v0.6.0")! > AppVersion("0.5.99")!)
        #expect(AppVersion("0.5")! == AppVersion("0.5.0")!)               // 足りない桁は 0
        #expect(AppVersion("v1.2.3")!.description == "1.2.3")
        for bad in ["", "v", "0..1", "0.5.x", "0.5.7-beta", "1.2.3.4.5", "٣.٤", " "] { #expect(AppVersion(bad) == nil, "読めない：\(bad)") }
    }

    // MARK: リリースの読み方

    private func release(tag: String = "v0.5.8", draft: Bool = false, prerelease: Bool = false, assets: [(String, String)]? = nil) -> Data {
        let base = "https://github.com/takemo101/voice-control/releases/download/\(tag)/"
        let list = assets ?? [("vc-\(tag.dropFirst())-macos-arm64.dmg", base + "vc-\(tag.dropFirst())-macos-arm64.dmg"), ("vc-\(tag.dropFirst())-macos-arm64.dmg.sha256", base + "vc-\(tag.dropFirst())-macos-arm64.dmg.sha256")]
        let json: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": "https://github.com/takemo101/voice-control/releases/tag/\(tag)",
                                    "assets": list.map { ["name": $0.0, "browser_download_url": $0.1] }]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func aPublishedReleaseWithBothAssetsBecomesACandidate() throws {
        let info = try ReleaseFeed.parse(release()).get()
        #expect(info.version == AppVersion("0.5.8") && info.dmgName == "vc-0.5.8-macos-arm64.dmg")
        #expect(info.dmgURL.lastPathComponent == "vc-0.5.8-macos-arm64.dmg" && info.checksumURL.lastPathComponent == "vc-0.5.8-macos-arm64.dmg.sha256")
        #expect(info.pageURL.absoluteString.hasSuffix("/releases/tag/v0.5.8"))
    }

    @Test func draftsPrereleasesBadTagsAndMissingAssetsAreRejectedWithAReason() {
        #expect(ReleaseFeed.parse(release(draft: true)) == .failure(.draftOrPrerelease))
        #expect(ReleaseFeed.parse(release(prerelease: true)) == .failure(.draftOrPrerelease))
        #expect(ReleaseFeed.parse(release(tag: "nightly")) == .failure(.badTag("nightly")))
        #expect(ReleaseFeed.parse(release(assets: [])) == .failure(.missingAsset("vc-0.5.8-macos-arm64.dmg")))
        let onlyDmg = [("vc-0.5.8-macos-arm64.dmg", "https://github.com/takemo101/voice-control/releases/download/v0.5.8/vc-0.5.8-macos-arm64.dmg")]
        #expect(ReleaseFeed.parse(release(assets: onlyDmg)) == .failure(.missingAsset("vc-0.5.8-macos-arm64.dmg.sha256")))   // SHA-256 がなければ、入れない
        #expect(ReleaseFeed.parse(Data("not json".utf8)) == .failure(.notRelease))
    }

    @Test func onlyThisRepositorysReleaseAssetsOverHTTPSAreTrusted() {
        func trusted(_ text: String) -> Bool { ReleaseFeed.isTrusted(URL(string: text)!) }
        #expect(trusted("https://github.com/takemo101/voice-control/releases/download/v0.5.8/a.dmg"))
        #expect(!trusted("http://github.com/takemo101/voice-control/releases/download/v0.5.8/a.dmg"))          // https だけ
        #expect(!trusted("https://github.com.evil.example/takemo101/voice-control/releases/download/v/a.dmg")) // ホストの偽装
        #expect(!trusted("https://github.com/other/repo/releases/download/v0.5.8/a.dmg"))                     // 別のリポジトリ
        #expect(!trusted("https://github.com/takemo101/voice-control/releases/download/../../x/a.dmg"))         // ..
        #expect(!trusted("https://user@github.com/takemo101/voice-control/releases/download/v/a.dmg"))
        // 偽の取得先が JSON にあれば、候補にしない
        let foreign = [("vc-0.5.8-macos-arm64.dmg", "https://evil.example/vc.dmg"), ("vc-0.5.8-macos-arm64.dmg.sha256", "https://evil.example/vc.sha256")]
        if case .success = ReleaseFeed.parse(release(assets: foreign)) { Issue.record("偽の取得先を受けた") }
    }

    @Test func theCheckRunsAtStartupAndThenOnceADay() {
        let now = Date()
        #expect(ReleaseFeed.isDue(lastChecked: nil, now: now))
        #expect(!ReleaseFeed.isDue(lastChecked: now.addingTimeInterval(-3_600), now: now))
        #expect(ReleaseFeed.isDue(lastChecked: now.addingTimeInterval(-ReleaseFeed.checkInterval), now: now))
    }

    // MARK: SHA-256

    @Test func theExpectedHashIsReadFromShasumOutputForTheRightFileOnly() {
        let hash = String(repeating: "ab", count: 32)
        #expect(ChecksumFile.expectedHash(in: "\(hash)  vc-0.5.8-macos-arm64.dmg\n", for: "vc-0.5.8-macos-arm64.dmg") == hash)
        #expect(ChecksumFile.expectedHash(in: "\(hash.uppercased())  a.dmg", for: "a.dmg") == hash)                // 大文字も、小文字に
        #expect(ChecksumFile.expectedHash(in: "\(hash)  other.dmg", for: "a.dmg") == nil)                           // ほかのファイルの行は、使わない
        #expect(ChecksumFile.expectedHash(in: "abc  a.dmg", for: "a.dmg") == nil)                                   // 64 桁でない
        #expect(ChecksumFile.expectedHash(in: "\(String(repeating: "zz", count: 32))  a.dmg", for: "a.dmg") == nil) // 16 進でない
        #expect(ChecksumFile.expectedHash(in: "", for: "a.dmg") == nil)
    }

    // MARK: 入れてよい場所

    @Test func onlyAnAppInApplicationsThatCanBeWrittenToIsReplaced() {
        let home = "/Users/someone"
        func block(_ path: String, writable: Bool = true) -> InstallPlan.Block? { InstallPlan.block(appPath: path, home: home, isWritable: { _ in writable }) }
        #expect(block("/Applications/VoiceControl.app") == nil)
        #expect(block("/Users/someone/Applications/VoiceControl.app") == nil)
        #expect(block("/Users/someone/work/voice-control/build/VoiceControl.app") == .unusualLocation("/Users/someone/work/voice-control/build/VoiceControl.app"))   // 開発のビルドを、潰さない
        #expect(block("/Volumes/voice-control/VoiceControl.app") == .unusualLocation("/Volumes/voice-control/VoiceControl.app"))                                     // ディスクイメージの中
        #expect(block("/private/var/folders/x/AppTranslocation/ABC/d/VoiceControl.app") == .translocated)
        #expect(block("/Applications/VoiceControl.app", writable: false) == .notWritable("/Applications"))
        #expect(block("/usr/local/bin/vc") == .notAnApp)
        #expect(InstallPlan.stagedPath(for: "/Applications/VoiceControl.app") == "/Applications/.VoiceControl-update.app")
    }

    // MARK: 入れ替え（実際の /bin/sh で、一時のフォルダの中を）

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func app(_ root: URL, _ name: String, version: String) throws -> String {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try version.write(to: dir.appendingPathComponent("Contents/version"), atomically: true, encoding: .utf8)
        return dir.path
    }

    private func version(of app: String) -> String? { try? String(contentsOfFile: app + "/Contents/version", encoding: .utf8) }

    private func swap(staged: String, target: String, pid: Int32, opener: String = "/usr/bin/true") -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = UpdateSwap.arguments(pid: pid, staged: staged, target: target, backup: InstallPlan.backupPath(for: target), opener: opener, background: false)
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func theSwapReplacesTheAppWithTheNewOneAndLeavesNoBackup() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try app(root, "VoiceControl.app", version: "old")
        let staged = try app(root, ".VoiceControl-update.app", version: "new")
        // 待つ相手は、すでに終わっているプロセス（番号 0 は、`kill -0` が失敗する：存在しない番号として、十分に大きい値を使う）
        #expect(swap(staged: staged, target: target, pid: 2_000_000) == 0)
        #expect(version(of: target) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged) && !FileManager.default.fileExists(atPath: InstallPlan.backupPath(for: target)))
    }

    @Test func ifTheNewAppCannotBePlacedTheOldOneIsRestored() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try app(root, "VoiceControl.app", version: "old")
        let missing = root.appendingPathComponent(".VoiceControl-update.app").path   // 置く新しいアプリが、ない
        #expect(swap(staged: missing, target: target, pid: 2_000_000) == 3)
        #expect(version(of: target) == "old")                                         // 元に戻っている
        #expect(!FileManager.default.fileExists(atPath: InstallPlan.backupPath(for: target)))
    }

    @Test func theSwapWaitsForTheRunningAppToEndAndTouchesNothingIfItNeverDoes() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try app(root, "VoiceControl.app", version: "old")
        let staged = try app(root, ".VoiceControl-update.app", version: "new")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
        try sleeper.run(); defer { sleeper.terminate() }
        // 終わらない相手を待つ間は、何も変えない：スクリプトは、待っている（このテストは、待ちを、短い別プロセスで確かめる）
        let waiting = Process()
        waiting.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiting.arguments = UpdateSwap.arguments(pid: sleeper.processIdentifier, staged: staged, target: target, backup: InstallPlan.backupPath(for: target), opener: "/usr/bin/true", background: false)
        try waiting.run()
        Thread.sleep(forTimeInterval: 1.0)
        #expect(waiting.isRunning && version(of: target) == "old")          // 相手が生きている間は、待つだけ
        sleeper.terminate(); sleeper.waitUntilExit()
        waiting.waitUntilExit()
        #expect(waiting.terminationStatus == 0 && version(of: target) == "new")   // 終わったら、入れ替える
    }

    @Test func theBackgroundLaunchReturnsAtOnceAndTheInnerShellFinishesTheSwapAfterTheAppEnds() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try app(root, "VoiceControl.app", version: "old")
        let staged = try app(root, ".VoiceControl-update.app", version: "new")
        let app = Process()   // 「いまのアプリ」の代わり：少しして終わる
        app.executableURL = URL(fileURLWithPath: "/bin/sleep"); app.arguments = ["1"]
        try app.run()
        let outer = Process()
        outer.executableURL = URL(fileURLWithPath: "/bin/sh")
        outer.arguments = UpdateSwap.arguments(pid: app.processIdentifier, staged: staged, target: target, backup: InstallPlan.backupPath(for: target), opener: "/usr/bin/true", background: true)
        try outer.run(); outer.waitUntilExit()
        #expect(outer.terminationStatus == 0 && version(of: target) == "old")   // 外側は、すぐ戻る。まだ、入れ替わっていない
        app.waitUntilExit()
        for _ in 0..<50 where version(of: target) != "new" { Thread.sleep(forTimeInterval: 0.1) }
        #expect(version(of: target) == "new")                                   // 相手が終わったあと、背景の内側が、入れ替える
    }

    @Test func pathsWithSpacesAndQuotesAreHandledBecauseTheyArePassedAsArgumentsNotEmbedded() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try app(root, "Voice Control \"x\" $HOME.app", version: "old")
        let staged = try app(root, ".stage; touch pwned.app", version: "new")
        #expect(swap(staged: staged, target: target, pid: 2_000_000) == 0)
        #expect(version(of: target) == "new" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("pwned.app").path))
    }
}
