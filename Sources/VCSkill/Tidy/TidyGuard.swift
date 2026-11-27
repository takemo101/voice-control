import Foundation
import VCCore

/// 整理の結果を、**コードで検査する**（SPEC F79(4)）。通らなければ、**元の文字を入力する**（言語モデルの出力は、信頼しない）。
/// 検査は、「整える」を、**元の文字の書き換えだけ**に、縛るもの：新しい数字・否定の増減・極端な長さの変化は、内容を、変えた可能性が高い。
public enum TidyRejection: Error, Equatable, CustomStringConvertible, Sendable {
    /// 出力から、`<tidied_text>` を、取り出せない。
    case unreadable
    /// 元になかった数字が、出てきた。
    case newNumber
    /// 否定の語の数が、変わった（自分で言い直した文を除く）。
    case negationChanged
    /// 長さが、極端に違う。
    case lengthChanged
    /// モデルが、失敗した・使えない。
    case failed(String)
    /// 時間内に、終わらなかった。
    case timedOut

    public var description: String {
        switch self {
        case .unreadable: return tr("整理の結果を読めませんでした")
        case .newNumber: return tr("整理で数字が変わったので、元の文字を入れました")
        case .negationChanged: return tr("整理で否定が変わったので、元の文字を入れました")
        case .lengthChanged: return tr("整理で長さが大きく変わったので、元の文字を入れました")
        case let .failed(why): return tr("整理できませんでした（\(why)）")
        case .timedOut: return tr("整理が間に合いませんでした")
        }
    }
}

public enum TidyGuard {
    /// 整える価値のある、最小の長さ（これより短い文は、整理しない）。
    public static let minimumLength = 6
    /// 結果の長さの、元に対する範囲（言い直し・つなぎ言葉の除去で、縮む）。短い文は、絶対の差（`lengthSlack`）も許す。
    public static let lengthRange: ClosedRange<Double> = 0.4...1.6
    public static let lengthSlack = 6

    /// 出力から、整えた文字を取り出す（タグの中。なければ、nil）。
    public static func extract(_ response: String) -> String? {
        let hasOpen = response.contains("<tidied_text>"), hasClose = response.contains("</tidied_text>")
        guard hasOpen, hasClose,
              let open = response.range(of: "<tidied_text>"), let close = response.range(of: "</tidied_text>", range: open.upperBound..<response.endIndex) else { return nil }
        let text = String(response[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 検査。通れば nil、通らなければ、その理由。
    public static func check(original: String, tidied: String) -> TidyRejection? {
        // 数字：整理後の数字は、元にあったものだけ（言い直しで、減るのは、よい。新しい数字は、内容を変えた）
        if !numbers(in: tidied).isSubset(of: numbers(in: original)) { return .newNumber }
        // 否定：増えたら、不可。減るのは、**自分で言い直した文**（「行かない、いや行く」）だけ
        let before = negations(in: original), after = negations(in: tidied)
        if after > before || (after < before && !hasSelfCorrection(original)) { return .negationChanged }
        // 長さ
        let o = Double(original.count), t = Double(tidied.count)
        if abs(o - t) > Double(lengthSlack), !(lengthRange.contains(t / max(o, 1))) { return .lengthChanged }
        return nil
    }

    // MARK: 部品

    /// 数（0〜9 のつながり）の集まり。全角は、半角にそろえる。
    static func numbers(in text: String) -> Set<String> {
        let normalized = text.precomposedStringWithCompatibilityMapping
        let regex = try! NSRegularExpression(pattern: "[0-9]+")   // 固定の正規表現
        let range = NSRange(normalized.startIndex..., in: normalized)
        return Set(regex.matches(in: normalized, range: range).compactMap { Range($0.range, in: normalized).map { String(normalized[$0]) } })
    }

    /// 否定の語の数（日本語：ない・なかっ・なく・ません・ず・ぬ／英語：no・not・n't・never・without・cannot）。
    static func negations(in text: String) -> Int {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        let regex = try! NSRegularExpression(pattern: "ない|なかっ|なく|ません|ず|ぬ|n't|\\bnot\\b|\\bno\\b|\\bnever\\b|\\bwithout\\b|\\bcannot\\b")   // l10n-skip：照合に使う語（画面に出ない）
        return regex.numberOfMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
    }

    /// 自分で言い直した文か（言い直しの印がある）。
    static func hasSelfCorrection(_ text: String) -> Bool {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        return ["いや", "違う", "ちがう", "じゃなくて", "ではなく", "間違え", "間違い", "訂正", "i mean", "no wait", "sorry", "rather", "actually"].contains { normalized.contains($0) }   // l10n-skip：照合に使う語（画面に出ない）
    }
}
