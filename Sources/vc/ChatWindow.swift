import AppKit
import SwiftUI
import VCCore
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
    private var expiry: Task<Void, Never>?

    var isVisible: Bool { window?.isVisible == true }

    /// 入力欄から送られた質問を、処理する（声の流れの組み立てで、決める：`VoiceSession`）。なければ、入力欄は出さない。
    var submit: (@MainActor (String) -> Void)? {
        get { state.submit }
        set { state.submit = newValue }
    }

    /// 声の状態（録音・認識）を、知らせる（下の案内に出す）。
    func setVoiceState(_ voice: ChatVoiceState) { state.voice = voice }

    /// 会話のキーの名前（案内に出す）。
    func setKeyHint(_ hint: String?) { state.keyHint = hint }
    var hasPending: Bool { state.entries.hasPending }

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
    /// 戻り値の `id` で、この往復を指す（答え・中断・失敗の知らせを、この往復だけに、届けるため）。
    @discardableResult
    func begin(question: String, agent: String, warning: String?, tools: String?, cancel: (() -> Void)? = nil) -> UUID {
        state.agent = agent
        state.warning = warning
        state.tools = tools
        var entry = ChatEntry(question: question)
        entry.cancel = cancel
        entry.image = state.image.map { EntryImage(thumbnail: $0.thumbnail) }   // 添えてある画像を、質問に付ける（どの画像についての質問か、分かるように）
        state.entries.begin(entry)
        state.scrollToken += 1
        return entry.id
    }

    /// 実行中の様子（外のエージェントの、いまの操作など）。
    func setStatus(_ id: UUID, _ text: String) { state.entries.setStatus(id, text) }

    /// 質問に使う画像が分かった（言葉で頼んだ画像など）：その質問に、画像を付ける（添えてある画像は、`begin` で付いている）。
    func attachImage(_ id: UUID, file: URL) {
        guard let thumbnail = HUDImage.load(file, sendsOut: false)?.thumbnail else { return }
        state.entries.attach(id, image: EntryImage(thumbnail: thumbnail))
    }

    /// 画像の扱いが決まった（確認待ち・送った・断った）：答えを待たずに、札を替える。
    func setImageRoute(_ id: UUID, _ route: ChatMode.ImageRoute) { state.entries.setRoute(id, route) }

    /// 答えが来た。`startedNew`：しばらく話さなかったので、前の会話は、終わった（古い記録を消す）。
    func finish(_ id: UUID, answer: String, activities: [ChatActivity], notes: [String], startedNew: Bool, imageRoute: ChatMode.ImageRoute? = nil) {
        state.entries.finish(id, answer: answer, rendered: Self.render(answer), activities: activities, notes: notes, route: imageRoute, startedNew: startedNew)
        state.scrollToken += 1
    }

    /// 中断・取りやめた：質問を、理由つきで残す（会話の記録には、入らない）。
    func stop(_ id: UUID, reason: String) { state.entries.stop(id, reason: reason) }

    /// 答えを作れなかった：質問を、理由つきで残す。
    func fail(_ id: UUID, message: String) { state.entries.fail(id, message: message) }

    /// 記録を、すべて消す（会話の終了・リセット）。添えた画像も、外す。
    func clear() {
        state.entries = []
        detachImage()
    }

    // MARK: 画像の添付（「画面を撮る」）

    /// 質問に使う、添えてある画像（撮ってから 180 秒以内）。なければ nil。
    var attachedImageFile: URL? {
        guard state.image != nil else { return nil }
        guard case let .success(file) = ScreenshotStore.current() else { detachImage(); return nil }
        return file
    }

    /// 範囲を選んで撮り、会話に添える（このウィンドウは、撮るあいだ、隠す）。撮った画像は、`ScreenshotStore`（180 秒で古くなる・自分だけが読める）。
    func attachScreenshot() async {
        guard !state.capturing else { return }
        state.capturing = true
        defer { state.capturing = false }
        window?.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(250))   // ウィンドウが消えるのを待つ（撮る画面に、写らないように）
        let outcome = await ScreenCapture.captureForVoice()
        show(activate: true)
        switch outcome {
        case .captured:
            guard case let .success(file) = ScreenshotStore.current(), let thumbnail = HUDImage.load(file, sendsOut: false)?.thumbnail else { return }
            let image = AttachedImage(thumbnail: thumbnail, takenAt: Date())
            state.image = image
            expiry?.cancel()
            // 古くなったら、外す（使えない画像を、添えたままにしない）
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ScreenshotStore.timeToLive))
                guard !Task.isCancelled, self?.state.image?.id == image.id else { return }
                self?.detachImage()
            }
        case .cancelled: break
        case let .failed(reason):
            HUD.shared.show(HUDContent(phase: .failure, title: "画面を撮れませんでした", hint: reason), hideAfter: 5)
        }
    }

    /// 添えた画像を外す（撮った画像も、消す）。
    func detachImage() {
        expiry?.cancel()
        expiry = nil
        guard state.image != nil else { return }
        state.image = nil
        ScreenshotStore.clear()
    }

    // MARK: 表示

    /// 出す。`activate`：前に出して、アプリを前面にする（出ているときの更新では、奪わない）。
    func show(activate: Bool) {
        let window = makeWindowIfNeeded()
        if !window.isVisible {
            window.alphaValue = 0
            window.setFrame(ScreenPlacement.windowFrame(size: window.frame.size, minSize: window.minSize, in: ScreenPlacement.currentVisibleFrame()), display: false)
            // 利用者の操作を、邪魔しない：自動で出すとき（`activate` なし）は、キーを奪わない
            if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 1
            }
            if activate { NSApplication.shared.activate(ignoringOtherApps: true) }
        } else {
            window.orderFrontRegardless()
        }
        // 初めて出すとき、中身の配置を、先に済ませる（キーでないウィンドウで、最初の描画が、遅れて、空に見えないように）
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
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
    /// 見た目の確認用：**ウィンドウを作る前に**、質問と答えを記録しておいて、そのあと、ウィンドウを出す（パネルが出ていない間に会話して、あとから開く流れ）。
    func previewLateWindow() -> NSWindow {
        let id = begin(question: "ウィンドウがないときの質問", agent: "Apple のモデル", warning: nil, tools: nil)
        finish(id, answer: "答えは、ウィンドウを作る前に、届きました。**これが見えれば、よい**です。", activities: [], notes: [], startedNew: false)
        let window = makeWindowIfNeeded()
        state.solid = true
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// 見本の画像（絵だけ。見た目の確認用）。
    private static func sampleThumbnail() -> NSImage {
        return NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1), NSColor(red: 0.5, green: 0.3, blue: 0.7, alpha: 1)])?.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 54, width: 90, height: 12), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 34, width: 120, height: 8), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    /// 見た目の確認用（`vc chat-preview`）：本物のウィンドウに、見本の状態（添えた画像・読み上げの札）を、決める。
    func previewState(attachedImage: Bool? = nil, speaking: Bool? = nil, header: (agent: String, warning: String?, tools: String?)? = nil) {
        if let attachedImage { state.image = attachedImage ? AttachedImage(thumbnail: Self.sampleThumbnail(), takenAt: Date().addingTimeInterval(-20)) : nil }
        if let speaking { state.speaking = speaking; state.speakingEntry = speaking ? state.entries.last?.id : nil }
        if let header { state.agent = header.agent; state.warning = header.warning; state.tools = header.tools }
    }

    func previewWindow(pendingOnly: Bool = false) -> NSWindow {
        let window = makeWindowIfNeeded()
        state.agent = "Claude Code"
        state.warning = "この Mac の外へ送信"
        state.tools = "すべて"
        func entry(_ question: String, answer: String?, status: String? = nil, activities: [ChatActivity] = [], notes: [String] = []) -> ChatEntry {
            var e = ChatEntry(question: question)
            e.status = status
            e.answer = answer
            e.outcome = answer == nil ? .pending : .answered
            e.rendered = answer.map { Self.render($0) }
            e.activities = activities
            e.notes = notes
            return e
        }
        state.entries = [
            entry("このフォルダのファイルを、一覧にして", answer: "## 見つけたファイル\n\nフォルダには、次の 2 つがあります。\n\n| 名前 | 内容 |\n|---|---|\n| **note.txt** | メモ（16 バイト） |\n| **memo.txt** | 「確認済み」 |\n\n1. `memo.txt` は、さっき作りました\n2. 詳しくは [公式の説明](https://example.com/doc) を見てください\n\n> 書き込みは、作業フォルダの中だけです。\n\n```sh\nls -la\n```", activities: [.run("ls -la"), .write("memo.txt")]),
            entry("東京の明日の天気は？", answer: "明日の東京は、**晴れ時々くもり**で、最高気温は 24 度の予報です。降水確率は午前 10%、午後 30% で、夕方から風が少し強くなります。傘は、念のため、持っていくと安心です。気温の変化が大きいので、薄手の上着があると、朝晩の移動が楽になります。", notes: ["しばらく話さなかったので、前の会話は終わりました"]),
            entry("ギフティのニュースを、調べて", answer: nil, status: nil),
            entry("もう少し詳しく教えて", answer: nil, status: ChatActivity.search("東京 天気 明日").text),
        ]
        let sample = Self.sampleThumbnail()
        state.image = AttachedImage(thumbnail: sample, takenAt: Date().addingTimeInterval(-40))
        state.entries[0].image = EntryImage(thumbnail: sample, route: .sent("claude"))
        state.entries[1].image = EntryImage(thumbnail: sample, route: .local)
        state.entries[2].outcome = .stopped("新しい質問を優先しました")
        state.keyHint = "右 ⌥（ropt）"
        state.submit = { _ in }
        if pendingOnly { state.entries = Array(state.entries.suffix(2)); state.image = nil; state.speaking = false } else { state.speaking = true; state.speakingEntry = state.entries.first?.id }
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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]   // Space（デスクトップ）を移動しても、ついてくる（どの Space でも、同じ位置に出る）
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
            attach: { Task { @MainActor in await ChatWindow.shared.attachScreenshot() } },
            detach: { ChatWindow.shared.detachImage() },
            copyAll: { [unowned self] in copyAll() },
            close: { [unowned window] in window.close() })
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        self.window = window
        return window
    }

    /// 答えを整形する（終わりの、空の行は、除く：カードの下に、余白ができるため）。
    private static func render(_ markdown: String) -> NSAttributedString {
        let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer.render(markdown, imageBase: ChatMode.shared.folder ?? ExternalChatBackend.defaultFolder))
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

