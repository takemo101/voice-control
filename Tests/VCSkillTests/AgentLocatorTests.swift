import Foundation
import Testing
@testable import VCSkill

/// 外のエージェントの CLI が、入っているかの判断：入っているものだけを、選択肢に出す。見つける場所は、`PATH` と、よくある置き場所。
@Suite struct AgentLocatorTests {
    private let home = "/Users/x"

    @Test func onlyInstalledAgentsAreOfferedAndAppleIsAlwaysFirst() {
        let installed: Set<String> = ["/Users/x/.local/bin/claude", "/opt/homebrew/bin/codex"]
        let dirs = AgentLocator.searchDirectories(environment: ["PATH": "/usr/bin:/bin"], home: home)
        let available = AgentLocator.available(directories: dirs, isExecutable: { installed.contains($0) })
        #expect(available == [.apple, .server, .claude, .codex])             // Apple と、設定のサーバーは、いつも選べる。入っていない agy・grok・opencode・pi は、出さない
        #expect(AgentLocator.isAvailable(.apple, directories: [], isExecutable: { _ in false }))   // Apple は、CLI がなくても、使える
        #expect(!AgentLocator.isAvailable(.grok, directories: dirs, isExecutable: { installed.contains($0) }))
    }

    @Test func theSearchOrderIsPathFirstThenCommonPlacesWithoutDuplicates() {
        let dirs = AgentLocator.searchDirectories(environment: ["PATH": "/custom/bin:/usr/bin:/custom/bin"], home: home)
        #expect(dirs.first == "/custom/bin" && dirs.filter { $0 == "/usr/bin" }.count == 1 && dirs.filter { $0 == "/custom/bin" }.count == 1)
        #expect(dirs.contains("/Users/x/.bun/bin") && dirs.contains("/opt/homebrew/bin"))   // アプリは、シェルの PATH を受け取らないので、よくある場所も探す
        #expect(AgentLocator.executablePath(for: .claude, directories: ["/a", "/b"], isExecutable: { $0 == "/b/claude" }) == "/b/claude")
        #expect(AgentLocator.executablePath(for: .claude, directories: ["/a"], isExecutable: { _ in false }) == nil)
        #expect(AgentLocator.childPATH(environment: ["PATH": "/custom/bin"], home: home).hasPrefix("/custom/bin:") && AgentLocator.childPATH(environment: [:], home: home).contains("/Users/x/.local/bin"))
    }
}
