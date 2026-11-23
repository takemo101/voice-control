import AppKit
import Testing
@testable import vc

/// メニューバーのアプリは、アプリのメニューを持たない：編集メニュー（のキーの組み合わせ）がないと、⌘V などが、入力欄に届かない。ここでは、**キーの組み合わせと、宛先（最初のレスポンダ）**だけ確かめる。
@Suite @MainActor struct EditMenuTests {
    @Test func theEditMenuMapsTheStandardShortcutsToTheStandardActionsForTheFirstResponder() throws {
        let main = EditMenu.make()
        let edit = try #require(main.items.dropFirst().first?.submenu)
        let items = edit.items.filter { !$0.isSeparatorItem }
        let table = Dictionary(uniqueKeysWithValues: items.map { ($0.action.map { NSStringFromSelector($0) } ?? "", $0) })
        for (action, key) in [("paste:", "v"), ("copy:", "c"), ("cut:", "x"), ("selectAll:", "a"), ("undo:", "z"), ("redo:", "z")] {
            let item = try #require(table[action], "\(action)")
            #expect(item.keyEquivalent == key && item.target == nil, "\(action)")                   // 宛先なし：いま入力しているものが、受ける
            #expect(item.keyEquivalentModifierMask == (action == "redo:" ? [.command, .shift] : [.command]), "\(action)")
        }
        #expect(main.items.first?.submenu != nil)                                                   // 先頭は、アプリのメニュー（標準の作り）
    }
}
