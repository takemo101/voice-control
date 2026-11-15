import AppKit
import SwiftUI

/// 会話のウィンドウ：**1 つだけ**。質問と答えが、下へ続いていく（答えごとに、新しいウィンドウを開かない）。
/// - 質問が分かった時点で、質問と「考えています…」（外のエージェントの実行中は、いまの操作）を出し、答えが来たら、同じ場所を、答えに置き換える。
/// - 答えは Markdown を整形して見せる。**実行した操作**（外のエージェントが、道具で、やったこと）は、答えの下に出す。
/// - 記録は、**メモリだけ**（会話を終えたら・リセットしたら・しばらく話さなかったら、消える。保存しない）。
/// - 読み上げの最中は、「読み上げを止める」を出す。Esc は、読み上げを先に止める（もう一度で、閉じる）。
/// メインスレッドで使う。
@MainActor final class ChatWindow: NSObject, NSWindowDelegate {
    static let shared = ChatWindow()

    struct Turn {
        var question: String
        var status: String? = "考えています…"
        var answer: String?
        var activities: [String] = []
        var notes: [String] = []
        /// 答えを整形した結果（描き直しのたびに、作り直さない）。
        var rendered: NSAttributedString?
    }

    private(set) var turns: [Turn] = []
    private let state = ChatWindowState()
    private let textView = NSTextView()
    private var window: DocumentWindowFrame?

    var isVisible: Bool { window?.isVisible == true }
    var hasPending: Bool { turns.last?.answer == nil && !turns.isEmpty }

    private override init() {
        super.init()
        SaySpeaker.shared.observe { [weak self] speaking in self?.state.speaking = speaking }
        state.speaking = SaySpeaker.shared.isSpeaking
    }

    // MARK: 記録の更新

    /// 質問が分かった：質問と「考えています…」を出す（ウィンドウが出ていれば、すぐ見える）。
    func begin(question: String, agent: String) {
        discardPending()
        turns.append(Turn(question: question))
        state.subtitle = agent
        redraw(scrollToLast: true)
    }

    /// 実行中の様子（外のエージェントの、いまの操作など）。
    func setStatus(_ text: String) {
        guard hasPending else { return }
        turns[turns.count - 1].status = text
        redraw(scrollToLast: true)
    }

    /// 答えが来た。`startedNew`：しばらく話さなかったので、前の会話は、終わった（古い記録を消す）。
    func finish(answer: String, activities: [String], notes: [String], startedNew: Bool) {
        guard hasPending else { return }
        if startedNew { turns = [turns[turns.count - 1]] }
        turns[turns.count - 1].status = nil
        turns[turns.count - 1].answer = answer
        turns[turns.count - 1].activities = activities
        turns[turns.count - 1].notes = notes
        redraw(scrollToLast: true)
    }

    /// 答えが出なかった（失敗・取りやめ）：待ちの質問を、取り除く。
    func discardPending() {
        guard hasPending else { return }
        turns.removeLast()
        redraw(scrollToLast: false)
    }

    /// 記録を、すべて消す（会話の終了・リセット）。
    func clear() {
        turns = []
        redraw(scrollToLast: false)
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
        redraw(scrollToLast: true)
    }

    func hide() { window?.orderOut(nil) }

    /// 見た目の確認用（`vc settings-preview --chat`）：見本の会話を入れて、画面の外に置いたウィンドウを返す（利用者の画面には、出ない）。
    func previewWindow() -> NSWindow {
        let window = makeWindowIfNeeded()
        state.subtitle = "Claude Code（claude。Anthropic） — この Mac の外へ送信・すべて（書き込み・コマンドの実行も）"
        turns = [
            Turn(question: "このフォルダのファイルを、一覧にして", status: nil, answer: "フォルダには、次の 2 つがあります。\n\n- **note.txt**：メモ（16 バイト）\n- **memo.txt**：「確認済み」と書いたファイル\n\n`memo.txt` は、さっき作りました。", activities: ["実行: ls -la", "書く: memo.txt"], notes: [], rendered: nil),
            Turn(question: "東京の明日の天気は？", status: nil, answer: "明日の東京は、**晴れ時々くもり**で、最高気温は 24 度の予報です。", activities: [], notes: ["しばらく話さなかったので、前の会話は終わりました"], rendered: nil),
            Turn(question: "もう少し詳しく教えて", status: "検索: 東京 天気 明日", answer: nil, activities: [], notes: [], rendered: nil),
        ]
        state.speaking = true
        state.solid = true
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.makeKeyAndOrderFront(nil)
        redraw(scrollToLast: true)
        return window
    }

    func windowWillClose(_ notification: Notification) {}

