import AppKit
import SwiftUI
import VCCore

struct SettingsPreviewCommand: Command {
    static let info = CommandInfo(
        name: "settings-preview", group: .evaluation, summary: "設定ウィンドウの見本を、画像（PNG）に書き出す（見た目の確認用。画面は撮らない）",
        usage: ["vc settings-preview <出力のフォルダ> [--page keys|voice|models|skills|general]"],
        details: [
            "設定ウィンドウ（メニューバーのアプリの「設定…」）の、各ページを、画像にする。画面を撮らない（ビューを、そのまま、描く）ので、画面収録の許可は要らない。",
            "設定は、いつもの設定ファイル（~/.voice-control/settings.json）を読む：自分の設定を写したくなければ、VC_HOME に、空のフォルダを渡す。",
        ],
        options: [("--page <名前>", "このページだけ（なければ、すべて）"), ("--icon <ファイル>", "サイドバーに出すアプリのアイコン（.icns）"), ("--diagnostics", "診断ウィンドウも描く"), ("--recording", "キーの記録中（声で頼むキー）の見た目で、キーのページを描く"), ("--chat", "会話のウィンドウ（見本の会話）だけを描く"), ("--chat-late", "ウィンドウを作る前に会話してから開いた状態を描く"), ("--catalog", "スキルのページで、インストールできるスキルの一覧（GitHub から取る）を出して描く")],
        examples: ["VC_HOME=/tmp/demo-home vc settings-preview /tmp/settings-shots"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let only = arguments.option("--page")
        let icon = arguments.option("--icon")
        let diagnostics = arguments.flag("--diagnostics")
        let recording = arguments.flag("--recording")
        let catalog = arguments.flag("--catalog")
        guard let directory = arguments.positionals.first else { usageError("settings-preview", "出力のフォルダを渡してください") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        if let icon, let image = NSImage(contentsOfFile: icon) { NSApplication.shared.applicationIconImage = image }
        let late = arguments.flag("--chat-late")
        if arguments.flag("--chat") || late {
            let window = late ? ChatWindow.shared.previewLateWindow() : ChatWindow.shared.previewWindow()
            guard let hosting = window.contentView else { fail("描けません（会話）") }
            Self.spin(seconds: 0.4)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fail("描けません（会話）") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let file = URL(fileURLWithPath: directory).appendingPathComponent("chat.png")
            try rep.representation(using: .png, properties: [:])?.write(to: file)
            print(file.path)
            // 考えている間（待ちの質問）と、読み上げていないとき
            let pending = ChatWindow.shared.previewWindow(pendingOnly: true)
            if let view = pending.contentView {
                Self.spin(seconds: 0.4)
                view.layoutSubtreeIfNeeded()
                if let rep2 = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep2)
                    let file2 = URL(fileURLWithPath: directory).appendingPathComponent("chat-pending.png")
                    try rep2.representation(using: .png, properties: [:])?.write(to: file2)
                    print(file2.path)
                }
            }
            return
        }
        let model = SettingsModel()
        for page in SettingsPage.allCases where only == nil || only == page.rawValue {
            model.page = page
            if catalog, page == .skills { model.skillCatalog.loadCatalog(); for _ in 0..<60 { if case .loading = model.skillCatalog.state { Self.spin(seconds: 0.5) } else { break } } }
            if recording, page == .keys { model.startRecording(.dictate) } else { model.stopRecording() }
            let window = SettingsWindow.makeWindow(model: model)
            guard let hosting = window.contentView else { fail("描けません（\(page.rawValue)）") }
            window.setFrameOrigin(NSPoint(x: -6000, y: -6000))   // 画面の外に置いて、アクティブな見た目で描く（利用者の画面には、出ない）
            window.makeKeyAndOrderFront(nil)
            // 描く前に、ランループを少し回す（SwiftUI の更新を、済ませる）
            Self.spin(seconds: 0.4)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fail("描けません（\(page.rawValue)）") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG にできません（\(page.rawValue)）") }
            let file = URL(fileURLWithPath: directory).appendingPathComponent("settings-\(page.rawValue).png")
            try png.write(to: file)
            print(file.path)
            if diagnostics {
            let model = DiagnosticsModel()
            model.run()
            try await Task.sleep(for: .seconds(6))   // 確認（言語モデルの用意・外部コマンド）が終わるまで待つ
            let window = DiagnosticsWindow.makeWindow(model: model)
            if let hosting = window.contentView {
                window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
                window.makeKeyAndOrderFront(nil)
                Self.spin(seconds: 0.4)
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    let file = URL(fileURLWithPath: directory).appendingPathComponent("diagnostics.png")
                    try rep.representation(using: .png, properties: [:])?.write(to: file)
                    print(file.path)
                }
            }
        }
    }
    }

    /// ランループを少し回す（同期の関数：`RunLoop.run(until:)` は、非同期の文脈からは、呼べない）。
    private static func spin(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
