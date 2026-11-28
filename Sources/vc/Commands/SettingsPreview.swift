import AppKit
import SwiftUI
import VCCore
import VCSkill

struct SettingsPreviewCommand: Command {
    static let info = CommandInfo(
        name: "settings-preview", group: .evaluation, summary: "設定ウィンドウの見本を、画像（PNG）に書き出す（見た目の確認用。画面は撮らない）",
        usage: ["vc settings-preview <出力のフォルダ> [--page general|keys|voice|dictation|transcribe|history|chat|models|skills] [--height <数>]"],
        details: [
            "設定ウィンドウ（メニューバーのアプリの「設定…」）の、各ページを、画像にする。画面を撮らない（ビューを、そのまま、描く）ので、画面収録の許可は要らない。",
            "設定は、いつもの設定ファイル（~/.voice-control/settings.json）を読む：自分の設定を写したくなければ、VC_HOME に、空のフォルダを渡す。",
        ],
        options: [("--page <名前>", "このページだけ（なければ、すべて）"), ("--height <数>", "ウィンドウの高さ（下まで見たいとき）"), ("--icon <ファイル>", "サイドバーに出すアプリのアイコン（.icns）"), ("--diagnostics", "診断ウィンドウも描く"), ("--recording", "キーの記録中（声で頼むキー）の見た目で、キーのページを描く"), ("--chat", "会話のウィンドウ（見本の会話）だけを描く"), ("--chat-late", "ウィンドウを作る前に会話してから開いた状態を描く"), ("--chat-up", "会話の記録を、いちばん上へ戻した状態（「最新へ」のボタンが出る）を描く"), ("--chat-draft", "入力欄に、複数行の文を入れた状態を描く"), ("--chat-files", "ファイルを添えた状態（札）を描く"), ("--catalog", "スキルのページで、インストールできるスキルの一覧（GitHub から取る）を出して描く")],
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
        // モデルの検索の一覧（ポップオーバーの中身）を、見本の一覧で描く：`--model-search <入力>`（見た目の確認用。エージェントは、起動しない）
        if let query = arguments.option("--model-search") {
            let samples: [String: [String]] = [
                "claude": ["default|Default (recommended)", "opus|Opus 5.5", "sonnet|Sonnet 5.5", "haiku|Haiku 5.5", "claude-sonnet-5|Sonnet 5", "claude-haiku-4-5-20251001|Haiku 4.5", "claude-opus-4-8|Opus 4.8"],
                "opencode": ["claude-agent/claude-fable-5|claude-agent/Fable 5", "claude-agent/haiku|claude-agent/Haiku 5.5", "claude-agent/opus|claude-agent/Opus 5.5", "openai/gpt-6.2|openai/GPT 6.2", "openai/gpt-6.2-mini|openai/GPT 6.2 mini", "google/gemini-4-argon|google/Gemini 4 Argon", "google/gemini-4-hydrogen|google/Gemini 4 Hydrogen"],
                "codex": ["gpt-6.2-sol[low]|6.2 Sol (low)", "gpt-6.2-sol[medium]|6.2 Sol (medium)", "gpt-6.2-sol[high]|6.2 Sol (high)", "gpt-6.2-astra[low]|6.2 Astra (low)", "gpt-6.2-astra[high]|6.2 Astra (high)"],
            ]
            let sample = (samples[arguments.option("--model-sample") ?? "claude"] ?? samples["claude"]!)
                .map { pair -> ACPModelChoice in let parts = pair.split(separator: "|", maxSplits: 1).map(String.init); return ACPModelChoice(id: parts[0], name: parts[1]) }
            let search = ModelSearchState(); search.query = query
            search.highlighted = arguments.option("--model-highlight")
            let view = ModelSearchList(search: search, state: .loaded(ACPModelListing(choices: sample, current: sample.first?.id)), chosen: arguments.option("--model-chosen") ?? "", agentName: "claude", select: { _ in }, reload: {})
                .padding(1).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fail("描けません（モデルの検索）") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let file = URL(fileURLWithPath: directory).appendingPathComponent("model-search.png")
            try rep.representation(using: .png, properties: [:])?.write(to: file)
            print(file.path)
            return
        }
        let late = arguments.flag("--chat-late")
        let scrolledUp = arguments.flag("--chat-up")
        if arguments.flag("--chat") || late {
            let window = late ? ChatWindow.shared.previewLateWindow() : ChatWindow.shared.previewWindow()
            guard let hosting = window.contentView else { fail("描けません（会話）") }
            Self.spin(seconds: 0.4)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fail("描けません（会話）") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if scrolledUp {   // 記録を、いちばん上へ戻した状態（「最新へ」のボタンが出る）を描く：本物のスクロールの位置の検出を、通す
                func scrollView(in view: NSView) -> NSScrollView? { (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first }
                if let scroll = scrollView(in: hosting), let document = scroll.documentView {
                    document.scroll(NSPoint(x: 0, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    Self.spin(seconds: 0.5)
                    hosting.layoutSubtreeIfNeeded()
                }
                guard let rep3 = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fail("描けません（会話）") }
                hosting.cacheDisplay(in: hosting.bounds, to: rep3)
                let up = URL(fileURLWithPath: directory).appendingPathComponent("chat-up.png")
                try rep3.representation(using: .png, properties: [:])?.write(to: up)
                print(up.path)
                return
            }
            let file = URL(fileURLWithPath: directory).appendingPathComponent("chat.png")
            try rep.representation(using: .png, properties: [:])?.write(to: file)
            print(file.path)
            // 考えている間（待ちの質問）と、読み上げていないとき
            let pending = ChatWindow.shared.previewWindow(pendingOnly: true)
            if arguments.flag("--chat-files") { ChatWindow.shared.previewState(sampleFiles: true) }   // 添えたファイルの札（見本）
            if arguments.flag("--chat-draft") { ChatWindow.shared.previewState(draft: "来週の会議の議事録を、次の形で、まとめてください。\n・決まったこと\n・宿題（担当と期限）\n・次回の議題") }   // 複数行の入力（見本の文）
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
            if recording, page == .keys { model.startRecording(.dictate) } else if recording, page == .dictation { model.startRecording(.sendKey(model.settings.sendKeyList.count)) } else { model.stopRecording() }
            let window = SettingsWindow.makeWindow(model: model)
            guard let hosting = window.contentView else { fail("描けません（\(page.rawValue)）") }
            if let height = arguments.option("--height").flatMap(Double.init) { window.setContentSize(NSSize(width: hosting.bounds.width, height: height)) }
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
