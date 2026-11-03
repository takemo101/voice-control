import Foundation

/// 実行の経過を、画面の上の表示に出し続ける（中身を持ち、変えるたびに出し直す）。どのスレッドから更新してもよい。
/// `@unchecked Sendable` の理由：可変な状態（`content`）は、すべて `lock` で守る。
final class HUDSession: @unchecked Sendable {
    private var content: HUDContent
    private let lock = NSLock()
    private let present: @Sendable (HUDContent, TimeInterval?) -> Void

    /// `present`：出す先（既定は、画面の上の表示。テストで差し替える）。
    init(_ content: HUDContent, present: @escaping @Sendable (HUDContent, TimeInterval?) -> Void = { HUD.shared.show($0, hideAfter: $1) }) {
        self.content = content
        self.present = present
    }

    /// 中身を変えて、出し直す。`hideAfter` 秒後に消す。
    func update(hideAfter: TimeInterval? = nil, _ change: (inout HUDContent) -> Void = { _ in }) {
        lock.lock(); change(&content); let snapshot = content; lock.unlock()
        present(snapshot, hideAfter)
    }

    /// 返事の長さに合わせた、読む時間（4〜12 秒）。
    static func readingTime(for text: String) -> TimeInterval { min(12, max(4, 2.5 + Double(text.count) / 18)) }

    /// 出力の先頭の、空でない 1 行（長いときは切る）。
    static func firstLine(_ output: String) -> String? {
        guard let line = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }
}
