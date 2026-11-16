import Foundation

/// ACP の許可の確認（`session/request_permission`）に、どう答えるか（**純粋**：段階ごとの、開ける道具を、テストで確かめる）。
/// これまでの方式（`agy -p … --dangerously-skip-permissions`）は、「すべて」のとき、**全部を許可して、確認なし**だった。ACP は、操作の前に、聞いてくる：読む・調べる操作は、段階で決め、**書き込み・削除・コマンドの実行は、毎回、利用者に確認する**。
enum ACPPermission {
    enum Decision: Equatable {
        case allow
        /// 利用者に、確認する（「すべて」のときだけ）。
        case ask
        case reject
    }

    /// `kind`：ACP のツールの種類（read・search・fetch・think・edit・delete・move・execute・switch_mode・other）。
    static func decide(kind: String, level: ChatToolLevel) -> Decision {
        switch kind {
        case "think": return .allow
        case "search", "fetch": return level.searchesWeb ? .allow : .reject
        case "read": return level.usesFolder ? .allow : .reject
        default: return level == .all ? .ask : .reject   // edit・delete・move・execute・switch_mode・other・知らない種類
        }
    }

    /// 応答に使う選択肢（`allow_once` か `reject_once`）。なければ、取りやめ（`cancelled`）。
    static func outcome(allow: Bool, options: [JSONValue]) -> JSONValue {
        let wanted = allow ? "allow_once" : "reject_once"
        if let option = options.first(where: { $0["kind"]?.string == wanted }), let id = option["optionId"]?.string {
            return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(id)])])
        }
        return .object(["outcome": .object(["outcome": .string("cancelled")])])
    }

    /// 確認の文（何をするか）：種類と、**実際の場所・コマンド**。エージェントの題（`File ../../../private/var/…`）は、読みにくく、本当の場所を隠すので、使わない（場所がなければ、題）。
    static func detail(kind: String, toolCall: JSONValue, folder: URL) -> String {
        let title = toolCall["title"]?.string ?? toolCall["name"]?.string ?? "操作"
        let path = toolCall["locations"]?.array?.first?["path"]?.string.map { displayPath($0, folder: folder) }
        switch kind {
        case "edit": return "ファイルを書き込む：\(path ?? title)"
        case "delete": return "ファイルを削除する：\(path ?? title)"
        case "move": return "ファイルを移動する：\(path ?? title)"
        case "execute": return "コマンドを実行する：\(command(in: toolCall) ?? title)"
        default: return "操作する：\(path ?? title)"
        }
    }

    /// 場所の見せ方：作業フォルダの中は、そこからの相対（`notes/a.txt`）。**外は、全部の場所に、「作業フォルダの外」を添える**（外への書き込みに、気づけるように）。
    static func displayPath(_ path: String, folder: URL) -> String {
        let root = canonicalPath(folder.path)
        let target = canonicalPath(path)
        if target == root { return "." }
        if target.hasPrefix(root + "/") { return String(target.dropFirst(root.count + 1)) }
        return target + "（作業フォルダの外）"
    }

    /// 実際の場所（シンボリックリンク・`..` を解いた形）。**まだない（これから作る）ファイル**は、いちばん近い、ある場所を解いて、残りをつなぐ。
    /// `URL.resolvingSymlinksInPath` は、使わない：ある場所と、ない場所で、`/var` と `/private/var` の扱いが違い、作業フォルダの中を、「外」と、取り違えた（実機の確認で見つけた）。
    static func canonicalPath(_ path: String) -> String {
        var rest: [String] = []
        var current = (path as NSString).standardizingPath
        while true {
            if let resolved = realpath(current, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + rest.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else { return (path as NSString).standardizingPath }
            rest.append((current as NSString).lastPathComponent)
            current = parent
        }
    }

    /// 実行するコマンド（入力の中の、コマンドらしい文字列）。
    static func command(in toolCall: JSONValue) -> String? {
        let input = toolCall["rawInput"]
        for key in ["CommandLine", "commandLine", "command", "Command", "cmd"] {
            if let text = input?[key]?.string, !text.isEmpty { return text.count > 200 ? String(text.prefix(200)) + "…" : text }
        }
        return nil
    }

    /// 実行中の操作（画面に出す）。出さないもの（考え中）は、nil。
    static func activity(kind: String, title: String) -> ChatActivity? {
        switch kind {
        case "think": return nil
        case "read": return .read(title)
        case "search": return .search(title)
        case "fetch": return .fetch(title)
        case "edit", "delete", "move": return .write(title)
        case "execute": return .run(title)
        default: return .other(title)
        }
    }
}
