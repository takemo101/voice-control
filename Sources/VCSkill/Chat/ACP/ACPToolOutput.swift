import Foundation

/// ACP のツールの結果（`tool_call_update` の `content`）を、画面に出す形（`ChatActivity.Output`）にする（**純粋**）。
/// - コマンド（`execute`）：出力の文字。エージェントの付けた、時刻の見出し（agy：`Created At:`・`Completed At:`）は、外す。
/// - 書き込み・削除・移動（`edit`・`delete`・`move`）：**差分**（`diff`：`oldText`・`newText`・`path`）。差分がなければ、出さない（「成功した」だけの文は、価値が低い）。
/// - 読む・調べる・Web：出さない（ファイルの中身・ページの文字は、長く、**答えの文に、必要なことだけが、書かれる**）。
enum ACPToolOutput {
    static func make(kind: String, content: [JSONValue]) -> ChatActivity.Output? {
        switch kind {
        case "execute":
            let texts = content.compactMap { block -> String? in
                guard block["type"]?.string == "content" else { return nil }
                return block["content"]?["text"]?.string
            }
            // Claude：出力は、コードの囲み（```console）つきの塊。囲みのない塊は、コマンドの説明（出力ではない）なので、囲みつきがあれば、それだけを使う
            let fenced = texts.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") }
            return clean(output: (fenced.isEmpty ? texts : fenced).joined(separator: "\n"))
        case "edit", "delete", "move":
            let diffs = content.compactMap { block -> String? in
                guard block["type"]?.string == "diff", let new = block["newText"]?.string else { return nil }
                let body = ACPDiff.unified(old: block["oldText"]?.string, new: new)
                guard let path = block["path"]?.string else { return body }
                return "--- \(URL(fileURLWithPath: path).lastPathComponent)\n" + body
            }
            return diffs.isEmpty ? nil : ChatActivity.Output(text: diffs.joined(separator: "\n\n"), isDiff: true)
        default:
            return nil
        }
    }
}

extension ACPToolOutput {
    /// 端末の出力（Codex：`_meta.terminal_output_delta` の断片を、つないだもの）。
    static func terminal(_ text: String) -> ChatActivity.Output? { clean(output: text) }

    /// コマンドの出力の整え：改行・エージェントの付けた時刻の見出し・コードの囲み（```）の行を、外す。空なら nil。
    fileprivate static func clean(output text: String) -> ChatActivity.Output? {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .filter { !$0.hasPrefix("Created At:") && !$0.hasPrefix("Completed At:") && !$0.hasPrefix("```") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : ChatActivity.Output(text: cleaned)
    }
}

/// 差分の行（`+`・`-`・空白で始まる）。変わった行と、その前後の、少しの行だけを出す。
enum ACPDiff {
    static func unified(old: String?, new: String, context: Int = 2) -> String {
        let oldLines = lines(old ?? ""), newLines = lines(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [(mark: Character, text: String)] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) { rows.append(("-", oldLines[i])); i += 1 }
            else if j < newLines.count, inserted.contains(j) { rows.append(("+", newLines[j])); j += 1 }
            else if i < oldLines.count, j < newLines.count { rows.append((" ", oldLines[i])); i += 1; j += 1 }
            else { break }
        }
        // 変わった行の前後 `context` 行だけ残し、間は、「…」にする
        let changed = rows.indices.filter { rows[$0].mark != " " }
        var out: [String] = []
        var skipping = false
        for (index, row) in rows.enumerated() {
            let near = changed.contains { abs($0 - index) <= context }
            if near { out.append(String(row.mark) + row.text); skipping = false }
            else if !skipping { out.append("…"); skipping = true }
        }
        return out.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }   // 末尾の改行は、行を増やさない
        return parts
    }
}
