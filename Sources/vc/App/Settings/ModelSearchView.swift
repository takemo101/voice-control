import SwiftUI
import VCSkill

/// 検索の状態（ポップオーバーの開閉・入力・強調している行）。SwiftUI の `@State` は、この環境では使えないので、参照型。
@MainActor final class ModelSearchState: ObservableObject {
    @Published var isOpen = false
    @Published var query = ""
    /// 強調している行（Return で選ぶ）。`""` は、「エージェントの設定」の行。
    @Published var highlighted: String?
}

/// 検索つきの、モデルの一覧（ポップオーバーの中身）：
/// - 開くと、**すぐ入力できる**（入力欄に、カーソルがある）。**↑↓** で行を動かし、**Return** で決める、**Esc** で閉じる。マウスを載せた行も、強調する。
/// - あいまい検索（`FuzzyMatch`）：合った文字を、色で強調する。語がないときは、提供元・モデルごとに、**見出しで分ける**（`ModelListLogic`）。
/// - いまの選択（✓）・エージェントの既定（「既定」の札）・件数・キーの案内。合うものがないときは、案内と「検索を消す」。
struct ModelSearchList: View {
    @ObservedObject var search: ModelSearchState
    let state: SettingsModel.ModelListState?
    let chosen: String
    let agentName: String
    let select: (String?) -> Void
    let reload: () -> Void
    @FocusState private var focused: Bool

    private static let accent = Color(red: 0.20, green: 0.52, blue: 0.95)
    private static let defaultRow = ""

    var body: some View {
        let listing: ACPModelListing? = { if case let .loaded(value) = state { return value }; return nil }()
        let all = (listing?.choices ?? []).map { ModelListLogic.Item(id: $0.id, name: $0.name, detail: $0.detail) }
        let matches = FuzzyMatch.filter(all, query: search.query) { "\($0.id) \($0.name)" }
        let sections = ModelListLogic.sections(matches, query: search.query)
        let navigable = (search.query.isEmpty ? [Self.defaultRow] : []) + matches.map(\.id)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                searchField(navigable: navigable, proxy: proxy)
                Divider()
                content(listing: listing, sections: sections, matchCount: matches.count)
                Divider()
                footer(total: all.count, shown: matches.count)
            }
            .onChange(of: search.query) { search.highlighted = search.query.isEmpty ? (chosen.isEmpty ? Self.defaultRow : chosen) : matches.first?.id }
            .onChange(of: listing?.choices.count) { if search.highlighted == nil { search.highlighted = chosen.isEmpty ? Self.defaultRow : chosen } }
        }
        .frame(width: 380)
        .onAppear {
            focused = true
            search.highlighted = chosen.isEmpty ? Self.defaultRow : chosen
        }
    }

    // MARK: 入力欄

    private func searchField(navigable: [String], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("モデルを探す（例：son 5・haiku・gpt high）", text: $search.query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    guard let id = search.highlighted ?? navigable.first, navigable.contains(id) else { return }
                    select(id.isEmpty ? nil : id)
                }
                .onKeyPress(.downArrow) { move(1, navigable, proxy); return .handled }
                .onKeyPress(.upArrow) { move(-1, navigable, proxy); return .handled }
            if !search.query.isEmpty {
                Button { search.query = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("検索を消す")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func move(_ delta: Int, _ navigable: [String], _ proxy: ScrollViewProxy) {
        guard let next = ModelListLogic.moved(from: search.highlighted, by: delta, in: navigable) else { return }
        search.highlighted = next
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(next, anchor: .center) }
    }

    // MARK: 本文

    @ViewBuilder
    private func content(listing: ACPModelListing?, sections: [ModelListLogic.Section], matchCount: Int) -> some View {
        switch state {
        case .none, .loading:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("\(agentName) に、選べるモデルを聞いています…").font(.system(size: 12)).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, minHeight: 120)
        case let .failed(why):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange)
                Text("一覧を取れませんでした").font(.system(size: 13, weight: .semibold))
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("もう一度") { reload() }.controlSize(.small)
            }
            .padding(18).frame(maxWidth: .infinity)
        case .loaded:
            if matchCount == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("「\(search.query)」に合うモデルは、ありません").font(.system(size: 12.5, weight: .medium))
                    Text("短い語・一部の文字で、探してみてください（順に含まれていれば合います）").font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("検索を消す") { search.query = ""; focused = true }.controlSize(.small)
                }
                .padding(20).frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if search.query.isEmpty {
                            row(id: Self.defaultRow, title: "エージェントの設定（既定）", subtitle: listing?.current.map { "いまの設定：\($0)" }, badge: nil)
                        }
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            if let title = section.title {
                                Section {
                                    ForEach(section.items) { item in row(id: item.id, title: item.name, subtitle: item.id == item.name ? item.detail : item.id, badge: item.id == listing?.current ? "既定" : nil, detail: item.detail) }
                                } header: { header(title, count: section.items.count) }
                            } else {
                                ForEach(section.items) { item in row(id: item.id, title: item.name, subtitle: item.id == item.name ? item.detail : item.id, badge: item.id == listing?.current ? "既定" : nil, detail: item.detail) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
        .background(.regularMaterial)
    }

    private func row(id: String, title: String, subtitle: String?, badge: String?, detail: String? = nil) -> some View {
        let isHighlighted = search.highlighted == id
        let isChosen = chosen == id
        return Button { select(id.isEmpty ? nil : id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Self.accent).opacity(isChosen ? 1 : 0).frame(width: 12)
                VStack(alignment: .leading, spacing: 1.5) {
                    highlighted(title, base: .system(size: 12.5, weight: .medium), color: .primary)
                    if let subtitle, !subtitle.isEmpty {
                        highlighted(subtitle, base: .system(size: 10.5, design: id == title || subtitle.hasPrefix("いまの設定") ? .default : .monospaced), color: .secondary)
                    }
                }
                Spacer(minLength: 6)
                if let badge { Text(badge).font(.system(size: 9.5, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.secondary.opacity(0.18))).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHighlighted ? Self.accent.opacity(0.14) : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(id)
        .onHover { inside in if inside { search.highlighted = id } }
    }

    /// 合った文字を、色と太さで強調する。
    private func highlighted(_ text: String, base: Font, color: Color) -> Text {
        let marks = search.query.isEmpty ? [] : FuzzyMatch.highlight(search.query, in: text)
        guard !marks.isEmpty else { return Text(text).font(base).foregroundColor(color) }
        var out = AttributedString()
        for (index, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            piece.font = marks.contains(index) ? base.bold() : base
            piece.foregroundColor = marks.contains(index) ? Self.accent : color
            out.append(piece)
        }
        return Text(out)
    }

    // MARK: 下

    private func footer(total: Int, shown: Int) -> some View {
        HStack(spacing: 10) {
            Text(search.query.isEmpty ? "\(total) 件" : "\(shown) 件／全 \(total) 件").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            keyHint("↑↓", "移動"); keyHint("⏎", "決定"); keyHint("esc", "閉じる")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 9.5, weight: .semibold, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.secondary.opacity(0.16)))
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
