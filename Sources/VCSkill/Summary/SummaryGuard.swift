import Foundation
import VCCore

/// 要約の失敗の理由。
public enum SummaryFailure: Error, Equatable, CustomStringConvertible, Sendable {
    /// 要約する発話が、ない。
    case empty
    /// 出力から、`<summary>` を、取り出せない。
    case unreadable
    /// 話になかった数字が、出てきた（作り話の恐れ）。
    case newNumber(String)
    /// 言語モデルが、失敗した・使えない。
    case failed(String)
    /// 時間内に、終わらなかった。
    case timedOut
    /// 長すぎて、まとめきれない。
    case tooLong

    public var description: String {
        switch self {
        case .empty: return tr("要約する発話が、ありません")
        case .unreadable: return tr("要約の結果を読めませんでした")
        case let .newNumber(number): return tr("要約に、話にない数字（\(number)）が出たので、出しません")
        case let .failed(why): return tr("要約できませんでした（\(why)）")
        case .timedOut: return tr("要約が間に合いませんでした")
        case .tooLong: return tr("会議が長すぎて、要約しきれません")
        }
    }
}

/// 要約の出力の検査（**コード**。モデルの出力は、信頼しない）：「要約」の囲みから取り出す・**元の話にない数字を、出さない**（要約は、数字を減らすのはよいが、足してはいけない）。
public enum SummaryGuard {
    /// 取り出し結果。
    public enum Extracted: Equatable {
        case summary(String)
        /// テーマに合う話が、なかった。
        case nothing
    }

    /// 出力から、要約を取り出す（タグの中。なければ、nil）。
    public static func extract(_ response: String) -> Extracted? {
        guard let open = response.range(of: "<summary>"), let close = response.range(of: "</summary>", range: open.upperBound..<response.endIndex) else { return nil }
        let text = String(response[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text == SummaryPrompt.none { return .nothing }
        return .summary(text)
    }

    /// 選んだ行の番号を、取り出す（`<lines>1,3</lines>`）。「該当なし」は空。読めない・範囲外の番号は、nil（作り話の番号を、使わない）。
    public static func extractLines(_ response: String, count: Int) -> [Int]? {
        guard let open = response.range(of: "<lines>"), let close = response.range(of: "</lines>", range: open.upperBound..<response.endIndex) else { return nil }
        let body = String(response[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty || body == SummaryPrompt.none { return [] }
        let numbers = body.split(whereSeparator: { ", 、，".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [Int] = []
        for token in numbers where !token.isEmpty {
            guard let number = Int(token.precomposedStringWithCompatibilityMapping), (1...max(count, 1)).contains(number) else { return nil }
            if !result.contains(number) { result.append(number) }
        }
        return result.sorted()
    }

    /// 検査。通れば nil。`source`：要約の元（発話の文字・途中の要約）。
    public static func check(summary: String, source: String) -> SummaryFailure? {
        let allowed = TidyGuard.numbers(in: source)
        if let extra = TidyGuard.numbers(in: summary).subtracting(allowed).sorted().first { return .newNumber(extra) }
        return nil
    }
}

/// 長い会議を、分けて要約するための、発話の分け方（**純粋**）。
public enum SummaryChunker {
    /// 発話を、順に、`budget` 文字以内の塊に分ける（1 つの発話が、それより長ければ、その発話だけの塊）。
    public static func chunks(_ lines: [SummaryLine], budget: Int) -> [[SummaryLine]] {
        var result: [[SummaryLine]] = []
        var current: [SummaryLine] = [], size = 0
        for line in lines {
            let cost = line.formatted.count + 1
            if !current.isEmpty, size + cost > budget { result.append(current); current = []; size = 0 }
            current.append(line); size += cost
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 途中の要約を、`budget` 文字以内の組に分ける（まとめを、繰り返すとき）。
    public static func groups(_ parts: [String], budget: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = [], size = 0
        for part in parts {
            if !current.isEmpty, size + part.count + 8 > budget { result.append(current); current = []; size = 0 }
            current.append(part); size += part.count + 8
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
