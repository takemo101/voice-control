import AppKit
import SwiftUI
import VCCore

/// 相手の音声の文字起こしのパネル（SPEC F80）の状態：検索・開いている「元の文字」・スクロール・コピーの合図。画面の状態は、ここだけ（SwiftUI の `@State` は、この環境では使えない）。
@MainActor final class TranscriptPanelState: ObservableObject {
    @Published var query = ""
    /// 「元の文字」を開いている吹き出し。
    @Published var openOriginals: Set<UUID> = []
    @Published var awayFromBottom = false
    /// 押したあと、少しの間、チェックにする。
    @Published var copiedAll = false
    /// 開始・停止のショートカットの表示（なければ nil）。空の画面の案内に使う。
    @Published var keyHint: String?
    /// 取り込む音の名前（全体なら nil）。
    @Published var targetName: String?
}

private enum TranscriptPalette {
    static let teal = Color(red: 0.30, green: 0.85, blue: 0.80)
    static let blue = Color(red: 0.30, green: 0.62, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.25)
    static let purple = Color(red: 0.58, green: 0.40, blue: 0.96)
    /// 自分の吹き出し（会話のウィンドウの、自分の質問と、同じ色）。
    static var mine: LinearGradient { LinearGradient(colors: [blue.opacity(0.85), purple.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var brand: LinearGradient { LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static let bottomAnchor = "transcript-bottom"
}

/// 相手の音声を、**チャットの形**で見せる：左に、相手の吹き出し（続けて話した文は、まとめる）・間が空いたところに、時刻の区切り・いま聞こえている文は、点線の吹き出し。
/// 上の行に、状態（聞いています・止まっています）と、開始／停止。下に、探す欄。**文字起こし専用**：ここの文は、スキルを実行しない。
struct TranscriptPanelView: View {
    @ObservedObject var session: TranscriptSession
    @ObservedObject var panel: TranscriptPanelState
    let toggle: () -> Void
    let copyMarkdown: () -> Void
    let copyText: () -> Void
    let copyOne: (String) -> Void
    let clear: () -> Void
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) {
            header
            Rule()
            if let notice = session.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").vcFont(11).foregroundStyle(TranscriptPalette.orange).lineLimit(2)
                    .padding(.horizontal, 18).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).background(TranscriptPalette.orange.opacity(0.10))
            }
            conversation
            if !session.log.entries.isEmpty {
                Rule()
                searchBar
            }
        }
        .glassEffect(.regular.tint(DocumentPalette.accent.opacity(0.06)), in: shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.05), TranscriptPalette.teal.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .clipShape(shape)
    }

    // MARK: ヘッダー

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(TranscriptPalette.brand).frame(width: 34, height: 34)
                Image(systemName: "captions.bubble.fill").vcFont(14, weight: .semibold).foregroundStyle(.white)
            }
            .shadow(color: TranscriptPalette.teal.opacity(0.4), radius: 8, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("音声入力（会議）")).vcFont(16, weight: .semibold).foregroundStyle(.white)
                HStack(spacing: 8) {
                    StatusDot(state: session.state)
                    if session.micState != .idle { MicStatus(state: session.micState) }
                    if let target = panel.targetName { Pill(text: target, symbol: "app.badge") }
                    if !session.log.entries.isEmpty { Pill(text: tr("\(session.log.entries.count) 件"), symbol: "text.bubble") }
                }
            }
            Spacer(minLength: 8)
            PillButton(title: session.isActive ? tr("停止") : tr("開始"), symbol: session.isActive ? "stop.fill" : "record.circle", flashed: false, action: toggle)
            moreMenu
            HeaderIconButton(symbol: "xmark", help: tr("閉じる（Esc）"), cancel: true, action: close)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(DragArea())
    }

    private var moreMenu: some View {
        Menu {
            Button(action: copyMarkdown) { Label(tr("Markdown をコピー"), systemImage: "doc.on.doc") }.disabled(session.log.entries.isEmpty)
            Button(action: copyText) { Label(tr("テキストをコピー"), systemImage: "text.alignleft") }.disabled(session.log.entries.isEmpty)
            Divider()
            Button(role: .destructive, action: clear) { Label(tr("画面の記録を消す（履歴は、残ります）"), systemImage: "trash") }.disabled(session.log.entries.isEmpty)
        } label: {
            HeaderCircle(symbol: "ellipsis", flashed: panel.copiedAll)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(tr("コピー・画面の記録を消す"))
        .accessibilityLabel(tr("そのほかの操作"))
    }

    // MARK: 吹き出し

    private var conversation: some View {
        let rows = session.log.rows(matching: panel.query)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if session.log.entries.isEmpty && session.log.tentative.isEmpty {
                        EmptyPanel(state: session.state, keyHint: panel.keyHint).frame(maxWidth: .infinity).padding(.top, 70)
                    } else if rows.isEmpty {
                        Text(tr("見つかりません")).vcFont(12).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case let .separator(date): TimeSeparator(date: date).padding(.vertical, 8)
                        case let .message(entry, startsGroup):
                            Bubble(entry: entry, startsGroup: startsGroup, panel: panel, copy: { copyOne(entry.text) })
                                .padding(.top, startsGroup ? 8 : 0)
                        }
                    }
                    if panel.query.isEmpty { liveBubble }
                    Color.clear.frame(height: 1).id(TranscriptPalette.bottomAnchor)
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                ChatScroll.isAwayFromBottom(contentHeight: geometry.contentSize.height, visibleMaxY: geometry.visibleRect.maxY)
            } action: { _, away in
                if panel.awayFromBottom != away { panel.awayFromBottom = away }
            }
            .overlay(alignment: .bottom) {
                if panel.awayFromBottom {
                    JumpToLatestButton { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(TranscriptPalette.bottomAnchor, anchor: .bottom) } }
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: panel.awayFromBottom)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            // 新しい文が来たら、下へ（読み返している間は、動かさない：「最新へ」で戻る）
            .onChange(of: session.log.entries.count) { follow(proxy) }
            .onChange(of: session.log.tentative) { follow(proxy) }   // 話し手ごとの確定前の文字
            .onAppear { proxy.scrollTo(TranscriptPalette.bottomAnchor, anchor: .bottom) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard !panel.awayFromBottom, panel.query.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(TranscriptPalette.bottomAnchor, anchor: .bottom) }
    }

    /// いま聞こえている文（確定前）：点線の吹き出し（相手は左・自分は右）。何も聞こえていない間は、「聞いています」の表示。
    @ViewBuilder private var liveBubble: some View {
        ForEach([HistoryEntry.Source.others, .me], id: \.self) { speaker in
            if let text = session.log.tentative[speaker] { LiveBubble(speaker: speaker, text: text).padding(.top, 8) }
        }
        if session.log.tentative.isEmpty, session.state == .running, !session.log.entries.isEmpty {   // 文がまだないときは、空の画面の案内が、その役目をする
            HStack(spacing: 8) {
                Image(systemName: "waveform").vcFont(12, weight: .semibold).foregroundStyle(TranscriptPalette.teal).symbolEffect(.variableColor.iterative.reversing)
                Text(tr("聞いています…")).vcFont(11, weight: .medium).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.leading, 36).padding(.top, 10)
        }
    }

    // MARK: 探す

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
            TextField(tr("探す"), text: $panel.query).textFieldStyle(.plain).vcFont(13).foregroundStyle(.white)
            if !panel.query.isEmpty {
                Button { panel.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.45)) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(DragArea())
    }
}

