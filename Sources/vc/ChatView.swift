import AppKit
import SwiftUI
import VCCore
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
                AttachmentBar(image: image, external: state.warning != nil, retake: attach, detach: detach)
            }
            if !state.queue.isEmpty {
                Rule()
                QueueList(state: state)
            }
            Rule()
            ComposerBar(state: state, attach: attach)
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
                Image(systemName: "bubble.left.and.bubble.right.fill").vcFont(14, weight: .semibold).foregroundStyle(.white)
            }
            .shadow(color: ChatPalette.purple.opacity(0.45), radius: 8, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("会話")).vcFont(16, weight: .semibold).foregroundStyle(.white)
                HStack(spacing: 6) {
                    if !state.agent.isEmpty { Text(state.agent).vcFont(11, weight: .medium, maxScale: 1.15).lineLimit(1).fixedSize(horizontal: true, vertical: false).foregroundStyle(.white.opacity(0.6)) }
                    if let tools = state.tools { Chip(text: tools, symbol: "wrench.and.screwdriver.fill", color: ChatPalette.accent) }
                    if let warning = state.warning { Chip(text: warning, symbol: "arrow.up.forward.circle.fill", color: ChatPalette.orange) }
                }
            }
            Spacer(minLength: 8)
            if state.speaking { StopSpeakingButton(action: stopSpeaking) }
            moreMenu
            HeaderIconButton(symbol: "xmark", help: tr("閉じる（Esc）"), cancel: !state.speaking, action: close)
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
            // 上下の端は、すっと消える（スクロールの途中で、文字が、線で切れない）：OS 標準の端の効果。以前の `.mask(グラデーション)` は、スクロールの領域全体を、毎フレーム、画面の外に描き直すので、ガラスの上で、引っ掛かった
            .scrollEdgeEffectStyle(.soft, for: .vertical)
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

    // MARK: 「…」メニュー（たまにしか使わない操作：会話全体のコピーと、新しい会話）

    private var moreMenu: some View {
        Menu {
            Button(action: copyAll) { Label(tr("会話全体をコピー"), systemImage: "doc.on.doc") }
                .disabled(state.entries.isEmpty)
            Divider()
            Button(role: .destructive, action: reset) { Label(tr("新しい会話を始める（いまの記録を消す）"), systemImage: "arrow.counterclockwise") }
                .disabled(state.entries.isEmpty)
        } label: {
            HeaderCircle(symbol: "ellipsis", flashed: state.copied)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(state.copied ? tr("コピーしました") : tr("会話全体のコピー・新しい会話"))
        .accessibilityLabel(tr("そのほかの操作"))
    }
}

/// 入力欄の左の、「画面を撮る」ボタン（撮った画像は、質問に添えられる）。添えているときは、色が付く。撮っている間は、押せない。
private struct AttachButton: View {
    let attached: Bool
    let capturing: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: "camera.viewfinder").vcFont(14, weight: .semibold)
                .foregroundStyle(attached ? ChatPalette.accent : .white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(Circle().fill(attached ? ChatPalette.accent.opacity(0.18) : .white.opacity(hover.on ? 0.20 : 0.10)))
                .overlay(Circle().strokeBorder(attached ? ChatPalette.accent.opacity(0.5) : .white.opacity(0.14), lineWidth: 0.7))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(capturing).onHover { hover.on = $0 }
        .help(attached ? tr("画面を撮り直して、質問に添える") : tr("画面を撮って、質問に添える"))
        .accessibilityLabel(tr("画面を撮る"))
    }
}

