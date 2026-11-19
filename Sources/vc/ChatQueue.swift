import Foundation

/// 会話の「順番待ち」の 1 件：考えている間に、送られた質問（文字か、声）。
struct QueuedMessage: Identifiable, Equatable {
    enum Source: Equatable { case typed, voice }
    let id = UUID()
    let text: String
    let source: Source
    /// 「今すぐ送る」で、先頭へ出した：ほかの文字と、まとめない（その 1 件だけを送る）。
    var isolated = false
}

/// 会話の**順番待ち**（Zed・Codync と同じ考え方：考えている間に送った質問は、**キューに入り**、いまの返答が終わってから、処理する）。**画面・声なしで、テストできる**。
/// - 文字の質問が続いて待っていたら、**まとめて 1 回の質問**にする（空行でつなぐ。長い待ちが、何回も続かない）。声の質問は、1 件ずつ（声の流れの中で、確認の返事・読み上げを受ける）。
/// - 「今すぐ送る」は、その 1 件を先頭へ（ほかと、まとめない。残りは、そのまま待つ）。
struct ChatQueue: Equatable {
    private(set) var items: [QueuedMessage] = []

    /// 次に処理する分：どの件か（`ids`）・送る文・種類。
    struct Batch: Equatable {
        let ids: [UUID]
        let text: String
        let source: QueuedMessage.Source
    }

    var isEmpty: Bool { items.isEmpty }

    @discardableResult
    mutating func enqueue(_ text: String, source: QueuedMessage.Source) -> QueuedMessage {
        let item = QueuedMessage(text: text, source: source)
        items.append(item)
        return item
    }

    /// 1 件、取り下げる（なければ nil）。
    @discardableResult
    mutating func remove(_ id: UUID) -> QueuedMessage? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// 1 件を、先頭へ（「今すぐ送る」）。
    mutating func moveToFront(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.isolated = true
        items.insert(item, at: 0)
    }

    /// 先頭から、処理する分を取り出す。文字が続いていれば、まとめる。空なら nil。
    mutating func takeNext() -> Batch? {
        guard let first = items.first else { return nil }
        guard first.source == .typed, !first.isolated else {
            items.removeFirst()
            return Batch(ids: [first.id], text: first.text, source: first.source)
        }
        let run = items.prefix { $0.source == .typed && !$0.isolated }
        items.removeFirst(run.count)
        return Batch(ids: run.map(\.id), text: run.map(\.text).joined(separator: "\n\n"), source: .typed)
    }

    /// すべて取り出す（停止：待っていた分は、送らない）。
    mutating func removeAll() -> [QueuedMessage] {
        defer { items = [] }
        return items
    }
}
