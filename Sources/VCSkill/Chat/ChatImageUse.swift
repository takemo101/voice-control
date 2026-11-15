import Foundation
import VCDecision

/// 会話で、**撮ったスクリーンショット**（ショートカットで撮ったもの）を、この質問に使うかの判定。
/// 言葉の一致（「画面」「画像」）では、「これ」「ここ」を見落とし、「スクショの撮り方は？」で、誤って反応するので、**Tiny-Jev が、質問の種類を、多択で選ぶ**。
/// 「画面を撮る」で添えた画像は、判定しない（使う）。判定が外れたときの被害：使うべきときに使わない → 「画面を撮る」で添えれば、必ず使う。使わないときに使う → Apple のモデルは、画像を読む時間がかかり、その会話では Web の道具を使わない。外のエージェントへは、毎回確認する。
/// **同じスクリーンショットは、1 度使ったら、次の質問では、判定せずに使わない**（`ScreenshotLedger`）：判定が外れると、どの質問にも、画像が付いてしまったので（利用者の報告）。
///
/// **測定（`vc eval-judge image`。docs/verification.md）**：最初の「2 つの言い方から選ぶ」形は、確率が 1 に近いところに集まり（0.96〜0.998）、画像なしの質問の約 4 割を、画像についてと誤った（実際の利用で、どの質問にも画像が付いた）。
/// **画像についてを 1 つ、ほかの種類（天気・説明・あいさつ・提案・続きの質問）を 5 つ並べた、多択**にすると、確率がばらけ（0.01〜0.99）、しきい値 0.9 で、誤りが減った。
/// 言い方としきい値は、自作の 76 文（`chat-image.tsv`・`chat-image-holdout.tsv`）で決めた（**調整に使った**）。そのあと、**見ずに作った 30 文**（`chat-image-test.tsv`）で測った：画像について 9/14 を使い、画像なしの 14/16 を使わなかった。
public struct ChatImageUse: Sendable {
    /// 画像についての確率の下限（上の測定で決めた）。
    public static let threshold = 0.9
    private let scorer: OptionScorer
    public init(scorer: OptionScorer) { self.scorer = scorer }

    /// 画像についての質問である確率。**直前のやり取りは、渡さない**：渡しても、測定の結果は変わらず、画像についての会話のあとで話題を変えた質問（「明日の天気は？」）を、画像についてと誤った。
    /// Apple のモデルは、画像を、1 度だけ文字にして会話に入れる（`attached`）ので、続きの質問は、画像の内容を、会話の記録から読める。
    public func probability(request: String) throws -> Double {
        let p = try scorer.score(
            state: "利用者は、いま、画面のスクリーンショットを撮った。\n発話: \(request)", question: "この発話は、何についてか",
            options: ["画面に写っているものについての質問（「これ」「ここ」「このエラー」を含む）", "天気・ニュース・最新の情報の質問", "知識・仕組み・使い方の説明を求める質問",
                      "あいさつ・お礼・雑談", "文章・アイデア・提案を作る依頼", "続きの質問（それ・さっきの・ほかには）"])
        return p[0]
    }
}

/// **撮ったスクリーンショットを、何度も使わない**ための記録：判定で使った（または添えた）スクリーンショットは、次の質問では、判定せずに使わない（言葉で「この画面」と頼めば、使う）。
/// 使わなかった（判定が、画像なし）ときの断りは、同じスクリーンショットについて、1 度だけ出す。
public struct ScreenshotLedger: Equatable, Sendable {
    private var used: String?
    private var noted: String?
    public init() {}

    /// まだ使っていないスクリーンショットか（`key`：中身の指紋）。
    public func isFresh(_ key: String) -> Bool { key != used }
    public mutating func markUsed(_ key: String) { used = key }
    /// 「使いませんでした」の断りを、出すか（同じスクリーンショットについて、1 度だけ）。
    public mutating func shouldNoteSkip(_ key: String) -> Bool {
        defer { noted = key }
        return noted != key
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
