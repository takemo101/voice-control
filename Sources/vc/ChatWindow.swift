import AppKit
import SwiftUI

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
        SaySpeaker.shared.observe { [weak self] speaking in self?.state.speaking = speaking }
        state.speaking = SaySpeaker.shared.isSpeaking
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
    func finish(answer: String, activities: [String], notes: [String], startedNew: Bool) {
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

    func hide() { window?.orderOut(nil) }

    func windowWillClose(_ notification: Notification) {}

    /// 見た目の確認用（`vc settings-preview --chat`）：見本の会話を入れて、画面の外に置いたウィンドウを返す（利用者の画面には、出ない）。
    func previewWindow(pendingOnly: Bool = false) -> NSWindow {
        let window = makeWindowIfNeeded()
        state.agent = "Claude Code"
        state.warning = "この Mac の外へ送信"
        state.tools = "すべて"
        func entry(_ question: String, answer: String?, status: String? = nil, activities: [String] = [], notes: [String] = []) -> ChatEntry {
            var e = ChatEntry(question: question)
            e.status = status
            e.answer = answer
            e.rendered = answer.map { Self.render($0) }
            e.activities = activities
            e.notes = notes
            return e
        }
        state.entries = [
            entry("このフォルダのファイルを、一覧にして", answer: "フォルダには、次の 2 つがあります。\n\n- **note.txt**：メモ（16 バイト）\n- **memo.txt**：「確認済み」と書いたファイル\n\n`memo.txt` は、さっき作りました。", activities: ["実行: ls -la", "書く: memo.txt"]),
            entry("東京の明日の天気は？", answer: "明日の東京は、**晴れ時々くもり**で、最高気温は 24 度の予報です。", notes: ["しばらく話さなかったので、前の会話は終わりました"]),
            entry("もう少し詳しく教えて", answer: nil, status: "検索: 東京 天気 明日"),
        ]
        if pendingOnly { state.entries = Array(state.entries.suffix(2)); state.speaking = false } else { state.speaking = true }
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
            guard SaySpeaker.shared.isSpeaking else { return false }
            SaySpeaker.shared.stop()
            return true
        }
        let root = ChatView(
            state: state,
            stopSpeaking: { SaySpeaker.shared.stop() },
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
            "あなた：\(entry.question)\n\n" + (entry.answer ?? "") + (entry.activities.isEmpty ? "" : "\n\n実行した操作：\n" + entry.activities.map { "- \($0)" }.joined(separator: "\n"))
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
    var activities: [String] = []
    var notes: [String] = []
    /// 答えを整形した結果（描き直しのたびに、作り直さない）。
    var rendered: NSAttributedString?
}

/// 画面の状態。SwiftUI の `@State` は、この環境（コマンドラインツールだけ）では、マクロのプラグインがなく使えないので、参照型にする。
@MainActor final class ChatWindowState: ObservableObject {
    @Published var entries: [ChatEntry] = []
    @Published var speaking = false
    @Published var copied = false
    @Published var agent = ""
    @Published var warning: String?
    @Published var tools: String?
    /// 増えると、いちばん新しい往復の頭へ、スクロールする。
    @Published var scrollToken = 0
    /// 画像に描く確認用：ガラスの代わりに、暗い面を敷く。
    @Published var solid = false
}

// MARK: 見た目

private enum ChatPalette {
    static let accent = DocumentPalette.accent
    static let blue = Color(red: 0.30, green: 0.58, blue: 1.0)
    static let purple = Color(red: 0.58, green: 0.40, blue: 0.96)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.25)
    static var bubble: LinearGradient { LinearGradient(colors: [blue.opacity(0.85), purple.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var brand: LinearGradient { LinearGradient(colors: [accent, purple], startPoint: .topLeading, endPoint: .bottomTrailing) }
}

private struct ChatView: View {
    @ObservedObject var state: ChatWindowState
    let stopSpeaking: () -> Void
    let reset: () -> Void
    let copyAll: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            header
            Rule()
            transcript
            Rule()
            footer
        }
        .modifier(Surface(solid: state.solid, shape: shape))
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), ChatPalette.accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .clipShape(shape)
    }

    // MARK: ヘッダー

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(ChatPalette.brand).frame(width: 34, height: 34)
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            .shadow(color: ChatPalette.purple.opacity(0.45), radius: 8, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("会話").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 6) {
                    if !state.agent.isEmpty { Text(state.agent).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
                    if let tools = state.tools { Chip(text: tools, symbol: "wrench.and.screwdriver.fill", color: ChatPalette.accent) }
                    if let warning = state.warning { Chip(text: warning, symbol: "arrow.up.forward.circle.fill", color: ChatPalette.orange) }
                }
            }
            Spacer(minLength: 8)
            if state.speaking { SpeakingBadge() }
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.45))
            }.buttonStyle(.plain).accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(DragArea())
    }

    // MARK: 本文

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if state.entries.isEmpty { EmptyState().frame(maxWidth: .infinity).padding(.top, 60) }
                    ForEach(state.entries) { entry in
                        EntryView(entry: entry, speaking: state.speaking, stopSpeaking: stopSpeaking).id(entry.id)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 22)
            }
            .scrollIndicators(.never)
            // 上下の端は、すっと消える（スクロールの途中で、文字が、線で切れない）
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
            })
            // いちばん新しい往復の頭へ（答えが長くても、質問から読める）
            .onChange(of: state.scrollToken) {
                guard let last = state.entries.last?.id else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last, anchor: .top) }
            }
        }
    }

    // MARK: フッター

    private var footer: some View {
        HStack(spacing: 10) {
            if state.speaking {
                PillButton(title: "読み上げを止める  esc", symbol: "speaker.slash.fill", flashed: false, action: stopSpeaking)
            }
            PillButton(title: "コピー", symbol: "doc.on.doc", flashed: state.copied, action: copyAll)
            PillButton(title: "リセット", symbol: "arrow.counterclockwise", flashed: false, action: reset)
            Spacer(minLength: 8)
            PillButton(title: "閉じる", symbol: "xmark", flashed: false, cancel: !state.speaking, action: close)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(DragArea())
    }
}

