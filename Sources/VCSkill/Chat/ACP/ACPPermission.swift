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

    /// Web に出る道具の名前（`opencode`：`websearch`・`webfetch`・`codesearch`）。`kind` だけでは、**調べる道具の、ローカル（grep）と Web（検索）が、区別できない**（opencode は、grep が `search`・Web 検索が `other`）。
    static let webTools: Set<String> = ["websearch", "webfetch", "codesearch", "web_search", "web_fetch"]
    /// 作業フォルダの中を、読むだけの道具の名前。
    static let folderReadTools: Set<String> = ["read", "grep", "glob", "list", "ls"]

    /// `kind`：ACP のツールの種類（read・search・fetch・think・edit・delete・move・execute・switch_mode・other）。`name`：ツールの名前（あれば。エージェントが決める）。
    /// 名前は、**読む・調べるものを、開けるためだけ**に使う（書き込み・コマンドの種類の操作は、名前が何でも、確認か断る）。
    static func decide(kind: String, name: String? = nil, level: ChatToolLevel) -> Decision {
        if let name = name?.lowercased(), !["edit", "delete", "move", "execute", "switch_mode"].contains(kind) {
            if webTools.contains(name) { return level.searchesWeb ? .allow : .reject }
            if folderReadTools.contains(name) { return level.usesFolder ? .allow : .reject }
        }
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
        return cancelledOutcome
    }

    /// 質問が、取りやめになったときの返事（仕様：取りやめた質問の、待っている許可の要求には、`cancelled` で、答えなければならない）。
    static let cancelledOutcome: JSONValue = .object(["outcome": .object(["outcome": .string("cancelled")])])

    /// 確認の文（何をするか）：種類と、**実際の場所・コマンド**。エージェントの題（`File ../../../private/var/…`）は、読みにくく、本当の場所を隠すので、使わない（場所がなければ、題）。
    static func detail(kind: String, toolCall: JSONValue, folder: URL) -> String {
        let title = visible(toolCall["title"]?.string ?? toolCall["name"]?.string ?? "操作")
        let path = toolCall["locations"]?.array?.first?["path"]?.string.map { visible(displayPath($0, folder: folder)) }
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
            if let text = input?[key]?.string, !text.isEmpty { return visible(text.count > 600 ? String(text.prefix(600)) + "…（残り \(text.count - 600) 文字）" : text) }
        }
        return nil
    }

    /// 確認の文に出す、エージェントの文字：**見えない文字・向きを変える文字・制御文字を、見える形（`⟨U+202E⟩`）にする**（仕様の安全の指針：コマンド・場所に、紛れ込ませて、読み違えさせる手を、防ぐ）。改行・タブは、空白。
    static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x0A || v == 0x0D || v == 0x09 { out += " "; continue }
            let hidden = v < 0x20 || (0x7F...0x9F).contains(v) || (0x200B...0x200F).contains(v) || (0x2028...0x202E).contains(v)
                || (0x2060...0x2069).contains(v) || v == 0xFEFF || (0xE0000...0xE007F).contains(v)
            out += hidden ? "⟨U+" + String(v, radix: 16, uppercase: true) + "⟩" : String(scalar)
        }
        return out
    }

    /// 実行中の操作（画面に出す）。出さないもの（考え中）は、nil。
    static func activity(kind: String, name: String? = nil, title: String) -> ChatActivity? {
        switch kind {
        case "think": return nil
        case "read": return .read(title)
        case "search": return folderReadTools.contains(name?.lowercased() ?? "") ? .read(title) : .search(title)   // grep・glob は、フォルダの中を読む
        case "fetch": return .fetch(title)
        case "edit", "delete", "move": return .write(title)
        case "execute": return .run(title)
        default: return .other(title)
        }
    }
}