/// 読み上げ中の、「止める」ボタン（動く波形つき）。読み上げている間は、Esc が、これを押す（閉じるのではなく）。
private struct StopSpeakingButton: View {
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
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
                Text(tr("読み上げを止める")).vcFont(11, weight: .semibold, maxScale: 1.15).lineLimit(1).foregroundStyle(ChatPalette.accent)
                Text("esc").vcFont(10, weight: .semibold, design: .monospaced, maxScale: 1.15).foregroundStyle(ChatPalette.accent.opacity(0.7))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(ChatPalette.accent.opacity(hover.on ? 0.26 : 0.14)))
            .overlay(Capsule().strokeBorder(ChatPalette.accent.opacity(0.35), lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).keyboardShortcut(.cancelAction).onHover { hover.on = $0 }
        .accessibilityLabel(tr("読み上げを止める"))
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
            Label(title, systemImage: symbol).vcFont(12.5, weight: .semibold).foregroundStyle(color)
            Text(detail).vcFont(11.5).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 下の入力帯：**いま何ができるか・何が起きているか**を、1 行で見せる（キーの案内・聞いている・認識中・考えている）と、文字で質問する欄。
private struct ComposerBar: View {
    @ObservedObject var state: ChatWindowState
    let attach: () -> Void

    private var busy: Bool { state.entries.hasPending }
    private var draftIsEmpty: Bool { state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            guide
            HStack(spacing: 8) {
                AttachButton(attached: state.image != nil, capturing: state.capturing, action: attach)
                if state.submit != nil {
                    TextField(busy ? tr("考えている間は、順番待ちに入ります（Enter）") : tr("メッセージを入力（Enter で送信）"), text: $state.draft)
                        .textFieldStyle(.plain).vcFont(13).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.09)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.7))
                        .onSubmit(send)
                    if busy && draftIsEmpty {
                        // 考えている間で、入力欄が空：送信ボタンが、停止になる（待っている質問も、送らない）
                        Button { state.stopTurn?() } label: {
                            Image(systemName: "stop.circle.fill").vcFont(26).foregroundStyle(ChatPalette.orange)
                        }
                        .buttonStyle(.plain).accessibilityLabel(tr("停止")).help(tr("考えているのを止める（待っている質問は、送りません）"))
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").vcFont(26).foregroundStyle(canSend ? AnyShapeStyle(ChatPalette.brand) : AnyShapeStyle(Color.white.opacity(0.2)))
                        }
                        .buttonStyle(.plain).disabled(!canSend).accessibilityLabel(tr("送信"))
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var canSend: Bool { !draftIsEmpty }

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
                Text(tr("聞いています…（離すと送信・Esc で取りやめ）")).vcFont(11.5, weight: .semibold).foregroundStyle(Color.red.opacity(0.95))
            }
        case .recognizing:
            Label(tr("文字にしています…"), systemImage: "waveform").vcFont(11.5, weight: .semibold).foregroundStyle(ChatPalette.accent)
        case .idle:
            if busy {
                Label(tr("考えています…（話すと、順番待ちに入ります）"), systemImage: "hourglass").vcFont(11.5).foregroundStyle(ChatPalette.accent.opacity(0.9))
            } else if let key = state.keyHint {
                Label(tr("\(key) を押している間、話します"), systemImage: "mic.fill").vcFont(11.5).foregroundStyle(.white.opacity(0.55))
            } else {
                Label(tr("会話のキーが、決まっていません（設定 > キー）。文字で質問できます"), systemImage: "mic.slash").vcFont(11.5).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// 順番待ちの質問（考えている間に送ったもの）：1 件ずつ、「今すぐ送る」（いまの質問を止めて、これを先に）と「取り下げ」。
private struct QueueList: View {
    @ObservedObject var state: ChatWindowState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("順番待ち（いまの質問が終わったら、送ります）"), systemImage: "list.number").vcFont(11, weight: .semibold).foregroundStyle(.white.opacity(0.55))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.queue.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.source == .voice ? "mic.fill" : "keyboard").vcFont(11).foregroundStyle(.white.opacity(0.5)).frame(width: 14)
                            Text(item.text).vcFont(12).foregroundStyle(.white.opacity(0.9)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Button { state.sendNow?(item.id) } label: { Image(systemName: "arrow.turn.down.right") }
                                .buttonStyle(.plain).foregroundStyle(ChatPalette.accent).help(tr("今すぐ送る（いまの質問を止めて、これを先に）"))
                            Button { state.removeQueued?(item.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).help(tr("取り下げる"))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                    }
                }
            }
            .frame(maxHeight: 130)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
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
                Image(systemName: "paperclip").vcFont(10, weight: .bold).foregroundStyle(.white.opacity(0.7))
                Text(tr("画像")).vcFont(11, weight: .semibold).foregroundStyle(.white.opacity(0.85))
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
            case nil: return (tr("読んでいます…"), "ellipsis", .white.opacity(0.6))
            case let .confirming(agent)?: return (tr("\(agent) へ送る確認待ち"), "hourglass", ChatPalette.orange)
            case .local?: return (tr("この Mac の中で処理"), "lock.fill", Color(red: 0.35, green: 0.85, blue: 0.6))
            case let .sent(agent)?: return (tr("\(agent) へ送信"), "arrow.up.forward.circle.fill", ChatPalette.orange)
            case .declined?: return (tr("送信しませんでした"), "xmark.circle.fill", .white.opacity(0.6))
            case let .notUsed(reason)?: return (reason, "exclamationmark.triangle.fill", .white.opacity(0.6))
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: symbol).vcFont(9, weight: .bold, maxScale: 1.15)
            Text(text).vcFont(10, weight: .semibold, maxScale: 1.15).lineLimit(1).lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

