import AppKit

// 検証用の自作ウィンドウ（汎用アプリ風）：ボタン・入力欄・スクロール領域・最後の操作を示すラベル。
// 実アプリの代わりに、agent-desktop の操作と、要素の選択を確かめる。--ja で日本語の名前、--many N で、ボタンを N 個足す。
// 操作の結果は、ウィンドウの status ラベルに出る（agent-desktop の snapshot で読める）。

final class Fixture: NSObject, NSApplicationDelegate {
    let ja = CommandLine.arguments.contains("--ja")
    let many: Int = {
        guard let i = CommandLine.arguments.firstIndex(of: "--many"), i + 1 < CommandLine.arguments.count else { return 0 }
        return Int(CommandLine.arguments[i + 1]) ?? 0
    }()
    var window: NSWindow!
    let status = NSTextField(labelWithString: "status: idle")
    let fields = NSTextField(labelWithString: "fields: ")
    var searchField: NSSearchField!, nameField: NSTextField!

    func t(_ en: String, _ jp: String) -> String { ja ? jp : en }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.setAccessibilityLabel(title)
        return b
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let names: [(String, String)] = [("Save", "保存"), ("Send", "送信"), ("Delete", "削除"), ("Cancel", "キャンセル"), ("Settings", "設定"), ("New Folder", "新しいフォルダ"), ("Reload", "再読み込み"), ("Help", "ヘルプ")]
        var views: [NSView] = names.map { button(t($0.0, $0.1), #selector(pressed(_:))) }
        for i in 0..<many { views.append(button("Item \(i + 1)", #selector(pressed(_:)))) }
        // 状態を持つ部品（チェック・切り替え・ポップアップ・開閉）。agent-desktop の available_actions の語彙を見る・操作を確かめるため。
        let dark = NSButton(checkboxWithTitle: t("Dark Mode", "ダークモード"), target: self, action: #selector(toggled(_:)))
        dark.setAccessibilityLabel(t("Dark Mode", "ダークモード"))
        let sw = NSSwitch(); sw.target = self; sw.action = #selector(toggled(_:)); sw.setAccessibilityLabel(t("Notifications", "通知"))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Small", "Medium", "Large"]); popup.target = self; popup.action = #selector(chose(_:)); popup.setAccessibilityLabel(t("Size", "サイズ"))
        let disclosure = NSButton(title: "", target: self, action: #selector(toggled(_:)))
        disclosure.bezelStyle = .disclosure; disclosure.setButtonType(.pushOnPushOff); disclosure.setAccessibilityLabel(t("Details", "詳細"))
        views.insert(contentsOf: [dark, sw, popup, disclosure], at: 0)
        // --dup：同じ名前のボタンが、位置だけ違う場合（左・右・下）と、名前のないアイコンのボタン（中央）。位置の情報の効果を確かめるため。
        if CommandLine.arguments.contains("--dup") {
            let open1 = button("Open", #selector(pressed(_:))), open2 = button("Open", #selector(pressed(_:)))
            let icon = NSButton(image: NSImage(systemSymbolName: "star", accessibilityDescription: nil)!, target: self, action: #selector(pressed(_:)))
            icon.title = ""; icon.setAccessibilityLabel(nil)
            let row = NSStackView(views: [open1, icon, open2])
            row.orientation = .horizontal; row.distribution = .equalSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 260).isActive = true
            views.insert(row, at: 0)
            views.append(button("Open", #selector(pressed(_:))))
        }

        searchField = NSSearchField()
        searchField.placeholderString = t("Search", "検索")
        searchField.setAccessibilityLabel(t("Search", "検索"))
        nameField = NSTextField()
        nameField.placeholderString = t("Name", "名前")
        nameField.setAccessibilityLabel(t("Name", "名前"))
        let notes = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        notes.string = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 90))
        scroll.documentView = notes
        scroll.hasVerticalScroller = true
        scroll.setAccessibilityLabel("notes")
        status.setAccessibilityLabel("status")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let grid = NSStackView(views: views)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        let stack = NSStackView(views: [searchField, nameField, scroll, grid, status, fields])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 300, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "VC Fixture"
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
        // 文字を入れる欄の既定のフォーカスを検索欄にする
        window.makeFirstResponder(searchField)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func say(_ s: String) { status.stringValue = "status: " + s; status.setAccessibilityValue(status.stringValue) }

    @objc func pressed(_ sender: NSButton) { say("pressed \(sender.title)") }
    @objc func toggled(_ sender: NSControl) { say("toggled \(sender.accessibilityLabel() ?? "?") state=\((sender as? NSButton)?.state.rawValue ?? (sender as? NSSwitch)?.state.rawValue ?? -1)") }
    @objc func chose(_ sender: NSPopUpButton) { say("size=\(sender.titleOfSelectedItem ?? "?")") }

    /// 入力欄の中身を、`fields` ラベルに出す（文字入力の確認用）。
    func refresh() {
        let text = "fields: search=\(searchField.stringValue) name=\(nameField.stringValue)"
        if fields.stringValue != text { fields.stringValue = text; fields.setAccessibilityValue(text) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dock に出さない・前面を奪わない
let delegate = Fixture()
app.delegate = delegate
app.run()
