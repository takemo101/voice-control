import Foundation

/// ACP の、エージェントが使おうとするツール（`session/request_permission`・`session/update` の `toolCall`）。**境界で、一度だけ、型にする**：エージェントの文字（非信頼）を、判断（`ACPPermission`）・表示（`ACPPermissionText`）が、別々に、読み直さない。
struct ACPToolCall: Equatable {
    /// ACP の種類（read・search・fetch・think・edit・delete・move・execute・switch_mode・other）。なければ `other`。
    var kind: String
    /// ツールの名前（あれば。エージェントが決める）。
    var name: String?
    /// エージェントの題（表示用。なければ、名前・「操作」）。
    var title: String
    /// 対象の場所（最初の 1 つ。エージェントの書いた、そのままの文字）。
    var path: String?
    /// 実行するコマンド（そのままの文字。切らない）。
    var command: String?

    init(kind: String = "other", name: String? = nil, title: String? = nil, path: String? = nil, command: String? = nil) {
        self.kind = kind; self.name = name; self.title = title ?? name ?? "操作"; self.path = path; self.command = command
    }

    /// 相手からの JSON から。
    init(_ json: JSONValue) {
        let input = json["rawInput"]
        let command = ["CommandLine", "commandLine", "command", "Command", "cmd"].lazy.compactMap { input?[$0]?.string }.first { !$0.isEmpty }
        self.init(kind: json["kind"]?.string ?? "other", name: json["name"]?.string, title: json["title"]?.string, path: json["locations"]?.array?.first?["path"]?.string, command: command)
    }
}