    private func makeWindowIfNeeded() -> DocumentWindowFrame {
        if let window { return window }
        let window = DocumentWindowFrame(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 380, height: 320)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.onEscape = {
            guard SaySpeaker.shared.isSpeaking else { return false }
            SaySpeaker.shared.stop()
            return true
        }
        configureTextView()
        let root = ChatView(
            state: state, textView: textView,
            stopSpeaking: { SaySpeaker.shared.stop() },
            reset: { AppActions.resetConversation() },
            copy: { [unowned self] in copyAll() },
            close: { [unowned window] in window.close() })
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        window.textView = textView
        self.window = window
        return window
    }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 16)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.selectedTextAttributes = [.backgroundColor: NSColor.systemTeal.withAlphaComponent(0.35)]
        textView.linkTextAttributes = [.foregroundColor: NSColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    private func copyAll() {
        let text = turns.map { turn in
            "あなた：\(turn.question)\n\n" + (turn.answer ?? "") + (turn.activities.isEmpty ? "" : "\n\n実行した操作：\n" + turn.activities.map { "- \($0)" }.joined(separator: "\n"))
        }.joined(separator: "\n\n---\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.state.copied = false }
    }

    // MARK: 描く

    private func redraw(scrollToLast: Bool) {
        state.hasTurns = !turns.isEmpty
        guard window != nil else { return }
        let out = NSMutableAttributedString()
        var lastStart = 0
        if turns.isEmpty {
            out.append(NSAttributedString(string: "まだ、会話がありません。\n\nキーを押して話しかけると、ここに、質問と答えが、続いていきます。", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: HUDStyle.secondary]))
        }
        for index in turns.indices {
            if index > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 10)])) }
            lastStart = out.length
            if turns[index].answer != nil, turns[index].rendered == nil { turns[index].rendered = MarkdownRenderer.render(turns[index].answer ?? "") }
            out.append(Self.render(turns[index], first: index == 0))
        }
        textView.textStorage?.setAttributedString(out)
        guard scrollToLast, !turns.isEmpty, let container = textView.textContainer, let layout = textView.layoutManager else { return }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: lastStart, length: 1), actualCharacterRange: nil)
        let top = layout.boundingRect(forGlyphRange: glyphs, in: container).minY + textView.textContainerInset.height
        // 新しい質問の頭が、見える位置へ（答えが長くても、頭から読める）
        textView.scroll(NSPoint(x: 0, y: max(0, top - 8)))
    }

    private static func label(_ text: String, color: NSColor, spacing: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacing
        style.paragraphSpacing = 4
        return NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color, .paragraphStyle: style, .kern: 0.6])
    }

    private static func render(_ turn: Turn, first: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let accent = NSColor(red: 0.40, green: 0.82, blue: 1.0, alpha: 1)
        out.append(label("あなた", color: accent, spacing: first ? 0 : 14))
        let questionStyle = NSMutableParagraphStyle()
        questionStyle.paragraphSpacing = 10
        questionStyle.lineHeightMultiple = 1.2
        out.append(NSAttributedString(string: turn.question + "\n", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.78), .paragraphStyle: questionStyle]))
        out.append(label("回答", color: NSColor(white: 1, alpha: 0.5), spacing: 2))
        if let rendered = turn.rendered {
            out.append(rendered)
        } else if let status = turn.status {
            out.append(NSAttributedString(string: status + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: accent.withAlphaComponent(0.9)]))
        }
        if !turn.activities.isEmpty {
            out.append(label("実行した操作", color: NSColor.systemOrange, spacing: 8))
            for activity in turn.activities {
                out.append(NSAttributedString(string: "▸ " + activity + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: HUDStyle.secondary]))
            }
        }
        for note in turn.notes {
            out.append(NSAttributedString(string: note + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.45)]))
        }
        return out
    }
}

/// 画面の状態（読み上げ中か・コピーしたか・記録があるか）。
@MainActor final class ChatWindowState: ObservableObject {
    @Published var speaking = false
    @Published var copied = false
    @Published var subtitle = ""
    @Published var hasTurns = false
    /// 画像に描く確認用：ガラスの代わりに、暗い面を敷く。
    @Published var solid = false
}

private struct ChatView: View {
    @ObservedObject var state: ChatWindowState
    let textView: NSTextView
    let stopSpeaking: () -> Void
    let reset: () -> Void
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            header
            Rule()
            TextBody(textView: textView)
                .mask(VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                })
            Rule()
            footer
        }
        .modifier(Surface(solid: state.solid, shape: shape))
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), DocumentPalette.accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .clipShape(shape)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(DocumentPalette.accent.opacity(0.2)).frame(width: 28, height: 28)
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(DocumentPalette.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("会話").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                if !state.subtitle.isEmpty {
                    Text(state.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if state.speaking {
                Label("読み上げ中", systemImage: "speaker.wave.2.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DocumentPalette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(DocumentPalette.accent.opacity(0.15)))
            }
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.45))
            }.buttonStyle(.plain).accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(DragArea())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.speaking {
                PillButton(title: "読み上げを止める  esc", symbol: "speaker.slash.fill", flashed: false, action: stopSpeaking)
            }
            PillButton(title: "コピー", symbol: "doc.on.doc", flashed: state.copied, action: copy)
            PillButton(title: "リセット", symbol: "arrow.counterclockwise", flashed: false, action: reset)
            Spacer(minLength: 8)
            PillButton(title: "閉じる", symbol: "xmark", flashed: false, cancel: !state.speaking, action: close)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(DragArea())
    }
}

/// 面：ふだんは、ガラス。**画像に描く確認用**（`solid`）は、暗い面（ガラスは、画像には描けず、白くなる）。
private struct Surface: ViewModifier {
    let solid: Bool
    let shape: RoundedRectangle

    @ViewBuilder func body(content: Content) -> some View {
        if solid {
            content.background(shape.fill(Color(white: 0.13)))
        } else {
            content.glassEffect(.regular.tint(DocumentPalette.accent.opacity(0.06)), in: shape)
        }
    }
}
