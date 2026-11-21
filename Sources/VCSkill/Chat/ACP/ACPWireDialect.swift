import Foundation

/// ACP の接続（`ACPConnection`）が、相手と話す**言葉の訳し役**。ACP を話さないが、似た、行ごとの JSON の口（pi の RPC モード）を持つエージェントを、**ACP の言葉のまま**扱うための継ぎ目。
/// 接続は、ACP のメッセージ（要求・通知・応答）だけを、扱う。相手へ書く前と、相手から読んだあとに、ここを通す（なければ、そのまま：ACP を話すエージェント）。
protocol ACPWireDialect: AnyObject, Sendable {
    /// ACP 側が出したメッセージ（要求・通知・相手からの要求への応答）。→ 相手へ書く行・ACP 側へ、すぐ返すメッセージ（相手に聞かないもの）。
    func outgoing(_ message: JSONValue) -> ACPWireOutput
    /// 相手が書いた 1 行。→ ACP 側へ届けるメッセージ（通知・要求・応答）・相手へ、すぐ返す行。
    func incoming(_ record: JSONValue) -> ACPWireOutput
}

/// 訳した結果。
struct ACPWireOutput {
    /// 相手へ書く行。
    var lines: [JSONValue] = []
    /// ACP 側へ届けるメッセージ。
    var messages: [JSONValue] = []
}
