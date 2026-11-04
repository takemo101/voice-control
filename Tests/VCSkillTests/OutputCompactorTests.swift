import Foundation
import Testing
@testable import VCSkill

@Suite struct OutputCompactorTests {
    private let snapshot = #"""
    {"ok":true,"data":{"app":"Fixture","tree":{"role":"window","children":[
      {"role":"button","name":"Save","ref_id":"@s17tb038elj2nz:e1","available_actions":["Click"]},
      {"role":"button","name":"Off","ref_id":"@s17tb038elj2nz:e2","available_actions":["Click"],"states":["disabled"]},
      {"role":"group","ref_id":"@s17tb038elj2nz:e3"},
      {"role":"textfield","name":"Search","ref_id":"@s17tb038elj2nz:e4","available_actions":["TypeText"],"states":["focused"]}]}}}
    """#

    @Test func snapshotBecomesShortOperableLinesWithAliasedRefs() {
        let aliases = RefAliases()
        let text = OutputCompactor.compact(argv: ["agent-desktop", "snapshot", "-i"], output: snapshot, aliases: aliases)
        #expect(text == "app: Fixture\n@a1:e1 [button] Save\n@a1:e4 [textfield] Search (focused)")
        // 別名は、実行の直前に、元の参照に戻る
        #expect(aliases.expand("@a1:e4") == "@s17tb038elj2nz:e4")
        #expect(aliases.expand("@zzz:e4") == "@zzz:e4")
        #expect(aliases.expand("Settings") == "Settings")
    }

    @Test func errorsKeepTheirCodeAndLongOutputIsCut() {
        let error = #"{"ok":false,"error":{"code":"STALE_REF","message":"gone"}}"#
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "click", "@a1:e1"], output: error) == "error STALE_REF: gone")
        let long = String(repeating: "x", count: OutputCompactor.maxChars + 50)
        #expect(OutputCompactor.compact(argv: ["ls"], output: long).contains("50 文字を省略"))
    }
}

/// agent-desktop は、警告を stderr に出す（標準出力と混ざる）。JSON の前に警告の行があっても、整形が効く。
@Suite struct WarningLinesTests {
    private let warning = "2026-11-04T14:40:57Z  WARN agent_desktop_macos: Skipped invalid AppKit application records skipped=[{\"field\":\"pid\"}]\n"
    private let snapshot = #"{"ok":true,"data":{"app":"Fixture","tree":{"role":"window","children":[{"role":"statictext","value":"hello"},{"role":"button","name":"Save","ref_id":"@s1:e1","available_actions":["Click"]}]}}}"#

    @Test func theSnapshotIsStillShapedWithWarningLinesInFront() {
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "snapshot", "-i"], output: warning + warning + snapshot) == "app: Fixture\n@a1:e1 [button] Save")
    }

    @Test func anOutputWithoutJsonIsLeftAlone() {
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "snapshot", "-i"], output: warning) == warning)
    }
}
