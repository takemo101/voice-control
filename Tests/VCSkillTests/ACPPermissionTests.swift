import Foundation
import Testing
@testable import VCSkill

/// 許可の確認の答え方（純粋）：段階ごとに、何を開けるか・応答の選択肢・エージェントのツールの読み取り。
@Suite struct ACPPermissionTests {
    private func decide(_ kind: String, name: String? = nil, level: ChatToolLevel) -> ACPPermission.Decision {
        ACPPermission.decide(ACPToolCall(kind: kind, name: name), level: level)
    }

    @Test func theLevelDecidesWhichKindsAreAllowedAskedOrRefused() {
        #expect(decide("search", level: .none) == .reject && decide("search", level: .web) == .allow)
        #expect(decide("read", level: .web) == .reject && decide("read", level: .read) == .allow)
        for kind in ["edit", "delete", "move", "execute", "other", "switch_mode", "unknown-kind"] {
            #expect(decide(kind, level: .read) == .reject)
            #expect(decide(kind, level: .all) == .ask)      // 書き込み・コマンドは、毎回、確認
        }
        #expect(decide("think", level: .none) == .allow)
        // 名前：opencode は、grep が search・Web 検索が other。名前で、読む・調べるだけを、開ける
        #expect(decide("search", name: "grep", level: .read) == .allow && decide("search", name: "grep", level: .web) == .reject)
        #expect(decide("other", name: "websearch", level: .web) == .allow && decide("other", name: "websearch", level: .none) == .reject)
        #expect(decide("other", name: "webfetch", level: .all) == .allow)
        #expect(decide("execute", name: "read", level: .read) == .reject)   // 名前を、読む道具に見せかけても、コマンドは、コマンド
        #expect(decide("edit", name: "websearch", level: .all) == .ask)
    }

    @Test func theOutcomePicksTheMatchingOptionOrCancels() {
        let options: [JSONValue] = [.object(["optionId": .string("a"), "kind": .string("allow_once")]), .object(["optionId": .string("d"), "kind": .string("reject_once")])]
        #expect(ACPPermission.outcome(allow: true, options: options)["outcome"]?["optionId"]?.string == "a")
        #expect(ACPPermission.outcome(allow: false, options: options)["outcome"]?["optionId"]?.string == "d")
        #expect(ACPPermission.outcome(allow: true, options: [])["outcome"]?["outcome"]?.string == "cancelled")   // 選択肢がない：取りやめ
    }

    @Test func aToolCallIsReadFromTheAgentsJsonOnce() {
        let json: JSONValue = .object(["kind": .string("execute"), "name": .string("bash"), "title": .string("Run"), "locations": .array([.object(["path": .string("/a/b")])]),
                                       "rawInput": .object(["CommandLine": .string("ls -la")])])
        #expect(ACPToolCall(json) == ACPToolCall(kind: "execute", name: "bash", title: "Run", path: "/a/b", command: "ls -la"))
        let bare = ACPToolCall(.object([:]))
        #expect(bare.kind == "other" && bare.name == nil && bare.title == "操作" && bare.path == nil && bare.command == nil)   // 足りない項目は、既定
        #expect(ACPToolCall(.object(["name": .string("grep")])).title == "grep")                                                // 題がなければ、名前
        #expect(ACPToolCall(.object(["rawInput": .object(["command": .string("")])])).command == nil)                           // 空のコマンドは、なし
    }
}
