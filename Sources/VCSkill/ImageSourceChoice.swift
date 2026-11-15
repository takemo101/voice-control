import Foundation
import VCDecision

/// **スクリーンショットも、コピーした画像も、ある**とき、依頼が、どちらの画像についてかの選び方（Tiny-Jev）。
/// 言葉の一致（「コピー」「クリップボード」）は、「さっきコピーした〜」は拾えても、「貼り付けようとしている画像」「ブラウザから持ってきたやつ」は拾えず、撮ったスクリーンショットを使ってしまった。
/// 決められない（どちらでもない・確信がない）ときは、従来の言葉の決め方に戻る（`ImageSource.resolve`）。
///
/// **測定（`vc eval-judge source`。docs/verification.md）**：`corpus/image-source.tsv`（24+6 文。言い方の選択に使った）：手がかりのある 23/24 を、正しく選び、取り違えは 0。`image-source-test.tsv`（見ずに作った 20 文）は、docs/verification.md。
public struct ImageSourceChoice: Sendable {
    /// 選ぶ確率の下限（測定で決める）。
    public static let threshold = 0.6
    private let scorer: OptionScorer
    public init(scorer: OptionScorer) { self.scorer = scorer }

    /// 順に：撮ったスクリーンショット・コピーした画像・決められない。
    /// 「どちらの画像についてか」と聞く形は、**コピーした画像ばかりを選んだ**（11/24 を取り違え）。**「画像は、どこから来たか」**と聞き、手がかり（コピー・貼り付け／画面・スクショ）を並べると、当たった。
    public func probabilities(request: String) throws -> [Double] {
        let p = try scorer.score(
            state: "発話: \(request)", question: "この依頼の画像は、どこから来たか",
            options: ["コピー・貼り付け・クリップボード・ブラウザやファイルから持ってきた画像", "画面・スクショ・撮った・いま見ているもの", "言葉からは分からない"])
        return [p[1], p[0], p[2]]
    }

    /// 選んだ取り先（確信がなければ nil）。
    public static func decide(_ p: [Double], threshold: Double = threshold) -> ImageSource? {
        guard p.count == 3, let best = p.indices.max(by: { p[$0] < p[$1] }), best < 2, p[best] >= threshold else { return nil }
        return best == 0 ? .screenshot : .clipboard
    }

    public func choose(request: String) -> ImageSource? {
        (try? probabilities(request: request)).flatMap { Self.decide($0) }   // 判定できなければ、決められない（言葉の決め方に戻る）
    }
}

/// `ImageSource.resolve` が使う、選び方。アプリ・コマンドが、Tiny-Jev を読んだとき、入れる（`CommandContext.tryLoadJev`）。入っていなければ、言葉で決める。
/// 同じ依頼の文は、続けて何度も聞かれる（パネルの画像・`vc see`・加工）ので、直前の 1 つを覚える。
public final class ImageSourceJudge: @unchecked Sendable {
    public static let shared = ImageSourceJudge()
    private let lock = NSLock()
    private var choice: ImageSourceChoice?
    private var last: (request: String, result: ImageSource?)?

    public func install(_ scorer: OptionScorer?) {
        lock.lock(); defer { lock.unlock() }
        choice = scorer.map { ImageSourceChoice(scorer: $0) }
        last = nil
    }

    public func pick(_ request: String) -> ImageSource? {
        lock.lock()
        let choice = choice
        if let last, last.request == request { lock.unlock(); return last.result }
        lock.unlock()
        guard let choice else { return nil }
        let result = choice.choose(request: request)
        lock.lock(); last = (request, result); lock.unlock()
        return result
    }
}
