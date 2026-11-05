import Foundation
import VCDecision

/// Tiny-Jev で、候補の中から、依頼に合うものを選ぶ（`vc pick`。ファイル検索・ほかの「選ぶ」に使う、汎用の部品）。
/// 候補は、短い 1 行の文字（名前・種類・日付など）。確率は、**誤りにも高く出る**ので、閾値（既定 0.7）を超えたときだけ「選んだ」、超えなければ「迷っている」（利用者に聞く）。
/// 測定（自作の 16 場面。ファイルの候補）：名前・種類・フォルダでの選択は 14/16。外れたのは、「新しいほう」「古いほう」（日付の比較。Tiny-Jev は、日付の大小を読めない）：**日付・順番は、コード（並べ替え・番号）で扱う**。「今日は…」の文脈を足すと、悪くなった（6/16）ので、足さない。
public enum Picker {
    public static let defaultThreshold = 0.7
    public static let defaultQuestion = "ユーザーが選びたいのは、どれか"
    public static let defaultNone = "どれでもない"
    /// 採点に渡す 1 行の長さ（長い候補は、切る。長いと、判定が崩れ、入力の上限に届く）。
    static let maxOptionLength = 90

    public enum Verdict: Sendable, Equatable {
        /// 確信できた（候補の添字）。
        case picked(Int)
        /// 迷っている（上位の添字）。利用者に、聞く。
        case ambiguous([Int])
        /// どれでもない。
        case none
    }

    public struct Result: Sendable {
        public let verdict: Verdict
        /// 確率の降順（`index == nil` は「どれでもない」）。
        public let ranked: [(index: Int?, probability: Double)]
    }

    public static func pick(query: String, options: [String], question: String = defaultQuestion, none: String = defaultNone,
                            threshold: Double = defaultThreshold, scorer: OptionScorer) throws -> Result {
        guard !options.isEmpty else { return Result(verdict: .none, ranked: [(nil, 1)]) }
        let lines = options.map { String($0.prefix(maxOptionLength)) }
        let pick = try Chooser(scorer: scorer).pick(state: query, question: question, options: lines, none: none)
        guard let top = pick.index else { return Result(verdict: .none, ranked: pick.ranked) }
        if pick.probability >= threshold { return Result(verdict: .picked(top), ranked: pick.ranked) }
        let close = pick.ranked.compactMap { $0.index }.prefix(3)
        return Result(verdict: .ambiguous(Array(close)), ranked: pick.ranked)
    }

    /// 画面（と、言語モデル）へ返す文：結果（`verdict:`）と、上位の候補（番号・確率）。番号は、`options` の位置（1 から）。
    public static func format(_ result: Result, options: [String], top: Int = 5) -> String {
        var lines: [String] = []
        switch result.verdict {
        case .picked(let i): lines.append("verdict: picked\n\(options[i])")
        case .ambiguous(let ids): lines.append("verdict: ambiguous (ask the user which one: " + ids.map { "\($0 + 1)" }.joined(separator: ", ") + ")")
        case .none: lines.append("verdict: none (no option matches)")
        }
        lines.append("ranked:")
        for entry in result.ranked.prefix(top) {
            let percent = Int((entry.probability * 100).rounded())
            if let i = entry.index { lines.append("\(i + 1). \(options[i])  \(percent)%") } else { lines.append("- none  \(percent)%") }
        }
        return lines.joined(separator: "\n")
    }
}
