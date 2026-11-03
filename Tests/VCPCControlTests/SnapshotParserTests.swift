import Foundation
import Testing
@testable import VCPCControl

@Suite struct SnapshotParserTests {
    private func json(_ tree: String) -> Data { Data(#"{"ok":true,"data":{"app":"A","tree":\#(tree)}}"#.utf8) }

    @Test func keepsOperableElementsInTreeOrder() throws {
        let tree = """
        {"role":"window","name":"w","children":[
          {"role":"group","name":"g","children":[
            {"role":"button","name":"Mute","ref_id":"@s:e1","available_actions":["Click"]}]},
          {"role":"button","name":"","ref_id":"@s:e2","available_actions":["Click"]},
          {"role":"button","name":"Zoom","ref_id":"@s:e3","states":["disabled"],"available_actions":["Click"]},
          {"role":"textfield","name":"Note","ref_id":"@s:e4","available_actions":["TypeText"]},
          {"role":"textfield","name":"Name","ref_id":"@s:e5","available_actions":["SetValue"]},
          {"role":"scrollarea","ref_id":"@s:e6","available_actions":["Scroll"]}]}
        """
        let snapshot = try SnapshotParser.parse(json(tree))
        #expect(snapshot.app == "A")
        #expect(snapshot.elements.map(\.ref) == ["@s:e1", "@s:e2", "@s:e4", "@s:e6"])   // 名前のない押せる要素（e2）も入る。無効（e3）は入らない
    }

    @Test func surfacesAgentDesktopErrorCode() {
        let data = Data(#"{"ok":false,"error":{"code":"WINDOW_NOT_FOUND"}}"#.utf8)
        #expect(throws: SnapshotError.notOK(code: "WINDOW_NOT_FOUND")) { try SnapshotParser.parse(data) }
    }
}
