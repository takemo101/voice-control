import Foundation
import VCCore

/// ACP の許可の確認（`session/request_permission`）に、どう答えるか（**純粋**：段階ごとの、開ける道具を、テストで確かめる）。
/// これまでの方式（`agy -p … --dangerously-skip-permissions`）は、「すべて」のとき、**全部を許可して、確認なし**だった。ACP は、操作の前に、聞いてくる：読む・調べる操作は、段階で決め、**書き込み・削除・コマンドの実行は、毎回、利用者に確認する**。
enum ACPPermission {
    enum Decision: Equatable {
        case allow
        /// 利用者に、確認する（「すべて」のときだけ）。
        case ask
        case reject
        /// 取り返しのつかないコマンド：段階・確認に関係なく、断る（パネルも出さない）。
        case block
        /// 自動モードで、コードの規則では決められないコマンド：Tiny-Jev に、無害かを聞く（`CommandSafetyJudge`）。無害でなければ、確認。
        case judge
    }

    /// Web に出る道具の名前（`opencode`：`websearch`・`webfetch`・`codesearch`）。`kind` だけでは、**調べる道具の、ローカル（grep）と Web（検索）が、区別できない**（opencode は、grep が `search`・Web 検索が `other`）。
    static let webTools: Set<String> = ["websearch", "webfetch", "codesearch", "web_search", "web_fetch"]
    /// 作業フォルダの中を、読むだけの道具の名前。
    static let folderReadTools: Set<String> = ["read", "grep", "glob", "list", "ls"]

    /// ツール 1 つを、段階（`level`）で、どう扱うか。`folder`：作業フォルダ。
    /// 名前は、**読む・調べるものを、開けるためだけ**に使う（書き込み・コマンドの種類の操作は、名前が何でも、確認か断る）。
    /// コマンドは、**取り返しのつかないものを断り**、作業フォルダの中を見るだけのものを、確認なしで許す（`ACPCommandPolicy`）。
    /// `auto`：**自動モード（作業フォルダの中は、確認なし）**：「すべて」のときだけ働く。呼ぶ側が、OS の制限（Seatbelt）が効いているときだけ、true にする（書き込みを、作業フォルダに限れないなら、自動にしない）。
    static func decide(_ call: ACPToolCall, folder: URL? = nil, level: ChatToolLevel, auto: Bool = false) -> Decision {
        let kind = call.kind
        let autoActive = auto && level == .all
        if kind == "execute", let command = call.command {
            if ACPCommandPolicy.isCatastrophic(command) { return .block }
            if level.usesFolder, let folder, ACPCommandPolicy.isHarmlessInFolder(command, folder: folder) { return .allow }
            // 自動：基本のコマンドは確認なし・危ないものは確認・ほかは Jev（書き込みの範囲は、OS の制限が、作業フォルダに限る）
            if autoActive {
                switch ACPCommandPolicy.autoClass(command) {
                case .free: return .allow
                case .confirm: return .ask
                case .judge: return .judge
                }
            }
        }
        if let name = call.name?.lowercased(), !["edit", "delete", "move", "execute", "switch_mode"].contains(kind) {
            if webTools.contains(name) { return level.searchesWeb ? .allow : .reject }
            if folderReadTools.contains(name) { return level.usesFolder ? .allow : .reject }
        }
        switch kind {
        case "think": return .allow
        case "search", "fetch": return level.searchesWeb ? .allow : .reject
        case "read": return level.usesFolder ? .allow : .reject
        default:
            guard level == .all else { return .reject }   // edit・delete・move・execute・switch_mode・other・知らない種類
            return autoActive ? autoDecision(call, kind: kind, folder: folder) : .ask
        }
    }

    /// 自動モードの、書き込み系：**作業フォルダの中の書き込みだけ**、確認なし。**フォルダの外への書き込みは、断る**（OS の制限も、書かせない）。**消す・移す**は、中でも、確認する。ほか（モードの切り替え・知らない種類）は、確認する。
    private static func autoDecision(_ call: ACPToolCall, kind: String, folder: URL?) -> Decision {
        guard let folder, let path = call.path, !path.isEmpty else { return .ask }
        let inside = RealPath.isInside(RealPath.eventual(path), root: RealPath.eventual(folder.path))
        switch kind {
        case "edit": return inside ? .allow : .reject
        case "delete", "move": return inside ? .ask : .reject
        default: return .ask
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
}
