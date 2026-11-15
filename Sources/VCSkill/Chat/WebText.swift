import Foundation

/// Web の検索結果・ページの HTML から、モデルに渡す文字を取り出す（純粋：テストで確かめる）と、取得してよい URL の判定。

enum WebText {
    struct Result: Equatable { var title: String; var url: String; var snippet: String }

    /// DuckDuckGo の HTML の結果を読む（上位 `limit` 件）。形が変わって読めなければ、空。
    static func parseSearch(_ html: String, limit: Int = 5) -> [Result] {
        var results: [Result] = []
        let linkPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#
        let links = matches(linkPattern, in: html)
        let snippets = matches(snippetPattern, in: html)
        for (index, link) in links.enumerated() where link.count == 2 {
            guard let url = resolve(link[0]), URLGuard.allows(url) else { continue }
            let snippet = index < snippets.count ? text(fromHTML: snippets[index][0]) : ""
            results.append(Result(title: clip(text(fromHTML: link[1]), 90), url: url.absoluteString, snippet: clip(snippet, 160)))
            if results.count == limit { break }
        }
        return results
    }

    /// 検索の結果を、モデルに返す文にする。
    static func render(_ results: [Result]) -> String {
        guard !results.isEmpty else { return "No results." }
        return results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)\n   \($0.element.snippet)" }.joined(separator: "\n")
    }

    /// ページの HTML から、読む文字だけ（スクリプト・スタイル・タグを除く）。`limit` 文字まで。
    static func pageText(_ html: String, limit: Int = 1800) -> String {
        var body = html
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer"] {
            body = body.replacingOccurrences(of: "(?is)<\(tag)\\b.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        body = body.replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: "(?i)</(p|div|li|h[1-6]|tr|br)\\s*>|<br\\s*/?>", with: "\n", options: .regularExpression)
        return clip(text(fromHTML: body, keepNewlines: true), limit)
    }

    /// タグを除き、よく使う実体参照を戻し、空白を詰める。
    static func text(fromHTML html: String, keepNewlines: Bool = false) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        if keepNewlines {
            let lines = text.split(separator: "\n").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }.filter { !$0.isEmpty }
            return lines.joined(separator: "\n")
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clip(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    /// 検索結果のリンクは、ときどき、`//duckduckgo.com/l/?uddg=<URL>` の中継：元の URL を取り出す。
    private static func resolve(_ href: String) -> URL? {
        let raw = href.replacingOccurrences(of: "&amp;", with: "&")
        let absolute = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let url = URL(string: absolute) else { return nil }
        if url.host?.hasSuffix("duckduckgo.com") == true, url.path.hasPrefix("/l"),
           let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: target)
        }
        return url
    }
}

/// 取得してよい URL か：http・https だけ。この Mac の中・同じ建物の中（localhost・プライベートの IP・`.local`）・認証情報つきは、取らない（モデルが、中のサービスを叩かないように）。
enum URLGuard {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") { return false }
        if host.contains(":") { return false }   // IPv6 の直書きは、取らない
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 && host.allSatisfy({ $0.isNumber || $0 == "." }) {
            let (a, b) = (parts[0], parts[1])
            if a == 10 || a == 127 || a == 0 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || a >= 224 { return false }
        } else if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }   // 数字だけの変な書き方（2130706433 など）
        return true
    }
}
