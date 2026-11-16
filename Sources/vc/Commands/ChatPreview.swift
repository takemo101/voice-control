import AppKit
import Foundation
import VCSkill

struct ChatPreviewCommand: Command {
    static let info = CommandInfo(
        name: "chat-preview", group: .evaluation, summary: "会話のウィンドウの見本を出す（マイク・言語モデル・読み上げなし。見た目の確認・文書の動画用）",
        usage: ["vc chat-preview [--seconds <秒>] [--markdown <ファイル>]"],
        details: ["本物の会話のウィンドウを、画面の中央に出して、見本の会話（作り物の質問と答え）を、時間に沿って流す：声を聞く案内・考え中・調べている操作・答え・外のエージェント・画像つきの質問。既定は 34 秒。`scripts/site/capture.sh chat` が、自作の背景の上で撮る。"],
        options: [("--seconds <秒>", "全体の長さ（既定 34）"), ("--markdown <ファイル>", "見本の流れの代わりに、このファイルの Markdown を、答えとして、1 つだけ出す（表示の確認用）")],
        examples: ["vc chat-preview", "vc chat-preview --seconds 40"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let total = arguments.option("--seconds").flatMap(Double.init) ?? 34
        let window = ChatWindow.shared
        // 出来事は、時刻つきの一覧に集めて、実時間で流す
        var events: [(time: Double, work: @MainActor () -> Void)] = []
        func at(_ seconds: Double, _ work: @escaping @MainActor () -> Void) { events.append((seconds, work)) }
        var first: UUID?, second: UUID?, third: UUID?

        window.setKeyHint(context.resolveHotKey().spec.displayName)
        window.submit = { _ in }

        // Markdown の表示の確認：ファイルの中身を、答えとして、1 つだけ出す
        if let path = arguments.option("--markdown") {
            guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { fail("読めません: \(path)") }
            window.show(activate: false)
            let id = window.begin(question: "このフローを、図にして", agent: "Apple のモデル", warning: nil, tools: "なし")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated { window.finish(id, answer: text, activities: [], notes: [], startedNew: false) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + total) { window.hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) } }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
            return
        }

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

        window.show(activate: false)
        for event in events.sorted(by: { $0.time < $1.time }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + event.time) { MainActor.assumeIsolated { event.work() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { window.hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) } }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}
