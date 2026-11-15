import AppKit
import SwiftUI
import VCSkill

/// 会話ウィンドウの見た目（SwiftUI）：質問の吹き出し・答えのカード・実行した操作・考え中の表示・ヘッダーとフッター。状態は `ChatWindowState`（`ChatWindow.swift`）。

// MARK: 見た目

private enum ChatPalette {
    static let accent = DocumentPalette.accent
    static let blue = Color(red: 0.30, green: 0.58, blue: 1.0)
    static let purple = Color(red: 0.58, green: 0.40, blue: 0.96)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.25)
    static var bubble: LinearGradient { LinearGradient(colors: [blue.opacity(0.85), purple.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var brand: LinearGradient { LinearGradient(colors: [accent, purple], startPoint: .topLeading, endPoint: .bottomTrailing) }
}

struct ChatView: View {
    @ObservedObject var state: ChatWindowState
    let stopSpeaking: () -> Void
    let speak: (ChatEntry) -> Void
    let reset: () -> Void
    let attach: () -> Void
    let detach: () -> Void
    let copyAll: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            header
            Rule()
            transcript
            if let image = state.image {
                Rule()
                AttachmentBar(image: image, external: state.warning != nil, detach: detach)
            }
            Rule()
            ComposerBar(state: state)
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
                // `LazyVStack` にしない：初めて開いたとき、表示の範囲が決まる前に、中身が作られず、会話が空に見えた（利用者の報告）。往復は、少ないので、遅延させる意味がない
                VStack(alignment: .leading, spacing: 22) {
                    if state.entries.isEmpty { EmptyState().frame(maxWidth: .infinity).padding(.top, 60) }
                    ForEach(state.entries) { entry in
                        EntryView(entry: entry, speakingThis: state.speakingEntry == entry.id, stopSpeaking: stopSpeaking, speak: speak).id(entry.id)
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
            .onAppear {
                guard let last = state.entries.last?.id else { return }
                proxy.scrollTo(last, anchor: .top)
            }
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
            PillButton(title: state.image == nil ? "画面を撮る" : "撮り直す", symbol: "camera.viewfinder", flashed: false, action: attach)
            PillButton(title: "コピー", symbol: "doc.on.doc", flashed: state.copied, action: copyAll)
            PillButton(title: "リセット", symbol: "arrow.counterclockwise", flashed: false, action: reset)
            Spacer(minLength: 8)
            PillButton(title: "閉じる", symbol: "xmark", flashed: false, cancel: !state.speaking, action: close)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(DragArea())
    }
}

/// 中断・失敗した往復の、表示（点線のカード。会話の記録には、入っていない）。
private struct OutcomeNote: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(color)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 下の入力帯：**いま何ができるか・何が起きているか**を、1 行で見せる（キーの案内・聞いている・認識中・考えている）と、文字で質問する欄。
private struct ComposerBar: View {
    @ObservedObject var state: ChatWindowState

    private var busy: Bool { state.entries.hasPending }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            guide
            if state.submit != nil {
                HStack(spacing: 8) {
                    TextField(busy ? "考えている間は、送れません（話して、中断もできます）" : "メッセージを入力（Enter で送信）", text: $state.draft)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.09)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.7))
                        .disabled(busy)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundStyle(canSend ? AnyShapeStyle(ChatPalette.brand) : AnyShapeStyle(Color.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain).disabled(!canSend).accessibilityLabel("送信")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var canSend: Bool { !busy && !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let submit = state.submit else { return }
        state.draft = ""
        submit(text)
    }

    /// いまの状態の案内。
    @ViewBuilder private var guide: some View {
        switch state.voice {
        case .listening:
            HStack(spacing: 7) {
                TimelineView(.animation) { context in
                    Circle().fill(Color.red).frame(width: 9, height: 9).opacity(0.45 + 0.55 * abs(sin(context.date.timeIntervalSinceReferenceDate * 3)))
                }
                Text("聞いています…（離すと送信・Esc で取りやめ）").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.red.opacity(0.95))
            }
        case .recognizing:
            Label("文字にしています…", systemImage: "waveform").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ChatPalette.accent)
        case .idle:
            if busy {
                Label("考えています…（話すと、この質問を中断して、新しい質問を優先します）", systemImage: "hourglass").font(.system(size: 11.5)).foregroundStyle(ChatPalette.accent.opacity(0.9))
            } else if let key = state.keyHint {
                Label("\(key) を押している間、話します", systemImage: "mic.fill").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            } else {
                Label("会話のキーが、決まっていません（設定 > キー）。文字で質問できます", systemImage: "mic.slash").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// 質問に付いた画像：**添付されているように**見せる（クリップのアイコン・サムネイル・下に、どう扱われたかの札）。
private struct AttachmentCard: View {
    let image: EntryImage

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: image.thumbnail).resizable().aspectRatio(contentMode: .fill).frame(width: 200, height: 116).clipped()
            HStack(spacing: 6) {
                Image(systemName: "paperclip").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                Text("画像").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 4)
                RouteChip(route: image.route)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.black.opacity(0.35))
        }
        .frame(width: 200)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

/// 画像が、どう扱われたか（読んでいる・この Mac の中で読んだ・外へ送った・送っていない）。
private struct RouteChip: View {
    let route: ChatMode.ImageRoute?

    var body: some View {
        let (text, symbol, color): (String, String, Color) = {
            switch route {
            case nil: return ("読んでいます…", "ellipsis", .white.opacity(0.6))
            case let .confirming(agent)?: return ("\(agent) へ送る確認待ち", "hourglass", ChatPalette.orange)
            case .local?: return ("この Mac の中で処理", "lock.fill", Color(red: 0.35, green: 0.85, blue: 0.6))
            case let .sent(agent)?: return ("\(agent) へ送信", "arrow.up.forward.circle.fill", ChatPalette.orange)
            case .declined?: return ("送信しませんでした", "xmark.circle.fill", .white.opacity(0.6))
            case let .notUsed(reason)?: return (reason, "exclamationmark.triangle.fill", .white.opacity(0.6))
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

/// 会話に添えてある画像：サムネイルと、使えなくなるまでの時間。外のエージェントへは、**送るたびに確認する**ことを、断る。
private struct AttachmentBar: View {
    let image: AttachedImage
    /// 外のエージェントか（送る前に、確認する）。
    let external: Bool
    let detach: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: image.thumbnail).resizable().aspectRatio(contentMode: .fill).frame(width: 64, height: 42).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text("画像を、会話に添えています").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(image.expiresAt.timeIntervalSince(context.date)))
                    Text("あと \(left / 60):\(String(format: "%02d", left % 60)) で、使えなくなります" + (external ? "・送る前に、確認します" : ""))
                        .font(.system(size: 11)).foregroundStyle(external ? ChatPalette.orange : .white.opacity(0.5))
                }
            }
            Spacer(minLength: 8)
            PillButton(title: "外す", symbol: "xmark", flashed: false, action: detach)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.white.opacity(0.04))
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
    /// この答えを、読んでいるところ。
    let speakingThis: Bool
    let stopSpeaking: () -> Void
    let speak: (ChatEntry) -> Void

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
                if let image = entry.image { AttachmentCard(image: image) }
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
                switch entry.outcome {
                case .pending:
                    Pending(status: entry.status ?? "考えています…")
                case .answered:
                    if let rendered = entry.rendered { RichText(attributed: rendered).frame(maxWidth: .infinity, alignment: .leading) }
                    if !entry.activities.isEmpty { activities.padding(.top, 4) }
                    ForEach(entry.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                    if let answer = entry.answer { actions(answer) }
                case let .stopped(reason):
                    OutcomeNote(symbol: "stop.circle.fill", title: "中断しました", detail: reason + "。この質問は、会話の記録に入っていません（もう一度、聞いてください）", color: .white.opacity(0.6))
                case let .failed(message):
                    OutcomeNote(symbol: "exclamationmark.triangle.fill", title: "答えを作れませんでした", detail: message, color: ChatPalette.orange)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(entry.outcome == .answered || entry.isPending ? 0.07 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), style: StrokeStyle(lineWidth: 0.7, dash: entry.outcome == .answered || entry.isPending ? [] : [4, 3])))
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
                    Image(systemName: Self.symbol(for: activity.kind)).font(.system(size: 10, weight: .semibold)).foregroundStyle(ChatPalette.orange.opacity(0.9)).frame(width: 14)
                    Text(activity.text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.72)).lineLimit(2).textSelection(.enabled)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.22)))
            }
        }
    }

    static func symbol(for kind: ChatActivity.Kind) -> String {
        switch kind {
        case .run: return "terminal.fill"
        case .search: return "magnifyingglass"
        case .fetch: return "globe"
        case .read: return "doc.text.fill"
        case .write: return "square.and.pencil"
        case .list: return "folder.fill"
        case .find: return "text.magnifyingglass"
        case .other: return "wrench.and.screwdriver.fill"
        }
    }

    private func actions(_ answer: String) -> some View {
        HStack(spacing: 6) {
            SmallAction(symbol: speakingThis ? "speaker.slash.fill" : "speaker.wave.2.fill", title: speakingThis ? "止める" : "読み上げ") {
                if speakingThis { stopSpeaking() } else { speak(entry) }
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
        view.textContainer?.widthTracksTextView = true   // 折り返しの幅は、実際に置かれた幅に、合わせる
        _ = view.layoutManager   // 表（`NSTextTable`）を使うので、従来のレイアウト（TextKit 1）にする
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

    /// 高さを測る：**表示している `NSTextView` の折り返しの幅には、触れない**（実際に置かれた幅に、自分で合わせる：`widthTracksTextView`）。測るだけの別のレイアウトで、与えられた幅の高さを求める。
    /// （以前は、表示している側の幅を、測るたびに書き換えていて、最後の問い合わせの幅が残り、実際の幅より広く折り返して、カードから文字がはみ出した。）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let current = view.textStorage else { return nil }
        let width = max(80, proposal.width ?? 400)
        let storage = NSTextStorage(attributedString: current)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
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
