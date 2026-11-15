import Foundation

/// 外のエージェントの CLI が、実行中に出す出来事（JSON の行）から、**いま何をしているか**を読み取る（`claude`・`codex`・`grok`）。
/// 「実行: ls」「検索: …」「読む: README.md」のような、短い文にして、画面に出す（道具を開けたとき、**何が実行されたかを、利用者が見られる**ようにするため）。
/// 読み取れない行は、読み捨てる（CLI の出力の形が変わっても、会話は、止まらない：表示が、出なくなるだけ）。**純粋**：テストできる。
public struct AgentStream: Sendable {
    public enum Event: Equatable, Sendable {
        /// いまの操作（例：「実行: ls」）。
        case activity(ChatActivity)
        /// 答えの文字（`grok` は、細かい塊で届く）。
        case text(String)
        /// 最終の答え（`claude` の result）。
        case final(String)
        /// エージェントが、失敗を知らせた。
        case failure(String)
    }

    private let agent: ChatAgent
    private var buffer = Data()

    public init(agent: ChatAgent) { self.agent = agent }

    /// 届いた塊を渡す。完成した行ごとの、出来事を返す。
    public mutating func feed(_ chunk: Data) -> [Event] {
        buffer.append(chunk)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { events += Self.events(from: object, agent: agent) }
        }
        return events
    }

    static func events(from object: [String: Any], agent: ChatAgent) -> [Event] {
        switch agent {
        case .claude: return claude(object)
        case .codex: return codex(object)
        case .grok: return grok(object)
        case .agy: return agy(object)
        case .opencode: return opencode(object)
        case .pi: return pi(object)
        case .apple: return []
        }
    }

    // MARK: claude（`--output-format stream-json --verbose`）

    private static func claude(_ o: [String: Any]) -> [Event] {
        switch o["type"] as? String {
        case "assistant":
            let blocks = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                return .activity(describe(tool: name, input: block["input"] as? [String: Any] ?? [:]))
            }
        case "result":
            if (o["is_error"] as? Bool) == true { return [.failure((o["result"] as? String) ?? "失敗しました")] }
            return (o["result"] as? String).map { [.final($0)] } ?? []
        default: return []
        }
    }

    // MARK: codex（`exec --json`）

    private static func codex(_ o: [String: Any]) -> [Event] {
        guard o["type"] as? String == "item.started", let item = o["item"] as? [String: Any], let kind = item["type"] as? String else { return [] }
        switch kind {
        case "command_execution":
            var command = (item["command"] as? String) ?? ""
            for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc "] where command.hasPrefix(prefix) { command = String(command.dropFirst(prefix.count)); break }
            return [.activity(.run(clip(unquote(command))))]
        case "web_search": return [.activity(.search(clip((item["query"] as? String) ?? "")))]
        case "file_change": return [.activity(.write("（ファイルを変更）"))]
        default: return []
        }
    }

    // MARK: grok（`--output-format streaming-json`）

    private static func grok(_ o: [String: Any]) -> [Event] {
        switch o["type"] as? String {
        case "text": return (o["data"] as? String).map { [.text($0)] } ?? []
        case "tool_call":
            let name = (o["toolName"] as? String) ?? (o["title"] as? String) ?? "道具"
            return [.activity(describe(tool: name, input: o["rawInput"] as? [String: Any] ?? [:]))]
        default: return []
        }
    }

    // MARK: agy（`--output-format stream-json`）

    private static func agy(_ o: [String: Any]) -> [Event] {
        switch o["event"] as? String {
        case "step_update":
            // 道具の呼び出し：始まったとき（ACTIVE）だけ（終わりは、重ねない）
            guard let step = o["step_update"] as? [String: Any], step["step_type"] as? String == "tool", step["state"] as? String == "ACTIVE",
                  let name = step["tool_name"] as? String else { return [] }
            let parameters = (step["tool_info"] as? [String: Any])?["parameters"] as? [String: Any] ?? [:]
            return [.activity(describe(tool: name, input: Dictionary(uniqueKeysWithValues: parameters.map { ($0.key.lowercased(), $0.value) })))]
        case "result":
            guard let result = o["result"] as? [String: Any] else { return [] }
            if (result["status"] as? String) != "SUCCESS" { return [.failure((result["status"] as? String) ?? "失敗しました")] }
            return (result["response"] as? String).map { [.final($0)] } ?? []
        default: return []
        }
    }

    // MARK: opencode（`run --format json`）

    private static func opencode(_ o: [String: Any]) -> [Event] {
        guard let part = o["part"] as? [String: Any] else { return [] }
        switch o["type"] as? String {
        case "tool_use":
            guard let name = part["tool"] as? String else { return [] }
            var input = (part["state"] as? [String: Any])?["input"] as? [String: Any] ?? [:]
            // `patch` は、パッチの文章の中に、ファイル名がある（`*** Add File: done.txt`）
            if name == "patch", let patch = input["patchText"] as? String,
               let line = patch.split(separator: "\n").first(where: { $0.hasPrefix("*** ") && $0.contains("File: ") }), let range = line.range(of: "File: ") {
                input["path"] = String(line[range.upperBound...])
            }
            return [.activity(describe(tool: name, input: input))]
        case "text": return (part["text"] as? String).map { [.final($0)] } ?? []   // 最後の文章が、答え
        default: return []
        }
    }

    // MARK: pi（`--mode json`）

    private static func pi(_ o: [String: Any]) -> [Event] {
        switch o["type"] as? String {
        case "tool_execution_start":
            guard let name = o["toolName"] as? String else { return [] }
            return [.activity(describe(tool: name, input: o["args"] as? [String: Any] ?? [:]))]
        case "message_end":
            guard let message = o["message"] as? [String: Any], message["role"] as? String == "assistant" else { return [] }
            let text = ((message["content"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return text.isEmpty ? [] : [.final(text)]   // 最後の、文章のある返事が、答え
        default: return []
        }
    }

    // MARK: 共通

    /// 道具の名前と入力から、いまの操作にする（名前は、CLI ごとに違う：`Bash`・`run_terminal_command` など）。
    static func describe(tool: String, input: [String: Any]) -> ChatActivity {
        // CLI ごとに、入力の名前が違う（`file_path`・`target_file`・`path` など）。知っている名前を先に探し、なければ、最初の文字列
        func string(_ keys: String...) -> String {
            keys.compactMap { input[$0] as? String }.first ?? ["file_path", "target_file", "target_directory", "path", "query", "url", "command", "pattern"].compactMap { input[$0] as? String }.first ?? input.values.compactMap { $0 as? String }.first ?? ""
        }
        switch tool.lowercased() {
        case "bash", "run_terminal_command", "shell", "execute", "run_command": return .run(clip(string("command", "commandline")))
        case "websearch", "web_search", "search_web": return .search(clip(string("query")))
        case "webfetch", "web_fetch", "read_url_content": return .fetch(clip(string("url")))
        case "read", "read_file", "view_file", "view_file_outline": return .read(clip(string("file_path", "path")))
        case "write", "edit", "multiedit", "search_replace", "apply_patch", "patch", "write_file", "replace_file_content", "write_to_file", "multi_replace_file_content": return .write(clip(string("file_path", "path")))
        case "glob", "list_dir", "ls": return .list(clip(string("pattern", "path")))
        case "grep": return .find(clip(string("pattern")))
        default:
            let extra = (input["description"] as? String) ?? (input["command"] as? String) ?? ""
            return .other(clip(tool + (extra.isEmpty ? "" : ": " + extra)))
        }
    }

    private static func unquote(_ text: String) -> String {
        if text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first { return String(text.dropFirst().dropLast()) }
        return text
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }
}
