import AppKit
import SwiftUI
import VCSkill

/// 会話のウィンドウ：**1 つだけ**。質問と答えが、下へ続いていく（答えごとに、新しいウィンドウを開かない）。
/// 見た目：質問は、右の吹き出し（青〜紫のグラデーション）。答えは、左のカード（アイコンつき。Markdown を整形）。**実行した操作**は、答えの下に、種類ごとのアイコンつきで並ぶ。考えている間は、波打つ点と、いまの操作。
/// - 質問が分かった時点で、質問と「考えています…」（外のエージェントの実行中は、いまの操作）を出し、答えが来たら、同じ場所を、答えに置き換える。
/// - 記録は、**メモリだけ**（会話を終えたら・リセットしたら・しばらく話さなかったら、消える。保存しない）。
/// - 読み上げの最中は、ヘッダーに波形と「読み上げ中」、下に「読み上げを止める」を出す。Esc は、読み上げを先に止める（もう一度で、閉じる）。答えごとの「読み上げ」「コピー」もある。
/// メインスレッドで使う。
@MainActor final class ChatWindow: NSObject, NSWindowDelegate {
    static let shared = ChatWindow()

    private let state = ChatWindowState()
    private var window: DocumentWindowFrame?

    var isVisible: Bool { window?.isVisible == true }
    var hasPending: Bool { state.entries.last.map { $0.answer == nil } ?? false }

    private override init() {
        super.init()
        // 会話の答えの読み上げだけに、反応する（スキルの結果・確認の問いかけの読み上げには、反応しない）
        SaySpeaker.shared.observe(.conversation) { [weak self] speaking in
            self?.state.speaking = speaking
            if !speaking { self?.state.speakingEntry = nil }
        }
        state.speaking = SaySpeaker.shared.isSpeaking(.conversation)
    }

    // MARK: 記録の更新

    /// 質問が分かった：質問と「考えています…」を出す。`agent`：使っているエージェントの名前。`warning`：外へ送るときの断り（ヘッダーの橙の札）。`tools`：開けている道具（札）。
    func begin(question: String, agent: String, warning: String?, tools: String?) {
        discardPending()
        state.agent = agent
        state.warning = warning
        state.tools = tools
        state.entries.append(ChatEntry(question: question))
        state.scrollToken += 1
    }

    /// 実行中の様子（外のエージェントの、いまの操作など）。
    func setStatus(_ text: String) {
        guard hasPending else { return }
        state.entries[state.entries.count - 1].status = text
    }

    /// 答えが来た。`startedNew`：しばらく話さなかったので、前の会話は、終わった（古い記録を消す）。
    func finish(answer: String, activities: [ChatActivity], notes: [String], startedNew: Bool) {
        guard hasPending else { return }
        if startedNew { state.entries = [state.entries[state.entries.count - 1]] }
        let last = state.entries.count - 1
        state.entries[last].status = nil
        state.entries[last].answer = answer
        state.entries[last].rendered = Self.render(answer)
        state.entries[last].activities = activities
        state.entries[last].notes = notes
        state.scrollToken += 1
    }

    /// 答えが出なかった（失敗・取りやめ）：待ちの質問を、取り除く。
    func discardPending() {
        guard hasPending else { return }
        state.entries.removeLast()
    }

    /// 記録を、すべて消す（会話の終了・リセット）。
    func clear() {
        state.entries = []
    }

    // MARK: 表示

