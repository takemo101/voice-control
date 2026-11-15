import AppKit
import Foundation
import VCSkill

struct ChatPreviewCommand: Command {
    static let info = CommandInfo(
        name: "chat-preview", group: .evaluation, summary: "会話のウィンドウの見本を、画面の外で、1 枚ずつ PNG に描く（マイク・言語モデル・読み上げなし。見た目の確認・文書の画像用）",
        usage: ["vc chat-preview --frames <フォルダ> [--fps <枚数>] [--seconds <秒>]"],
        details: ["本物の会話のウィンドウ（SwiftUI）を、画面の外で描いて、見本の会話（作り物の質問と答え）を、時間に沿って流す：声を聞く案内・考え中・調べている操作・答え・外のエージェント・画像つきの質問。利用者の画面には出ない。画面収録の許可も要らない（`scripts/site/render.sh` が使う）。ガラスの透け感は、描けないので、不透明の背景。"],
        options: [("--frames <フォルダ>", "1 枚ずつ PNG（frame-0001.png …）を書く場所（必須）"), ("--seconds <秒>", "全体の長さ（既定 34）"), ("--fps <枚数>", "1 秒あたりの枚数（既定 12）")],
        examples: ["vc chat-preview --frames /tmp/frames --fps 10"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let total = arguments.option("--seconds").flatMap(Double.init) ?? 34
        guard let framesDirectory = arguments.option("--frames") else { usageError("chat-preview", "--frames <フォルダ> を渡してください") }
        let fps = arguments.option("--fps").flatMap(Double.init) ?? 12
        let window = ChatWindow.shared
        // 出来事は、時刻つきの一覧に集める（仮の時計を 1 枚ぶんずつ進めて、描く：描く時間で、ずれない）
        var events: [(time: Double, work: @MainActor () -> Void)] = []
        func at(_ seconds: Double, _ work: @escaping @MainActor () -> Void) { events.append((seconds, work)) }
        var first: UUID?, second: UUID?, third: UUID?

        window.setKeyHint(context.resolveHotKey().spec.displayName)
        window.submit = { _ in }

        // 1. 声で聞く → 調べて答える（Apple のモデル・Web の道具）
        at(1.5) { window.setVoiceState(.listening) }
        at(3.2) { window.setVoiceState(.recognizing) }
        at(4.2) {
            window.setVoiceState(.idle)
            first = window.begin(question: "明日の東京の天気を、調べて", agent: "Apple のモデル", warning: nil, tools: "Web")
        }
        at(5.6) { if let id = first { window.setStatus(id, ChatActivity.search("東京 天気 明日").text) } }
        at(7.4) { if let id = first { window.setStatus(id, ChatActivity.fetch("weather.example.com").text) } }
        at(9.2) {
            guard let id = first else { return }
            window.finish(id, answer: "明日の東京は、**晴れ時々くもり**の予報です。\n\n- 最高気温：24 度\n- 降水確率：午前 10%・午後 30%\n\n夕方から、風が少し強くなります。", activities: [.search("東京 天気 明日"), .fetch("weather.example.com")], notes: [], startedNew: false)
            window.previewState(speaking: true)
        }
        at(13.5) { window.previewState(speaking: false) }

        // 2. 外のエージェント（読む）：フォルダの中を読んで、答える
        at(14.5) {
            third = nil
            second = window.begin(question: "このフォルダのファイルを、一覧にして", agent: "Claude Code", warning: "この Mac の外へ送信", tools: "読む")
        }
        at(15.8) { if let id = second { window.setStatus(id, ChatActivity.list(".").text) } }
        at(17.4) { if let id = second { window.setStatus(id, ChatActivity.read("notes.txt").text) } }
        at(19.2) {
            guard let id = second else { return }
            window.finish(id, answer: "## 見つけたファイル\n\n| 名前 | 内容 |\n|---|---|\n| **notes.txt** | 会議のメモ（42 行） |\n| **plan.md** | 来月の計画 |\n\n`notes.txt` の最後に、**宿題が 2 つ**あります。", activities: [.list("."), .read("notes.txt")], notes: [], startedNew: false)
        }

        // 3. 画面を撮って、画像について聞く（Apple のモデルが、この Mac の中で読む）
        at(23.0) { window.previewState(attachedImage: true, header: (agent: "Apple のモデル", warning: nil, tools: "読む")) }
        at(24.6) { third = window.begin(question: "この画像に、何が写っている？", agent: "Apple のモデル", warning: nil, tools: "読む") }
        at(26.2) { if let id = third { window.setImageRoute(id, .local) } }
        at(28.0) {
            guard let id = third else { return }
            window.finish(id, answer: "青から紫へ変わる背景に、**白い帯が 2 本**あります。上の帯は短く、下の帯は長めです。文字は、読み取れません。", activities: [], notes: [], startedNew: false, imageRoute: .local)
            window.previewState(attachedImage: false)
        }

        try Self.renderFrames(events: events, window: window, seconds: total, fps: fps, directory: framesDirectory)
    }

    /// 画面の外で、1 枚ずつ描く（本物の SwiftUI の描画。ガラスの透け感は、描けないので、ウィンドウは、不透明の背景）。
    @MainActor private static func renderFrames(events: [(time: Double, work: @MainActor () -> Void)], window: ChatWindow, seconds: Double, fps: Double, directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let nsWindow = window.previewOffscreen()
        guard let view = nsWindow.contentView else { fail("描けません（会話）") }
        let queue = events.sorted { $0.time < $1.time }
        var next = 0
        let count = Int(seconds * fps)
        for frame in 0..<count {
            let time = Double(frame) / fps
            while next < queue.count, queue[next].time <= time { queue[next].work(); next += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))   // SwiftUI が、状態を反映する間
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("描けません（会話）") }
            view.cacheDisplay(in: view.bounds, to: rep)
            let file = URL(fileURLWithPath: directory).appendingPathComponent(String(format: "frame-%04d.png", frame + 1))
            try rep.representation(using: .png, properties: [:])?.write(to: file)
        }
        print("\(count) 枚: \(directory)")
    }
}
