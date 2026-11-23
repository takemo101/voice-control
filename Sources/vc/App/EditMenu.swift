import AppKit
import VCCore

/// **編集メニュー**（取り消す・やり直す・切り取り・コピー・貼り付け・すべてを選択）。メニューバーのアプリ（Dock に出ない・`.accessory`）は、アプリのメニューを持たないので、**⌘V・⌘C・⌘X・⌘A・⌘Z が、入力欄に届かない**（設定ウィンドウの入力欄へ、URL・キーを貼り付けられなかった）。
/// 標準の部品は、メニューの「キーの組み合わせ」を経由して、これらの操作を受ける。メニューバーには出ない（`.accessory`）が、キーの組み合わせは、アプリが前面のとき、効く。
/// 宛先は、決めない（`nil`）：いま入力しているもの（最初のレスポンダ）が、受ける。
enum EditMenu {
    struct Entry: Equatable {
        let title: String
        let action: String
        let key: String
        let shift: Bool
    }

    /// 並び（区切りは、`nil`）。言葉は、呼ぶたびに作る（表示言語の切り替えに、従う）。
    static var entries: [Entry?] { [
        Entry(title: tr("取り消す"), action: "undo:", key: "z", shift: false),
        Entry(title: tr("やり直す"), action: "redo:", key: "z", shift: true),
        nil,
        Entry(title: tr("切り取り"), action: "cut:", key: "x", shift: false),
        Entry(title: tr("コピー"), action: "copy:", key: "c", shift: false),
        Entry(title: tr("貼り付け"), action: "paste:", key: "v", shift: false),
        Entry(title: tr("すべてを選択"), action: "selectAll:", key: "a", shift: false),
    ] }

    /// アプリのメインメニュー（先頭は、空のアプリのメニュー：標準の作り。2 つ目が編集）。
    @MainActor static func make() -> NSMenu {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        main.addItem(app)
        let edit = NSMenuItem(title: tr("編集"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: tr("編集"))
        for entry in entries {
            guard let entry else { submenu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: Selector((entry.action)), keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.shift ? [.command, .shift] : [.command]
            submenu.addItem(item)
        }
        edit.submenu = submenu
        main.addItem(edit)
        return main
    }

    @MainActor static func install() { NSApplication.shared.mainMenu = make() }
}