    /// 出す。`activate`：前に出して、アプリを前面にする（出ているときの更新では、奪わない）。
    func show(activate: Bool) {
        let window = makeWindowIfNeeded()
        if !window.isVisible {
            window.alphaValue = 0
            window.setFrame(ScreenPlacement.centeredFrame(size: window.frame.size, in: ScreenPlacement.currentVisibleFrame()), display: false)
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 1
            }
            if activate { NSApplication.shared.activate(ignoringOtherApps: true) }
        } else {
            window.orderFrontRegardless()
        }
        state.scrollToken += 1
    }

    /// いちばん新しい答えを、読み上げる（会話の答えとして：読んでいる間、この答えに、「止める」が出る）。
    func speakLatest(_ chunks: [String]) {
        state.speakingEntry = state.entries.last?.id
        SaySpeaker.shared.say(chunks: chunks, channel: .conversation)
    }

    func hide() { window?.orderOut(nil) }

    func windowWillClose(_ notification: Notification) {}

    /// 見た目の確認用（`vc settings-preview --chat`）：見本の会話を入れて、画面の外に置いたウィンドウを返す（利用者の画面には、出ない）。
    func previewWindow(pendingOnly: Bool = false) -> NSWindow {
        let window = makeWindowIfNeeded()
        state.agent = "Claude Code"
        state.warning = "この Mac の外へ送信"
        state.tools = "すべて"
        func entry(_ question: String, answer: String?, status: String? = nil, activities: [ChatActivity] = [], notes: [String] = []) -> ChatEntry {
            var e = ChatEntry(question: question)
            e.status = status
            e.answer = answer
            e.rendered = answer.map { Self.render($0) }
            e.activities = activities
            e.notes = notes
            return e
        }
        state.entries = [
            entry("このフォルダのファイルを、一覧にして", answer: "## 見つけたファイル\n\nフォルダには、次の 2 つがあります。\n\n| 名前 | 内容 |\n|---|---|\n| **note.txt** | メモ（16 バイト） |\n| **memo.txt** | 「確認済み」 |\n\n1. `memo.txt` は、さっき作りました\n2. 詳しくは [公式の説明](https://example.com/doc) を見てください\n\n> 書き込みは、作業フォルダの中だけです。\n\n```sh\nls -la\n```", activities: [.run("ls -la"), .write("memo.txt")]),
            entry("東京の明日の天気は？", answer: "明日の東京は、**晴れ時々くもり**で、最高気温は 24 度の予報です。降水確率は午前 10%、午後 30% で、夕方から風が少し強くなります。傘は、念のため、持っていくと安心です。気温の変化が大きいので、薄手の上着があると、朝晩の移動が楽になります。", notes: ["しばらく話さなかったので、前の会話は終わりました"]),
            entry("もう少し詳しく教えて", answer: nil, status: ChatActivity.search("東京 天気 明日").text),
        ]
        if pendingOnly { state.entries = Array(state.entries.suffix(2)); state.speaking = false } else { state.speaking = true; state.speakingEntry = state.entries.first?.id }
        state.solid = true
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindowIfNeeded() -> DocumentWindowFrame {
        if let window { return window }
        let window = DocumentWindowFrame(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 420, height: 380)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.onEscape = {
            guard SaySpeaker.shared.isSpeaking(.conversation) else { return false }
            SaySpeaker.shared.stop()
            return true
        }
        let root = ChatView(
            state: state,
            stopSpeaking: { SaySpeaker.shared.stop() },
            speak: { [unowned self] entry in
                SaySpeaker.shared.stop()
                state.speakingEntry = entry.id
                SaySpeaker.shared.say(chunks: SpokenText.chunks(from: entry.answer ?? ""), channel: .conversation)
            },
            reset: { AppActions.resetConversation() },
            copyAll: { [unowned self] in copyAll() },
            close: { [unowned window] in window.close() })
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        self.window = window
        return window
    }

    /// 答えを整形する（終わりの、空の行は、除く：カードの下に、余白ができるため）。
    private static func render(_ markdown: String) -> NSAttributedString {
        let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer.render(markdown))
        while rendered.length > 0, rendered.string.last == "\n" { rendered.deleteCharacters(in: NSRange(location: rendered.length - 1, length: 1)) }
        return rendered
    }

    private func copyAll() {
        let text = state.entries.map { entry in
            "あなた：\(entry.question)\n\n" + (entry.answer ?? "") + (entry.activities.isEmpty ? "" : "\n\n実行した操作：\n" + entry.activities.map { "- \($0.text)" }.joined(separator: "\n"))
        }.joined(separator: "\n\n---\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.state.copied = false }
    }
}

// MARK: 状態

/// 会話の 1 往復（質問と、答え。答えが来るまでは、`status`）。
struct ChatEntry: Identifiable {
    let id = UUID()
    var question: String
    let asked = Date()
    var status: String? = "考えています…"
    var answer: String?
    var activities: [ChatActivity] = []
    var notes: [String] = []
    /// 答えを整形した結果（描き直しのたびに、作り直さない）。
    var rendered: NSAttributedString?
}

/// 画面の状態。SwiftUI の `@State` は、この環境（コマンドラインツールだけ）では、マクロのプラグインがなく使えないので、参照型にする。
@MainActor final class ChatWindowState: ObservableObject {
    @Published var entries: [ChatEntry] = []
    /// 会話の答えを、読んでいるか（スキルの結果などの読み上げは、含まない）。
    @Published var speaking = false
    /// 読んでいる答え（その答えにだけ、「止める」を出す）。
    @Published var speakingEntry: UUID?
    @Published var copied = false
    @Published var agent = ""
    @Published var warning: String?
    @Published var tools: String?
    /// 増えると、いちばん新しい往復の頭へ、スクロールする。
    @Published var scrollToken = 0
    /// 画像に描く確認用：ガラスの代わりに、暗い面を敷く。
    @Published var solid = false
}