/// 小さな札（アイコンと文字。色つき）。
private struct Chip: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// 読み上げ中の、波打つ棒。
private struct SpeakingBadge: View {
    var body: some View {
        HStack(spacing: 7) {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(ChatPalette.accent).frame(width: 2.5, height: 5 + 9 * abs(sin(t * 5 + Double(i) * 0.9)))
                    }
                }
                .frame(height: 14)
            }
            Text("読み上げ中").font(.system(size: 11, weight: .semibold)).foregroundStyle(ChatPalette.accent)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(ChatPalette.accent.opacity(0.14)))
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(ChatPalette.brand.opacity(0.22)).frame(width: 64, height: 64)
                Image(systemName: "waveform.and.mic").font(.system(size: 26, weight: .semibold)).foregroundStyle(ChatPalette.brand)
            }
            Text("話しかけてみましょう").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Text("会話のキーを押している間、話します。\n質問と答えが、ここに続いていきます。").font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: 1 往復

private struct EntryView: View {
    let entry: ChatEntry
    let speaking: Bool
    let stopSpeaking: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            userBubble
            assistantCard
        }
    }

    /// 質問：右の吹き出し。
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.question)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5, topTrailingRadius: 18, style: .continuous).fill(ChatPalette.bubble))
                    .shadow(color: ChatPalette.blue.opacity(0.28), radius: 8, y: 3)
                Text(entry.asked, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.white.opacity(0.32)).padding(.trailing, 4)
            }
        }
    }

    /// 答え：左の、アイコンつきのカード。
    private var assistantCard: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.10)).frame(width: 28, height: 28)
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(ChatPalette.brand)
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 10) {
                if let rendered = entry.rendered {
                    RichText(attributed: rendered).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Pending(status: entry.status ?? "考えています…")
                }
                if !entry.activities.isEmpty { activities.padding(.top, 4) }
                ForEach(entry.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                if let answer = entry.answer { actions(answer) }
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.7))
        }
    }

    /// 実行した操作（種類ごとのアイコン）。
    private var activities: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                Text("実行した操作").font(.system(size: 10, weight: .bold)).kerning(0.5)
            }
            .foregroundStyle(ChatPalette.orange)
            ForEach(Array(entry.activities.enumerated()), id: \.offset) { _, activity in
                HStack(spacing: 7) {
                    Image(systemName: Self.symbol(for: activity)).font(.system(size: 10, weight: .semibold)).foregroundStyle(ChatPalette.orange.opacity(0.9)).frame(width: 14)
                    Text(activity).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.72)).lineLimit(2).textSelection(.enabled)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.22)))
            }
        }
    }

    static func symbol(for activity: String) -> String {
        switch activity.prefix(while: { $0 != ":" && $0 != "：" }) {
        case "実行": return "terminal.fill"
        case "検索": return "magnifyingglass"
        case "取得": return "globe"
        case "読む": return "doc.text.fill"
        case "書く": return "square.and.pencil"
        case "一覧": return "folder.fill"
        case "探す": return "text.magnifyingglass"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    private func actions(_ answer: String) -> some View {
        HStack(spacing: 6) {
            SmallAction(symbol: speaking ? "speaker.slash.fill" : "speaker.wave.2.fill", title: speaking ? "止める" : "読み上げ") {
                if speaking { stopSpeaking() } else { SaySpeaker.shared.say(chunks: SpokenText.chunks(from: answer)) }
            }
            SmallAction(symbol: "doc.on.doc", title: "コピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            }
        }
        .padding(.top, 2)
    }
}

/// 答えの下の、小さな操作（触れると、明るくなる）。
private struct SmallAction: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hover.on ? 0.95 : 0.55))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(hover.on ? 0.14 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// 考えている間：波打つ点と、いまの操作。
private struct Pending: View {
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(ChatPalette.brand).frame(width: 7, height: 7)
                            .opacity(0.3 + 0.7 * max(0, sin(t * 4.5 - Double(i) * 0.85)))
                            .scaleEffect(0.75 + 0.25 * max(0, sin(t * 4.5 - Double(i) * 0.85)))
                    }
                }
            }
            Text(status).font(.system(size: 12.5, weight: .medium)).foregroundStyle(ChatPalette.accent.opacity(0.9)).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// 整形した文章（`NSTextView`）：文字の選択・⌘C・日本語の組みは、標準のまま。幅に合わせて、高さを決める。
private struct RichText: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false   // 幅は、`sizeThatFits` で決める（実際に置かれる幅で、折り返す）
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.selectedTextAttributes = [.backgroundColor: NSColor.systemTeal.withAlphaComponent(0.35)]
        view.linkTextAttributes = [.foregroundColor: NSColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.textStorage?.string != attributed.string { view.textStorage?.setAttributedString(attributed) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        // 幅が決まっていない問い合わせ（理想の大きさ）では、折り返す幅を、変えない（本当の幅の問い合わせのあとに、狭い幅が残らないように）
        let previous = container.containerSize
        let width = max(80, proposal.width ?? (previous.width > 1000 ? 400 : previous.width))
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        if proposal.width == nil { container.containerSize = previous }
        return CGSize(width: width, height: height)
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
