import AppKit
import SwiftUI
import VCCore

/// 止めたあとの後始末（自動の要約・Markdown の保存）の知らせ：作業中・保存した（見る）・失敗。
struct WrapUpBanner: View {
    let wrapUp: TranscriptSession.WrapUp
    let reveal: (URL) -> Void

    var body: some View {
        switch wrapUp {
        case .idle:
            EmptyView()
        case let .working(message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).vcFont(11, weight: .medium).foregroundStyle(.white.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 8).background(TranscriptPalette.teal.opacity(0.10))
        case let .saved(url):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.ok)
                Text(tr("会議の記録を保存しました：\(url.lastPathComponent)")).vcFont(11, weight: .medium).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(tr("Finder で見る")) { reveal(url) }.buttonStyle(.plain).vcFont(11, weight: .semibold).foregroundStyle(TranscriptPalette.teal)
            }
            .padding(.horizontal, 18).padding(.vertical, 8).background(Brand.ok.opacity(0.10))
        case let .failed(why):
            Label(why, systemImage: "exclamationmark.triangle.fill").vcFont(11).foregroundStyle(TranscriptPalette.orange).lineLimit(2)
                .padding(.horizontal, 18).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).background(TranscriptPalette.orange.opacity(0.10))
        }
    }
}

/// 面の切り替え（会話｜要約）。要約の面には、件数・作っている最中の印を出す。
struct TabBar: View {
    @ObservedObject var session: TranscriptSession
    @ObservedObject var panel: TranscriptPanelState

    private var working: Bool { if case .working = session.summaryState { return true } else { return false } }

