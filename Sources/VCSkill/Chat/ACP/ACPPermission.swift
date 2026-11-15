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

    /// 確認の文（何をするか）：種類と、ツールの題・場所。
    static func detail(kind: String, toolCall: JSONValue) -> String {
        let title = toolCall["title"]?.string ?? toolCall["name"]?.string ?? "操作"
        switch kind {
        case "edit": return "ファイルを書き込む：\(title)"
        case "delete": return "ファイルを削除する：\(title)"
        case "move": return "ファイルを移動する：\(title)"
        case "execute": return "コマンドを実行する：\(title)"
        default: return "操作する：\(title)"
        }
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
