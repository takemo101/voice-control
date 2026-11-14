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
        options: [("--page <名前>", "このページだけ（なければ、すべて）")],
        examples: ["VC_HOME=/tmp/demo-home vc settings-preview /tmp/settings-shots"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let only = arguments.option("--page")
        guard let directory = arguments.positionals.first else { usageError("settings-preview", "出力のフォルダを渡してください") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = SettingsModel()
        for page in SettingsPage.allCases where only == nil || only == page.rawValue {
            model.page = page
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: 780, height: 580)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            // 描く前に、ランループを少し回す（SwiftUI の更新を、済ませる）
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fail("描けません（\(page.rawValue)）") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG にできません（\(page.rawValue)）") }
            let file = URL(fileURLWithPath: directory).appendingPathComponent("settings-\(page.rawValue).png")
            try png.write(to: file)
            print(file.path)
        }
    }
}