    var body: some View {
        HStack(spacing: 6) {
            tab(.chat, title: tr("会話"), symbol: "text.bubble", badge: nil)
            tab(.summary, title: tr("要約"), symbol: "text.badge.star", badge: session.summaries.isEmpty ? nil : "\(session.summaries.count)")
            Spacer()
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
        .background(DragArea())
    }

    private func tab(_ tab: TranscriptPanelState.Tab, title: String, symbol: String, badge: String?) -> some View {
        let active = panel.tab == tab
        return Button { panel.tab = tab } label: {
            HStack(spacing: 6) {
                if tab == .summary && working { ProgressView().controlSize(.mini) } else { Image(systemName: symbol).vcFont(12, weight: .semibold) }
                Text(title).vcFont(13, weight: .semibold)
                if let badge { Text(badge).vcFont(10.5, weight: .bold).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(TranscriptPalette.teal.opacity(0.28))) }
            }
            .foregroundStyle(active ? .white : .white.opacity(0.55))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(active ? AnyShapeStyle(TranscriptPalette.teal.opacity(0.22)) : AnyShapeStyle(.white.opacity(0.0))))
            .overlay(Capsule().strokeBorder(active ? TranscriptPalette.teal.opacity(0.6) : .white.opacity(0.12), lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 要約の面：上に「要約を作る」（会議全体・テーマ・選んだ発話）・その下に、できた要約（新しい順の、大きなカード）。**言語モデルによる言い換え**であることを、明示する。
struct SummaryTab: View {
    @Environment(\.fontScale) private var scale
    @ObservedObject var session: TranscriptSession
    @ObservedObject var panel: TranscriptPanelState
    let actions: TranscriptPanelActions

    /// テーマの候補（押すだけで、そのテーマで要約する）。
    private static var topics: [String] { [tr("決まったこと"), tr("やること"), tr("質問・確認事項"), tr("数字・日程")] }

    private var busy: Bool { if case .working = session.summaryState { return true } else { return false } }
    private var hasText: Bool { !session.log.entries.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                creator
                status
                if session.summaries.isEmpty {
                    if !busy { EmptySummary(hasText: hasText) }
                } else {
                    ForEach(session.summaries.reversed()) { item in
                        SummaryItemView(item: item, copy: { actions.copyOne(item.text) }, remove: { session.removeSummary(id: item.id) })
                    }
                }
                Text(tr("要約は、言語モデルによる言い換えです。正確さは、会話の面の文字起こしで、確かめてください。")).vcFont(10.5).foregroundStyle(.white.opacity(0.35)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .scrollIndicators(.never)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    // MARK: 作る

    private var creator: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { if !busy && hasText { actions.summarize(.all, nil) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").vcFont(14, weight: .bold)
                    Text(tr("会議全体を要約")).vcFont(14, weight: .bold)
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Capsule().fill(TranscriptPalette.brand))
                .opacity(busy || !hasText ? 0.45 : 1)
            }
            .buttonStyle(.plain).disabled(busy || !hasText)

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("テーマ・コメントで絞って要約")).vcFont(12, weight: .semibold).foregroundStyle(.white.opacity(0.7))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Self.topics, id: \.self) { topic in
                        Button { run(topic) } label: {
                            Text(topic).vcFont(12, weight: .semibold).foregroundStyle(.white.opacity(0.9)).frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(Capsule().fill(.white.opacity(0.09))).overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.7))
                        }
                        .buttonStyle(.plain).disabled(busy || !hasText)
                    }
                }
                // テーマ・コメント：会話の入力欄と同じ作り（複数行：Return で要約・⇧Return で改行。1 行から、最大 6 行まで、高くなる）
                HStack(alignment: .bottom, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        if panel.focusText.isEmpty {
                            Text(tr("テーマやコメント（⇧Return で改行）")).vcFont(13).foregroundStyle(.white.opacity(0.42)).lineLimit(1).allowsHitTesting(false)
                        }
                        ComposerField(text: $panel.focusText, fontSize: 13 * scale, onSend: { run(panel.focusText) })
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(.white.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.7))
                    Button { run(panel.focusText) } label: {
                        Image(systemName: "arrow.up.circle.fill").vcFont(26).foregroundStyle(canRunFocus ? AnyShapeStyle(TranscriptPalette.brand) : AnyShapeStyle(Color.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain).disabled(!canRunFocus).accessibilityLabel(tr("要約"))
                }
            }

            Button { panel.tab = .chat; panel.selecting = true } label: {
                Label(tr("発話を選んで要約…"), systemImage: "checkmark.circle").vcFont(12, weight: .semibold).foregroundStyle(TranscriptPalette.teal)
            }
            .buttonStyle(.plain).disabled(busy || !hasText).opacity(busy || !hasText ? 0.4 : 1)
            .help(tr("会話の面で、吹き出しにチェックを付けて、その発話だけを要約します"))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.7))
    }

    private var canRunFocus: Bool { !busy && hasText && !panel.focusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func run(_ topic: String) {
        let text = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, hasText, !text.isEmpty else { return }
        actions.summarize(.focus(text), nil)
    }

    // MARK: 状態

    @ViewBuilder private var status: some View {
        switch session.summaryState {
        case .idle: EmptyView()
        case let .working(focus):
            StatusCard(symbol: nil, color: TranscriptPalette.teal, title: focus.map { tr("「\($0)」を要約しています…") } ?? tr("要約しています…"), detail: tr("長い会議は、分けて要約するので、時間がかかります。文字起こしは、続いています。"), dismiss: nil)
        case let .failed(why):
            StatusCard(symbol: "exclamationmark.triangle.fill", color: TranscriptPalette.orange, title: tr("要約できませんでした"), detail: why, dismiss: { session.dismissSummaryState() })
        case let .nothing(focus):
            StatusCard(symbol: "magnifyingglass", color: .white.opacity(0.6), title: focus.map { tr("「\($0)」に関する話は、見つかりませんでした") } ?? tr("該当する話は、見つかりませんでした"), detail: tr("別のテーマで、試してください。"), dismiss: { session.dismissSummaryState() })
        }
    }
}

