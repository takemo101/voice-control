import Foundation
import VCDecision

/// 会話で、**撮ったスクリーンショット**（ショートカットで撮ったもの）を、この質問に使うかの判定。
/// 言葉の一致（「画面」「画像」）では、「これ」「ここ」を見落とし、「スクショの撮り方は？」で、誤って反応するので、**Tiny-Jev が、2 つの言い方から選ぶ**。
/// 「画面を撮る」で添えた画像は、判定しない（使う）。判定が外れたときの被害：使うべきときに使わない → 「画面を撮る」で添えれば、必ず使う。使わないときに使う → Apple のモデルは、画像を読む時間がかかり、その会話では Web の道具を使わない。外のエージェントへは、毎回確認する。
///
/// **測定（`vc eval-image`。docs/verification.md）**：言い方 9 通りを、自作の 46 文（`corpus/chat-image.tsv`）で比べて、いまの言い方としきい値を選んだ（**この 46 文は、調整にも使った**）。
/// そのあと、**見ずに作った別の 30 文**（`corpus/chat-image-holdout.tsv`）で測った：画像について 13/14 を使い、画像なしの 11/16 を使わなかった。
/// 前提（「いま、スクリーンショットを撮った」）を、状態に入れる言い方だけが、「これ」「ここ」を拾えた。前提のない言い方は、画像についての質問の半分以上を取りこぼした。
public struct ChatImageUse: Sendable {
    /// 画像を使う確率の下限。確率が、1 に近いところに集まる言い方なので、高い（上の測定で決めた）。
    public static let threshold = 0.985
    private let scorer: OptionScorer
    public init(scorer: OptionScorer) { self.scorer = scorer }

    /// 画像を使う側の確率。**直前のやり取りは、渡さない**：渡しても、測定の結果は変わらず（2 つのコーパスとも同じ）、画像についての会話のあとで話題を変えた質問（「明日の天気は？」）を、画像についてと誤った（0.96 → 0.995）。
    /// Apple のモデルは、画像を、1 度だけ文字にして会話に入れる（`attached`）ので、続きの質問は、画像の内容を、会話の記録から読める。
    public func probability(request: String) throws -> Double {
        let state = "利用者は、いま、画面のスクリーンショットを撮った。\n発話: \(request)"
        let p = try scorer.score(
            state: state, question: "この発話の対象は、どちらか",
            options: ["一般的な知識・相談（画面に何が写っていても、関係ない）", "画面に写っているもの（「これ」「ここ」「このエラー」を含む）"])
        return p[1]
    }
}

extension ChatAttachments {
    /// 会話で、画像を、どう使うか（**添えるかどうかは、コードが決める**。言語モデルは、パスを渡せない）。
    public enum ImagePlan: Equatable, Sendable {
        /// 「画面を撮る」で添えた画像：判定しない。
        case attached
        /// 「コピーした画像」と言った：コピーした画像（クリップボード）。
        case clipboard
        /// 撮ったスクリーンショット：この質問に使う（Tiny-Jev の判定）。
        case screenshot
        /// 撮ったスクリーンショットがあるが、この質問には使わない（判定した確率）。
        case skippedScreenshot(Double)
        /// 判定できない（Tiny-Jev がない・失敗）または撮ったスクリーンショットがない：画像の言葉があれば、従来どおり、言葉で取り先を決める。
        case byWords
        case none

        /// 画像を、質問に使うか。
        public var usesImage: Bool {
            switch self {
            case .none, .skippedScreenshot: return false
            case .attached, .clipboard, .screenshot, .byWords: return true
            }
        }
    }

    /// - `judge`：撮ったスクリーンショットを、この質問に使う確率（`ChatImageUse`）。なければ nil。**スクリーンショットがあり、画像の指定が他にないときだけ**呼ぶ。
    public static func imagePlan(request: String, hasAttached: Bool, screenshotAvailable: Bool, judge: (() throws -> Double)?) -> ImagePlan {
        if hasAttached { return .attached }
        let wants = wants(request)
        if wants.image, ImageSource.clipboardWords.contains(where: request.contains) { return .clipboard }
        if wants.text { return .none }   // 「コピーした文章」と言った：画像の判定はしない
        if screenshotAvailable, let judge, let p = try? judge() { return p >= ChatImageUse.threshold ? .screenshot : .skippedScreenshot(p) }
        return wants.image ? .byWords : .none
    }
}
