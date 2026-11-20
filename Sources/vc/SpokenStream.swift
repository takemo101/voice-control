import Foundation
import VCCore

/// 答えが**少しずつ届く**間に、読める文から、順に、声で読む塊にする（`SpokenText` の、順次版）。最初の文が届いたら、すぐ読み始められる（答えが全部そろうのを、待たない）。
/// - **区切り**：行の終わり（改行）・文の終わり（`。．！？`。英語の `. ! ?` は、**あとに空白が続いたとき**：`3.14`・`e.g.` を、切らない）。区切りまでが届くまで、読まない。
/// - **コードブロック**は、読まない（`SpokenText` と同じ）。終わりに、1 度だけ、「コードは、画面に出しています。」。
/// - 全部を足して読んだ文は、`SpokenText.chunks(from: 全文)` と、同じ（塊の切れ目だけが、違う）。**純粋**（声・画面を持たない）。
struct SpokenStream {
    /// 行の途中（改行がまだ届いていない）の文字。
    private var tail = ""
    private var inFence = false
    private var skippedCode = false
    /// 読む塊を、1 つでも出したか。
    private(set) var emitted = false

    /// 届いた続きの文字を足して、**読めるようになった**塊を返す（なければ、空）。
    mutating func push(_ delta: String) -> [String] {
        tail += delta
        var lines: [String] = []
        while let newline = tail.firstIndex(of: "\n") {
            let line = String(tail[..<newline])
            tail = String(tail[tail.index(after: newline)...])
            consume(line, into: &lines)
        }
        // 行の途中でも、文の終わりまで届いていれば、そこまで読む（行が長いとき、最初の文を、すぐ読み始める）
        if !inFence, !startsFence(tail), let cut = sentenceEnd(in: tail) {
            lines.append(String(tail[..<cut]))
            tail = String(tail[cut...]).trimmingCharacters(in: .whitespaces)
        }
        return chunks(from: lines)
    }

    /// 答えが終わった：残りを、すべて読める形にして返す（コードを飛ばしたなら、その知らせも）。
    mutating func finish() -> [String] {
        var lines: [String] = []
        if !tail.isEmpty { consume(tail, into: &lines) }
        tail = ""
        var out = chunks(from: lines)
        if skippedCode, emitted { out.append(tr("コードは、画面に出しています。")) }
        skippedCode = false
        return out
    }

    private mutating func consume(_ line: String, into lines: inout [String]) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if MarkdownPreprocess.isFence(trimmed) { inFence.toggle(); return }
        if inFence { skippedCode = true; return }
        lines.append(line)
    }

    private mutating func chunks(from lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let chunks = SpokenText.chunks(from: lines.joined(separator: "\n"))
        if !chunks.isEmpty { emitted = true }
        return chunks
    }

    /// 行頭が、コードブロックの印（```）の途中か（印かどうかが決まるまで、読まない）。
    private func startsFence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("``") || trimmed.hasPrefix("~~")
    }

    /// 文の終わりの、すぐあとの位置（最後の区切り）。なければ nil。
    private func sentenceEnd(in text: String) -> String.Index? {
        var cut: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if "。．！？".contains(character) { cut = next }
            else if ".!?".contains(character), next < text.endIndex, text[next].isWhitespace { cut = next }   // 英語：あとに空白が届いてから（`3.14` を、切らない）
            index = next
        }
        return cut
    }
}
