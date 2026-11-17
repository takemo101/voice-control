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

    // MARK: 自動モード（作業フォルダの中は、確認なし）

    private let work = URL(fileURLWithPath: "/tmp/vc-auto-work")
    private func auto(_ call: ACPToolCall, level: ChatToolLevel = .all, on: Bool = true) -> ACPPermission.Decision { ACPPermission.decide(call, folder: work, level: level, auto: on) }

    @Test func inAutoModeWritesInsideTheFolderAndHarmlessCommandsRunWithoutAsking() {
        #expect(auto(ACPToolCall(kind: "edit", path: "/tmp/vc-auto-work/notes/a.md")) == .allow)
        #expect(auto(ACPToolCall(kind: "execute", command: "set -C; printf hi > check.txt")) == .allow)                   // Codex の実際の形
        #expect(auto(ACPToolCall(kind: "execute", command: "cat a.md | wc -l")) == .allow)
        // 利用者が確認を出された形（Python で、ファイルを作る）：規則では決めず、Jev に聞く
        #expect(auto(ACPToolCall(kind: "execute", command: ##"python3 -c 'from pathlib import Path; Path("a.md").open("x").write("""本文""")'"##)) == .judge)
    }

    @Test func inAutoModeWritesOutsideAreRefusedDeletesAndMovesStillAskAndTheCatastrophicIsBlocked() {
        #expect(auto(ACPToolCall(kind: "edit", path: "/tmp/other/a.md")) == .reject)                       // 外は、断る
        #expect(auto(ACPToolCall(kind: "edit", path: "/tmp/vc-auto-work/../other/a.md")) == .reject)       // `..` で、外へ出る道
        #expect(auto(ACPToolCall(kind: "edit")) == .ask)                                                   // 場所が分からなければ、聞く
        #expect(auto(ACPToolCall(kind: "delete", path: "/tmp/vc-auto-work/a.md")) == .ask)                 // 消す：中でも、聞く
        #expect(auto(ACPToolCall(kind: "move", path: "/tmp/vc-auto-work/a.md")) == .ask && auto(ACPToolCall(kind: "delete", path: "/etc/hosts")) == .reject)
        #expect(auto(ACPToolCall(kind: "switch_mode")) == .ask && auto(ACPToolCall(kind: "other")) == .ask)
        #expect(auto(ACPToolCall(kind: "execute", command: "rm -rf ~")) == .block)                         // 取り返しのつかないもの：断る
        #expect(auto(ACPToolCall(kind: "execute", command: "rm a.md")) == .ask)                            // 消す：聞く
    }

    @Test func autoModeNeverWorksBelowTheAllLevelOrWhenSwitchedOffAndOtherRulesAreUnchanged() {
        #expect(auto(ACPToolCall(kind: "edit", path: "/tmp/vc-auto-work/a.md"), level: .read) == .reject)  // 「すべて」だけ
        #expect(auto(ACPToolCall(kind: "execute", command: "echo hi"), level: .web) == .reject)
        #expect(auto(ACPToolCall(kind: "edit", path: "/tmp/vc-auto-work/a.md"), on: false) == .ask)        // オフなら、これまでどおり
        #expect(auto(ACPToolCall(kind: "execute", command: "echo hi"), on: false) == .ask)
        #expect(auto(ACPToolCall(kind: "read"), level: .read) == .allow && auto(ACPToolCall(kind: "search", name: "websearch"), level: .none) == .reject)
    }

    // MARK: Jev に聞く（ACPTurnState：許可の要求に、答える）

    private func request(_ command: String, judge: CommandJudge?, confirm: ToolConfirm?) async -> String {
        let turn = ACPTurnState(tools: .all, folder: work, sessionID: "s", confirm: confirm, auto: true, judge: judge, onActivity: nil)
        let json = #"{"sessionId":"s","toolCall":{"toolCallId":"t","kind":"execute","rawInput":{"command":\#(String(data: try! JSONSerialization.data(withJSONObject: [command], options: [.fragmentsAllowed]).dropFirst().dropLast(), encoding: .utf8)!)}},"options":[{"optionId":"allow","kind":"allow_once"},{"optionId":"deny","kind":"reject_once"}]}"#
        let reply = await turn.handleRequest("session/request_permission", JSONValue.parse(Data(json.utf8))!)
        return reply?["outcome"]?["optionId"]?.string ?? "none"
    }

    @Test func aHarmlessVerdictFromJevSkipsTheConfirmationButAnythingElseAsks() async {
        let asked = ACPCollected<String>()
        let confirm: ToolConfirm = { detail in asked.add(detail); return false }
        let harmless: CommandJudge = { _ in true }, harmful: CommandJudge = { _ in false }
        #expect(await request("python3 build.py", judge: harmless, confirm: confirm) == "allow" && asked.all.isEmpty)    // Jev が、無害と判定：聞かない
        #expect(await request("python3 build.py", judge: harmful, confirm: confirm) == "deny" && asked.all.count == 1)   // 無害でない：聞く（断られた）
        #expect(await request("python3 build.py", judge: nil, confirm: confirm) == "deny" && asked.all.count == 2)        // Jev が使えない：聞く
        #expect(await request("rm a.md", judge: harmless, confirm: confirm) == "deny" && asked.all.count == 3)            // 危ない名前：Jev に聞かず、確認
        #expect(await request("python3 -c 'print(open(\"/etc/hosts\").read())'", judge: harmless, confirm: confirm) == "deny" && asked.all.count == 4)   // 危ない場所：同じ
    }
}