/// 会話に添えた画像。
struct AttachedImage: Identifiable {
    let id = UUID()
    let thumbnail: NSImage
    let takenAt: Date
    /// これを過ぎると、使えない（`ScreenshotStore.timeToLive`）。
    var expiresAt: Date { takenAt.addingTimeInterval(ScreenshotStore.timeToLive) }
}

/// 会話のキーの、いまの状態。
enum ChatVoiceState: Equatable {
    case idle
    /// キーを押している間、聞いている。
    case listening
    /// 離した：文字にしている。
    case recognizing
}

/// 画面の状態。SwiftUI の `@State` は、この環境（コマンドラインツールだけ）では、マクロのプラグインがなく使えないので、参照型にする。
@MainActor final class ChatWindowState: ObservableObject {
    @Published var entries: [ChatEntry] = []
    /// 声の状態（会話のキーの録音・認識）。ウィンドウの下の案内に出す。
    @Published var voice = ChatVoiceState.idle
    /// 会話のキーの名前（案内用。なければ、キーなし）。
    @Published var keyHint: String?
    /// 入力欄の文字。
    @Published var draft = ""
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
    /// 会話に添えてある画像（撮ってから 180 秒だけ、使える）。
    @Published var image: AttachedImage?
    /// 範囲を選んでいる間。
    @Published var capturing = false
    /// 入力欄から質問を送る（声の流れの組み立てが、決める）。
    var submit: (@MainActor (String) -> Void)?
    /// 画像に描く確認用：ガラスの代わりに、暗い面を敷く。
    @Published var solid = false
}