/// 会話に添えてある画像：サムネイルと、使えなくなるまでの時間。外のエージェントへは、**送るたびに確認する**ことを、断る。
private struct AttachmentBar: View {
    let image: AttachedImage
    /// 外のエージェントか（送る前に、確認する）。
    let external: Bool
    let retake: () -> Void
    let detach: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: image.thumbnail).resizable().aspectRatio(contentMode: .fill).frame(width: 64, height: 42).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("画像を、会話に添えています")).vcFont(12, weight: .semibold).foregroundStyle(.white.opacity(0.9))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(image.expiresAt.timeIntervalSince(context.date)))
                    let time = "\(left / 60):" + String(format: "%02d", left % 60)
                    Text(external ? tr("あと \(time) で、使えなくなります・送る前に、確認します") : tr("あと \(time) で、使えなくなります"))
                        .vcFont(11).foregroundStyle(external ? ChatPalette.orange : .white.opacity(0.5))
                }
            }
            Spacer(minLength: 8)
            PillButton(title: tr("撮り直す"), symbol: "camera.viewfinder", flashed: false, action: retake)
            PillButton(title: tr("外す"), symbol: "xmark", flashed: false, action: detach)
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
            Image(systemName: symbol).vcFont(9, weight: .bold, maxScale: 1.15)
            Text(text).vcFont(10, weight: .semibold, maxScale: 1.15).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// 読み上げ中の、波打つ棒。

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(ChatPalette.brand.opacity(0.22)).frame(width: 64, height: 64)
                Image(systemName: "waveform.and.mic").vcFont(26, weight: .semibold).foregroundStyle(ChatPalette.brand)
            }
            Text(tr("話しかけてみましょう")).vcFont(16, weight: .semibold).foregroundStyle(.white.opacity(0.9))
            Text(tr("会話のキーを押している間、話します。\n質問と答えが、ここに続いていきます。")).vcFont(12).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.5))
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
                    .vcFont(14, weight: .medium).foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5, topTrailingRadius: 18, style: .continuous).fill(ChatPalette.bubble))
                    .shadow(color: ChatPalette.blue.opacity(0.28), radius: 8, y: 3)
                Text(entry.asked, format: .dateTime.hour().minute()).vcFont(10).foregroundStyle(.white.opacity(0.32)).padding(.trailing, 4)
            }
        }
    }

    /// 答え：左の、アイコンつきのカード。
    private var assistantCard: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.10)).frame(width: 28, height: 28)
                Image(systemName: "sparkles").vcFont(12, weight: .semibold).foregroundStyle(ChatPalette.brand)
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 10) {
                switch entry.outcome {
                case .pending:
                    Pending(status: entry.status ?? tr("考えています…"))
                case .answered:
                    if let rendered = entry.rendered { RichText(attributed: rendered).frame(maxWidth: .infinity, alignment: .leading) }
                    if !entry.activities.isEmpty { activities.padding(.top, 4) }
                    ForEach(entry.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").vcFont(11).foregroundStyle(.white.opacity(0.45))
                    }
                    if let answer = entry.answer { actions(answer) }
                case let .stopped(reason):
                    OutcomeNote(symbol: "stop.circle.fill", title: tr("中断しました"), detail: tr("\(reason)。この質問は、会話の記録に入っていません（もう一度、聞いてください）"), color: .white.opacity(0.6))
                case let .failed(message):
                    OutcomeNote(symbol: "exclamationmark.triangle.fill", title: tr("答えを作れませんでした"), detail: message, color: ChatPalette.orange)
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
                Image(systemName: "bolt.fill").vcFont(9, weight: .bold)
                Text(tr("実行した操作")).vcFont(10, weight: .bold).kerning(0.5)
            }
            .foregroundStyle(ChatPalette.orange)
            ForEach(Array(entry.activities.enumerated()), id: \.offset) { _, activity in ActivityRow(activity: activity) }
        }
    }

    static func symbol(for kind: ChatActivity.Kind) -> String {  // `ActivityRow` も使う
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
            SmallAction(symbol: speakingThis ? "speaker.slash.fill" : "speaker.wave.2.fill", title: speakingThis ? tr("止める") : tr("読み上げ")) {
                if speakingThis { stopSpeaking() } else { speak(entry) }
            }
            SmallAction(symbol: "doc.on.doc", title: tr("コピー")) {
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
                Image(systemName: symbol).vcFont(10, weight: .semibold)
                Text(title).vcFont(11, weight: .medium)
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
            Text(status).vcFont(12.5, weight: .medium).foregroundStyle(ChatPalette.accent.opacity(0.9)).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// 整形した文章（`NSTextView`）：文字の選択・⌘C・日本語の組みは、標準のまま。幅に合わせて、高さを決める。
private struct RichText: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = DiagramTextView(frame: .zero)   // 図（Mermaid）は、クリックで拡大
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
        // 同じ幅・同じ文字は、測り直さない（レイアウトのたびに、文章全体を、新しく組み直していた。長い答え・表で、重い）
        // 図（Mermaid）は、文字が 1 つの印だけなので、画像の大きさも、鍵に入れる（別の図と、高さを取り違えない）
        var attachmentSizes = ""
        current.enumerateAttribute(.attachment, in: NSRange(location: 0, length: current.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { attachmentSizes += "|\(range.location):\(Int(attachment.bounds.width))x\(Int(attachment.bounds.height))" }
        }
        let height = TextHeightCache.height(width: width, text: current.string + attachmentSizes) {
            let storage = NSTextStorage(attributedString: current)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            return ceil(layout.usedRect(for: container).height)
        }
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

/// 実行した操作の 1 行。**結果（コマンドの出力・ファイルの差分）があれば、押して、開ける**（画面に出すだけ：記録には残さない）。
private struct ActivityRow: View {
    let activity: ChatActivity
    @StateObject private var flag = OpenFlag()   // SwiftUI の `@State` は、この環境では使えない（ChatWindow.swift の注記）
    private var open: Bool { flag.open }
    /// 長い操作（長いコマンド）：押すと、**全文**を見られる（確認のときは、見出しと抜粋だけを出したので、ここで、全文を確かめられる）。
    private var hasLongDetail: Bool { activity.detail.count > 100 }
    private var expandable: Bool { activity.output != nil || hasLongDetail }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: EntryView.symbol(for: activity.kind)).vcFont(10, weight: .semibold).foregroundStyle(ChatPalette.orange.opacity(0.9)).frame(width: 14)
                Text(activity.text).vcFont(11.5, design: .monospaced).foregroundStyle(.white.opacity(0.72)).lineLimit(2).textSelection(.enabled)
                if expandable {
                    Spacer(minLength: 4)
                    Text(activity.output?.isDiff == true ? tr("差分") : (activity.output != nil ? tr("出力") : tr("全文"))).vcFont(10, weight: .semibold).foregroundStyle(.white.opacity(0.5))
                    Image(systemName: open ? "chevron.down" : "chevron.right").vcFont(9, weight: .bold).foregroundStyle(.white.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if expandable { withAnimation(.easeOut(duration: 0.15)) { flag.open.toggle() } } }
            if open, hasLongDetail {
                ActivityOutput(output: ChatActivity.Output(text: activity.detail))   // 全文（上限は、`ChatActivity.Output` の、行数・文字数）
            }
            if open, let output = activity.output { ActivityOutput(output: output) }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.22)))
    }
}

private final class OpenFlag: ObservableObject { @Published var open = false }

/// 結果の本文（等幅。差分は、追加を緑・削除を赤・「…」を薄く）。長いときは、中でスクロール。
private struct ActivityOutput: View {
    let output: ChatActivity.Output

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(output.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line).vcFont(11, design: .monospaced).foregroundStyle(color(of: line)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(7)
        }
        .frame(maxHeight: 220)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.28)))
    }

    private func color(of line: String) -> Color {
        guard output.isDiff else { return .white.opacity(0.82) }
        if line.hasPrefix("---") || line.hasPrefix("…") { return .white.opacity(0.45) }   // ファイル名の見出し（「--- 名前」）は、削除の行（「-」）より先に見分ける
        if line.hasPrefix("+") { return Color(red: 0.55, green: 0.90, blue: 0.62) }
        if line.hasPrefix("-") { return Color(red: 1.0, green: 0.55, blue: 0.55) }
        return .white.opacity(0.78)
    }
}

