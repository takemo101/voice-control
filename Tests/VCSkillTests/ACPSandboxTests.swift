import Foundation
import Testing
import VCCore
@testable import VCSkill

/// OS の制限（Seatbelt）：設定の中身（純粋）と、**実際に動かして**、書き込みが、作業フォルダだけに限られること。
@Suite struct ACPSandboxTests {
    private let home = "/Users/someone"

    @Test func onlyTheAllLevelMayWriteInTheFolderAndKeysAreUnreadable() {
        let folder = URL(fileURLWithPath: "/tmp/vc-sandbox-folder")
        let all = ACPSandbox.profile(agent: .opencode, level: .all, folder: folder, home: home)
        #expect(all.contains("(deny file-write*)"))
        #expect(all.contains(RealPath.eventual(folder.path)))                    // 「すべて」：作業フォルダに、書ける
        for level in [ChatToolLevel.none, .web, .read] {
            #expect(!ACPSandbox.profile(agent: .opencode, level: level, folder: folder, home: home).contains(RealPath.eventual(folder.path)))   // ほかは、フォルダにも、書けない
        }
        #expect(all.contains("\(home)/.local/share/opencode") && !all.contains(".gemini"))                // エージェント自身の置き場
        #expect(ACPSandbox.profile(agent: .agy, level: .read, folder: folder, home: home).contains("\(home)/.gemini"))
        #expect(all.contains("(deny file-read*") && all.contains("\(home)/.ssh") && all.contains("\(home)/.aws") && all.contains("\(home)/.gnupg"))
        #expect(ACPSandbox.applies(to: .agy) && ACPSandbox.applies(to: .opencode) && ACPSandbox.applies(to: .claude) && ACPSandbox.applies(to: .codex) && !ACPSandbox.applies(to: .grok) && !ACPSandbox.applies(to: .pi))
    }

    @Test func quotesInAPathCannotBreakOutOfTheProfile() {
        let folder = URL(fileURLWithPath: "/tmp/a\"b)(allow file-write* (subpath \"/\"))")
        let profile = ACPSandbox.profile(agent: .opencode, level: .all, folder: folder, home: home)
        #expect(!profile.contains("(subpath \"/\")"))   // 逃がされて、ただの文字になる
    }

    @Test func aWrappedProcessCanWriteInTheFolderButNotOutside() throws {
        // この環境で、sandbox-exec が使えるか（すでに制限の中だと、重ねられない）：使えなければ、確かめない
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: ACPSandbox.executable); probe.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
        probe.standardError = Pipe(); guard (try? probe.run()) != nil else { return }; probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }
        let base = URL(fileURLWithPath: "/private/tmp/vc-sbx-\(UUID().uuidString)")   // 一時フォルダ（/private/var/folders）は、書ける場所なので、使わない
        let folder = base.appendingPathComponent("work"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func run(level: ChatToolLevel, target: URL) throws -> Int32 {
            let argv = ACPSandbox.wrap(["/bin/sh", "-c", "echo hi > '\(target.path)'"], agent: .opencode, level: level, folder: folder)
            let process = Process(); process.executableURL = URL(fileURLWithPath: argv[0]); process.arguments = Array(argv.dropFirst())
            process.standardError = Pipe(); try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run(level: .all, target: folder.appendingPathComponent("in.txt")) == 0)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("in.txt").path))
        #expect(try run(level: .all, target: outside.appendingPathComponent("out.txt")) != 0)                       // 外へは、書けない
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("out.txt").path))
        #expect(try run(level: .read, target: folder.appendingPathComponent("in2.txt")) != 0)                       // 読む段階は、フォルダにも書けない
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("in2.txt").path))
    }

    @Test func claudesHomeConfigFileAndItsTemporaryFilesAreWritableButOnlyThoseNames() {
        let folder = URL(fileURLWithPath: "/tmp/work")
        let profile = ACPSandbox.profile(agent: .claude, level: .read, folder: folder, home: "/Users/a.b")
        #expect(profile.contains("(literal \"/Users/a.b/.claude.json\")") && profile.contains("\\.claude\\.json\\..*$"))
        #expect(profile.contains("/Users/a.b/.claude\"") && !profile.contains("(subpath \"/Users/a.b\")"))      // ホーム全体は、書けない
        #expect(profile.contains("^/Users/a\\.b/"))                                                            // ホームの `.` は、逃がす（a.b が、aXb に一致しない）
        #expect(profile.contains("(regex #\"^/private/tmp/claude-\")"))                                          // Bash の一時の場所（頭が、一致する、絶対の場所）
        #expect(!ACPSandbox.profile(agent: .codex, level: .read, folder: folder, home: "/Users/a.b").contains(".claude"))
        #expect(ACPSandbox.profile(agent: .codex, level: .read, folder: folder, home: "/Users/a.b").contains("/Users/a.b/.codex"))
    }

    /// 文字の確認だけでは、**書き方の誤り**（括弧・引用符）を、見つけられない：実際に、`sandbox-exec` に、読ませる（すべてのエージェント・段階。Claude の設定ファイルの規則が、書き方の誤りで、起動できなかった：実測）。
    @Test func everyAgentsProfileIsAcceptedByTheRealSandboxExec() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vc-sbx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for agent in [ChatAgent.agy, .opencode, .claude, .codex] {
            for level in [ChatToolLevel.none, .web, .read, .all] {
                let result = ProcessRunner.run(executable: "sandbox-exec", arguments: ["-p", ACPSandbox.profile(agent: agent, level: level, folder: folder, home: NSHomeDirectory()), "/usr/bin/true"], mergeStderr: true, timeout: 20)
                #expect(result.exitCode == 0, "\(agent) \(level): \(result.text.prefix(200))")
            }
        }
    }
}