// MARK: 部品

/// 状態の点と文字：聞いています（緑・脈打つ）・始めています・止まっています・始められません（理由）。
private struct StatusDot: View {
    let state: TranscriptSession.State

    var body: some View {
        switch state {
        case .running:
            HStack(spacing: 5) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Brand.ok).symbolEffect(.pulse)
                Text(tr("聞いています")).vcFont(11, weight: .medium, maxScale: 1.15).foregroundStyle(.white.opacity(0.7))
            }
        case .starting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(tr("始めています…")).vcFont(11, weight: .medium, maxScale: 1.15).foregroundStyle(.white.opacity(0.7))
            }
        case .idle:
            HStack(spacing: 5) {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.white.opacity(0.3))
                Text(tr("止まっています")).vcFont(11, weight: .medium, maxScale: 1.15).foregroundStyle(.white.opacity(0.5))
            }
        case let .failed(why):
            Label(why, systemImage: "exclamationmark.triangle.fill").vcFont(11, weight: .medium, maxScale: 1.15).foregroundStyle(TranscriptPalette.orange).lineLimit(2)
        }
    }
}

private struct Pill: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol).vcFont(10.5, weight: .medium, maxScale: 1.15).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(.white.opacity(0.09)))
    }
}

/// 時刻の区切り（前の文から、間が空いたところ）。
private struct TimeSeparator: View {
    let date: Date
    var body: some View {
        HStack(spacing: 10) {
            line
            Text(date, format: .dateTime.hour().minute()).vcFont(10.5, weight: .semibold).foregroundStyle(.white.opacity(0.4))
            line
        }
    }
    private var line: some View { Rectangle().fill(.white.opacity(0.10)).frame(height: 0.7) }
}