/// 作っている最中・失敗・該当なしの知らせ。
private struct StatusCard: View {
    let symbol: String?
    let color: Color
    let title: String
    let detail: String
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let symbol { Image(systemName: symbol).foregroundStyle(color).padding(.top, 2) } else { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).vcFont(12.5, weight: .semibold).foregroundStyle(.white.opacity(0.9))
                Text(detail).vcFont(11).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark").vcFont(10, weight: .bold) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 0.7))
    }
}

/// まだ要約がないときの案内。
private struct EmptySummary: View {
    let hasText: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.star").vcFont(26, weight: .semibold).foregroundStyle(TranscriptPalette.brand)
            Text(hasText ? tr("まだ、要約がありません") : tr("話が出てから、要約できます")).vcFont(14, weight: .semibold).foregroundStyle(.white.opacity(0.85))
            Text(hasText ? tr("上のボタンで、会議全体や、テーマごとの要約を作れます。できた要約は、ここに並び、会議の Markdown にも入ります。") : tr("会議の文字起こしが、会話の面に出たら、ここから、要約を作れます。"))
                .vcFont(11.5).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 12)
    }
}

/// できた要約 1 つ（大きなカード）：見出し（会議全体・テーマ・選んだ発話）・時刻・コピー・消す・本文（選べる）。
private struct SummaryItemView: View {
    let item: MeetingSummary
    let copy: () -> Void
    let remove: () -> Void
    @StateObject private var hover = HoverState()

    private var title: String {
        switch item.scope {
        case .all: return tr("会議全体")
        case let .selected(count): return tr("選んだ \(count) 件")
        case let .focus(topic): return tr("テーマ：\(topic.split(whereSeparator: \.isNewline).first.map(String.init) ?? topic)")
        }
    }

    private var symbol: String {
        switch item.scope {
        case .all: return "text.alignleft"
        case .selected: return "checkmark.circle"
        case .focus: return "scope"
        }
    }

    /// 要約は Markdown（見出し・箇条書き・入れ子・太字・表など）：会話のウィンドウと同じ描画（`MarkdownRenderer`）で見せる。
    private var rendered: NSAttributedString { MarkdownRenderer.render(item.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol).vcFont(12, weight: .semibold).foregroundStyle(TranscriptPalette.teal).lineLimit(1)
                Text(item.date, format: .dateTime.hour().minute()).vcFont(10.5).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button(action: copy) { Label(tr("コピー"), systemImage: "doc.on.doc").vcFont(11, weight: .semibold) }.buttonStyle(.plain).help(tr("この要約をコピー"))
                Button(action: remove) { Image(systemName: "trash").vcFont(11) }.buttonStyle(.plain).help(tr("この要約を消す"))
            }
            .foregroundStyle(.white.opacity(0.6))
            RichText(attributed: rendered).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(hover.on ? 0.08 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(TranscriptPalette.teal.opacity(0.28), lineWidth: 0.7))
        .onHover { hover.on = $0 }
    }
}

/// 発話を選んでいる間の、下の行：選んだ件数・全部選ぶ・解除・やめる。
struct SelectionBar: View {
    @ObservedObject var session: TranscriptSession
    @ObservedObject var panel: TranscriptPanelState
    let actions: TranscriptPanelActions

    var body: some View {
        HStack(spacing: 10) {
            Text(tr("\(panel.selected.count) 件を選んでいます")).vcFont(12, weight: .semibold).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button(tr("全部")) { panel.selected = Set(session.log.entries.map(\.id)) }.buttonStyle(.plain).vcFont(12, weight: .semibold).foregroundStyle(TranscriptPalette.teal)
            Button(tr("解除")) { panel.selected = [] }.buttonStyle(.plain).vcFont(12, weight: .semibold).foregroundStyle(.white.opacity(0.6))
            PillButton(title: tr("要約"), symbol: "sparkles", flashed: false) {
                if !panel.selected.isEmpty { actions.summarize(.selected(count: panel.selected.count), panel.selected) }
            }
            PillButton(title: tr("やめる"), symbol: "xmark", flashed: false) { panel.stopSelecting() }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(DragArea())
    }
}
