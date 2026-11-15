import AppKit
import Foundation
import VCSkill

/// 質問に付いた画像（サムネイルと、どう扱われたか）。
struct EntryImage {
    let thumbnail: NSImage
    /// 答えが出たあとに決まる（それまでは、nil：「読んでいます」）。
    var route: ChatMode.ImageRoute?
}

/// 会話の 1 往復（質問と、答え。答えが来るまでは、`status`）。
struct ChatEntry: Identifiable {
    /// この往復が、どうなったか。**中断・失敗した質問も、ウィンドウに残す**（黙って消えると、操作を取り違えたのかと不安になる）。会話の記録には、入らない（表示だけ）。
    enum Outcome: Equatable {
        case pending
        case answered
        /// 答えを待っている間に、中断・取りやめた（理由）。
        case stopped(String)
        /// 答えを作れなかった（理由）。
        case failed(String)
    }

    let id = UUID()
    var question: String
    let asked = Date()
    var outcome = Outcome.pending
    var status: String? = "考えています…"
    var answer: String?
    var activities: [ChatActivity] = []
    var notes: [String] = []
    /// この質問に付けた、画像。
    var image: EntryImage?
    /// 答えを整形した結果（描き直しのたびに、作り直さない）。
    var rendered: NSAttributedString?
    /// 文字で送った質問を、取りやめる手続き（声の質問は、声の流れが取りやめる：nil）。新しい質問が来たとき、前の質問を止めるのに使う。
    var cancel: (() -> Void)?

    var isPending: Bool { outcome == .pending }
}

/// 会話の表示の記録（ウィンドウの中身）の、状態の移り変わり。**画面なしで、テストできる**。往復は、`id` で指す（中断した質問の後始末が、新しい質問を巻き込まないように）。
extension Array where Element == ChatEntry {
    var hasPending: Bool { contains { $0.isPending } }

    /// 新しい質問を足す。まだ待っている前の質問は、**中断した**扱いにする（新しい質問を、優先した）。
    mutating func begin(_ entry: ChatEntry) {
        for index in indices where self[index].isPending {
            self[index].cancel?()   // 文字で送った質問は、処理も止める（止めた質問を、会話の記録に入れない）
            stopEntry(at: index, reason: "新しい質問を優先しました")
        }
        append(entry)
    }

    /// 待っている往復だけ、変える（もう決まった往復は、変えない：遅れて届いた知らせで、上書きしない）。
    mutating func updatePending(_ id: UUID, _ change: (inout ChatEntry) -> Void) {
        guard let index = firstIndex(where: { $0.id == id }), self[index].isPending else { return }
        change(&self[index])
    }

    mutating func setStatus(_ id: UUID, _ text: String) { updatePending(id) { $0.status = text } }

    /// 画像の扱いが決まった（確認待ち・送った・断った・この Mac の中で処理した）。答えを待たずに、出す。
    mutating func setRoute(_ id: UUID, _ route: ChatMode.ImageRoute) { updatePending(id) { $0.image?.route = route } }

    /// 質問に使う画像が分かった（まだ付いていないときだけ）。
    mutating func attach(_ id: UUID, image: EntryImage) { updatePending(id) { if $0.image == nil { $0.image = image } } }

    /// 答えが来た。`startedNew`：しばらく話さなかったので、前の会話は、終わった（この往復だけを残す）。
    mutating func finish(_ id: UUID, answer: String, rendered: NSAttributedString?, activities: [ChatActivity], notes: [String], route: ChatMode.ImageRoute?, startedNew: Bool) {
        updatePending(id) {
            $0.outcome = .answered; $0.status = nil
            $0.answer = answer; $0.rendered = rendered
            $0.activities = activities; $0.notes = notes
            $0.image?.route = route
        }
        if startedNew, let kept = first(where: { $0.id == id }) { self = [kept] }
    }

    /// 中断・取りやめた（理由つきで、残す）。
    mutating func stop(_ id: UUID, reason: String) {
        if let index = firstIndex(where: { $0.id == id }), self[index].isPending { stopEntry(at: index, reason: reason) }
    }

    /// 答えを作れなかった（理由つきで、残す）。
    mutating func fail(_ id: UUID, message: String) {
        updatePending(id) {
            $0.outcome = .failed(message); $0.status = nil
            if let route = $0.image?.route { $0.image?.route = route } else { $0.image?.route = .notUsed("答えが出ませんでした") }
        }
    }

    private mutating func stopEntry(at index: Int, reason: String) {
        self[index].outcome = .stopped(reason)
        self[index].status = nil
    }
}
