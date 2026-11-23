import Foundation

/// エンドポイントの**文字の形**（`[http://]<ポート>`・`[http://]<ホスト>:<ポート>`、どちらも、あとに経路 `/v1` などを付けられる）の、**解釈の入口**。
/// `--engine` の書き方（`Engine.parse`）と、設定ウィンドウの入力（貼り付けた URL を、保存する形にする）が、**同じ分け方**を使う（以前は、別々に、スキーム・経路を分けていた）。
public enum EndpointText {
    public struct Parts: Equatable {
        /// `://` の前（小文字）。なければ nil。
        public let scheme: String?
        /// ホストとポート（`192.168.1.5:8080`・`8000`・`box.local`）。
        public let authority: String
        /// 経路（`/v1`・`/openai/v1`）。終わりの `/` は、落とす。なければ、空。
        public let path: String
    }

    /// スキーム・ホストとポート・経路に分ける（検査は、しない）。
    public static func parts(_ raw: String) -> Parts {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme: String?
        if let range = text.range(of: "://") {
            scheme = String(text[..<range.lowerBound]).lowercased()
            text = String(text[range.upperBound...])
        }
        var path = ""
        if let slash = text.firstIndex(of: "/") { path = String(text[slash...]); text = String(text[..<slash]) }
        while path.hasSuffix("/") { path.removeLast() }
        return Parts(scheme: scheme, authority: text, path: path)
    }

    /// 画面の入力を、**保存する形**にする：`http://` は落とし（ポートがなければ `:80`）、終わりの `/` も落とす。経路は、残す。
    /// `http` 以外のスキーム（`https://` など）は、保存する形にできない：`unsupportedScheme` に、そのスキームを返す（`value` は、入力のまま）。
    public static func canonical(_ raw: String) -> (value: String, unsupportedScheme: String?) {
        let parts = parts(raw)
        if let scheme = parts.scheme, scheme != "http" { return (raw.trimmingCharacters(in: .whitespacesAndNewlines), scheme) }
        var authority = parts.authority
        if parts.scheme != nil, !authority.isEmpty, !authority.contains(":") { authority += ":80" }   // ポートを省いた `http://` の URL：80
        return (authority + parts.path, nil)
    }
}
