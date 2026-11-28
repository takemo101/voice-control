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

/// 要約のカード（会議の上）：「会議全体を要約」・「テーマで要約」・（発話を選んでいるとき）「選んだ発話を要約」。できた要約は、下に並ぶ（コピー・消す）。**言語モデルによる言い換え**であることを、明示する。
struct SummaryCard: View {
    @ObservedObject var session: TranscriptSession
    @ObservedObject var panel: TranscriptPanelState
    let actions: TranscriptPanelActions

    private var busy: Bool { if case .working = session.summaryState { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.star").vcFont(13, weight: .semibold).foregroundStyle(TranscriptPalette.teal)
                Text(tr("要約")).vcFont(13, weight: .semibold).foregroundStyle(.white)
                Text(tr("言語モデルによる言い換えです")).vcFont(10.5).foregroundStyle(.white.opacity(0.4))
                if !panel.summaryOpen && !session.summaries.isEmpty { Text(tr("\(session.summaries.count) 件")).vcFont(10.5, weight: .semibold).foregroundStyle(TranscriptPalette.teal) }
                Spacer()
                Image(systemName: panel.summaryOpen ? "chevron.up" : "chevron.down").vcFont(11, weight: .bold).foregroundStyle(.white.opacity(0.5))
            }
            .contentShape(Rectangle())
            .onTapGesture { panel.summaryOpen.toggle() }
            .help(panel.summaryOpen ? tr("要約を閉じる") : tr("要約を開く"))
            if panel.summaryOpen { controls }
            status
            if panel.summaryOpen && !session.summaries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.summaries) { item in SummaryItemView(item: item, copy: { actions.copyOne(item.text) }, remove: { session.removeSummary(id: item.id) }) }
                    }
                }
                .frame(maxHeight: 190).scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.white.opacity(0.04))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PillButton(title: tr("会議全体を要約"), symbol: "text.alignleft", flashed: false) { if !busy { actions.summarize(.all, nil) } }
                if panel.selecting && !panel.selected.isEmpty {
                    PillButton(title: tr("選んだ \(panel.selected.count) 件を要約"), symbol: "checkmark.circle", flashed: false) {
                        if !busy { actions.summarize(.selected(count: panel.selected.count), panel.selected) }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(.white.opacity(0.45))
                TextField(tr("テーマだけ要約（例：予算の話）"), text: $panel.focusText).textFieldStyle(.plain).vcFont(13).foregroundStyle(.white)
                    .onSubmit { runFocus() }
                PillButton(title: tr("要約"), symbol: "sparkles", flashed: false) { runFocus() }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.07)))
            if !panel.selecting {
                Text(tr("「…」> 発話を選んで、要約…：吹き出しを選んで、その発話だけ要約できます。")).vcFont(10.5).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func runFocus() {
        let topic = panel.focusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !topic.isEmpty else { return }
        actions.summarize(.focus(topic), nil)
    }

    @ViewBuilder private var status: some View {
        switch session.summaryState {
        case .idle: EmptyView()
        case let .working(focus):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(focus.map { tr("「\($0)」を要約しています…") } ?? tr("要約しています…")).vcFont(11, weight: .medium).foregroundStyle(.white.opacity(0.75))
            }
        case let .failed(why):
            HStack(alignment: .top, spacing: 8) {
                Label(why, systemImage: "exclamationmark.triangle.fill").vcFont(11).foregroundStyle(TranscriptPalette.orange).lineLimit(3)
                Spacer()
                Button { session.dismissSummaryState() } label: { Image(systemName: "xmark").vcFont(10, weight: .bold) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            }
        case let .nothing(focus):
            HStack(alignment: .top, spacing: 8) {
                Label(focus.map { tr("「\($0)」に関する話は、見つかりませんでした") } ?? tr("該当する話は、見つかりませんでした"), systemImage: "magnifyingglass").vcFont(11).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button { session.dismissSummaryState() } label: { Image(systemName: "xmark").vcFont(10, weight: .bold) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// できた要約 1 つ：見出し（会議全体・テーマ・選んだ発話）・本文（選べる）・コピー・消す。
private struct SummaryItemView: View {
    let item: MeetingSummary
    let copy: () -> Void
    let remove: () -> Void

    private var title: String {
        switch item.scope {
        case .all: return tr("会議全体")
        case let .selected(count): return tr("選んだ \(count) 件")
        case let .focus(topic): return tr("テーマ：\(topic)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).vcFont(11, weight: .semibold).foregroundStyle(TranscriptPalette.teal).lineLimit(1)
                Text(item.date, format: .dateTime.hour().minute()).vcFont(10).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button(action: copy) { Image(systemName: "doc.on.doc").vcFont(11) }.buttonStyle(.plain).help(tr("この要約をコピー"))
                Button(action: remove) { Image(systemName: "trash").vcFont(11) }.buttonStyle(.plain).help(tr("この要約を消す"))
            }
            .foregroundStyle(.white.opacity(0.55))
            Text(item.text).vcFont(13).foregroundStyle(.white.opacity(0.92)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TranscriptPalette.teal.opacity(0.25), lineWidth: 0.7))
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