/// 相手のアイコン（続けて話した文では、場所だけ空ける）。
private struct Avatar: View {
    let visible: Bool
    var speaker: HistoryEntry.Source = .others
    var body: some View {
        ZStack {
            if visible {
                Circle().fill(.white.opacity(0.10))
                if speaker == .others {
                    Image(systemName: "person.wave.2.fill").vcFont(11, weight: .semibold).foregroundStyle(TranscriptPalette.brand)
                } else {
                    Image(systemName: "mic.fill").vcFont(11, weight: .semibold).foregroundStyle(TranscriptPalette.mine)
                }
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// 確定した 1 文の吹き出し。相手は左（薄い面）・自分は右（会話のウィンドウの、自分の質問と同じ色）。整理したときは、「整理済み」を出し、押すと、元の文字が開く。触れると、コピーのボタン。
private struct Bubble: View {
    let entry: TranscriptLog.Entry
    let startsGroup: Bool
    @ObservedObject var panel: TranscriptPanelState
    let copy: () -> Void
    @StateObject private var hover = HoverState()

    private var mine: Bool { entry.speaker == .me }

    private var shape: UnevenRoundedRectangle {
        // 話の先頭の吹き出しは、アイコン側の角を、小さく（しっぽ）
        UnevenRoundedRectangle(topLeadingRadius: !mine && startsGroup ? 5 : 18, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: mine && startsGroup ? 5 : 18, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 40) } else { Avatar(visible: startsGroup, speaker: entry.speaker) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if startsGroup {
                    HStack(spacing: 6) {
                        Text(TranscriptLog.name(entry.speaker)).vcFont(11, weight: .semibold).foregroundStyle(.white.opacity(0.6))
                        Text(entry.date, format: .dateTime.hour().minute().second()).vcFont(10).foregroundStyle(.white.opacity(0.32))
                    }
                }
                HStack(alignment: .center, spacing: 6) {
                    if mine { copyButton }
                    Text(entry.text)
                        .vcFont(14, weight: .medium).foregroundStyle(.white.opacity(0.95))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(mine ? AnyShapeStyle(TranscriptPalette.mine) : AnyShapeStyle(.white.opacity(0.08)), in: shape)
                        .overlay(shape.strokeBorder(.white.opacity(mine ? 0.0 : 0.10), lineWidth: 0.7))
                    if !mine { copyButton }
                }
                if let raw = entry.raw {
                    let open = panel.openOriginals.contains(entry.id)
                    Button { if open { panel.openOriginals.remove(entry.id) } else { panel.openOriginals.insert(entry.id) } } label: {
                        Label(open ? tr("元の文字を閉じる") : tr("整理済み（元の文字を見る）"), systemImage: open ? "chevron.up" : "sparkles")
                            .vcFont(10.5, weight: .medium).foregroundStyle(TranscriptPalette.teal.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    if open {
                        Text(raw).vcFont(12).foregroundStyle(.white.opacity(0.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3])))
                    }
                }
            }
            if mine { Avatar(visible: startsGroup, speaker: entry.speaker) } else { Spacer(minLength: 40) }
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }

    private var copyButton: some View {
        Button(action: copy) { Image(systemName: "doc.on.doc").vcFont(11) }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).help(tr("この文をコピー"))
            .opacity(hover.on ? 1 : 0)
    }
}

/// いま聞こえている文（確定前）の、点線の吹き出し。
private struct LiveBubble: View {
    let speaker: HistoryEntry.Source
    let text: String

    var body: some View {
        let mine = speaker == .me
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 40) } else { Avatar(visible: true, speaker: speaker) }
            HStack(alignment: .bottom, spacing: 6) {
                Text(text).vcFont(14, weight: .medium).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "ellipsis").vcFont(12, weight: .bold).foregroundStyle((mine ? TranscriptPalette.blue : TranscriptPalette.teal).opacity(0.8)).symbolEffect(.variableColor.iterative)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder((mine ? TranscriptPalette.blue : TranscriptPalette.teal).opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3])))
            if mine { Avatar(visible: true, speaker: speaker) } else { Spacer(minLength: 40) }
        }
    }
}

/// 自分のマイクの状態（設定 `transcribeMic` がオンのとき）。
private struct MicStatus: View {
    let state: TranscriptSession.State

    var body: some View {
        switch state {
        case .running: Pill(text: tr("自分：聞いています"), symbol: "mic.fill")
        case .starting: Pill(text: tr("自分：始めています…"), symbol: "mic")
        case let .failed(why): Label(tr("自分：\(why)"), systemImage: "mic.slash.fill").vcFont(10.5, weight: .medium, maxScale: 1.15).foregroundStyle(TranscriptPalette.orange).lineLimit(2)
        case .idle: EmptyView()
        }
    }
}

/// まだ文がないときの案内：止まっているときは、始め方（キー）。動いているときは、「音が出るのを待っています」。
private struct EmptyPanel: View {
    let state: TranscriptSession.State
    let keyHint: String?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(TranscriptPalette.brand.opacity(0.22)).frame(width: 64, height: 64)
                Image(systemName: state == .running ? "waveform" : "captions.bubble").vcFont(26, weight: .semibold).foregroundStyle(TranscriptPalette.brand)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: state == .running)
            }
            Text(state == .running ? tr("音が出るのを、待っています") : tr("会議の音を、文字にします")).vcFont(16, weight: .semibold).foregroundStyle(.white.opacity(0.9))
            if state == .running {
                Text(tr("会議や動画の音が出ると、ここに、チャットのように並びます。")).vcFont(12).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.5))
            } else {
                VStack(spacing: 8) {
                    Text(tr("Mac から出ている音（会議・動画など）が、ここに、チャットのように並びます。")).vcFont(12).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.5))
                    if let keyHint {
                        Label(tr("\(keyHint) で、開始・停止"), systemImage: "keyboard").vcFont(11, weight: .semibold).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(.white.opacity(0.10)))
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }
}
