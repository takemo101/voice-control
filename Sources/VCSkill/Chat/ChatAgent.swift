import Foundation
import VCCore

/// 会話に使うエージェント（答えを作る側）。**既定は、この Mac の Apple のモデル**（外へ出さない）。
/// `agy`・`claude`・`codex`・`grok`・`opencode`・`pi`（コーディングエージェントの CLI）を選ぶと、**会話の発話が、その提供元へ送られる**：`ask-agent` と同じ、「この Mac の外へ出さない」の例外（SPEC N1）。利用者が `設定ウィンドウ > モデル set` で選んだときだけ。
public enum ChatAgent: String, CaseIterable, Sendable {
    case apple, agy, claude, codex, grok, opencode, pi

    /// この Mac の外へ送るか。
    public var isExternal: Bool { self != .apple }

    /// 表示名（提供元）。
    public var label: String {
        switch self {
        case .apple: return "Apple のモデル（この Mac の中）"
        case .agy: return "Antigravity（agy。Google）"
        case .claude: return "Claude Code（claude。Anthropic）"
        case .codex: return "Codex（codex。OpenAI）"
        case .grok: return "Grok（grok。xAI）"
        case .opencode: return "OpenCode（opencode。設定したモデルの提供元）"
        case .pi: return "pi（pi。設定したモデルの提供元）"
        }
    }

    /// 声・文字での呼び名も受ける（`ask-agent` と同じ）。
    public static func parse(_ text: String) -> ChatAgent? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        let aliases: [String: ChatAgent] = [
            "apple": .apple, "fm": .apple, "アップル": .apple,
            "agy": .agy, "antigravity": .agy, "アンチグラビティ": .agy,
            "claude": .claude, "クロード": .claude,
            "codex": .codex, "コーデックス": .codex,
            "grok": .grok, "グロック": .grok,
            "opencode": .opencode, "open code": .opencode, "オープンコード": .opencode,
            "pi": .pi, "パイ": .pi,
        ]
        return aliases[key]
    }

    /// このエージェントの、会話の長さの決まり。Apple は 8,192 トークンなので小さく、外のエージェントは、大きな文脈を持つので、大きくする（毎回、全部を送るので、大きすぎると、遅く・高くなる）。
    public var budget: ChatBudget {
        isExternal ? ChatBudget(trigger: 24_000, keepRecent: 8_000, summaryMaxCharacters: 1500, notesMaxCharacters: 1500) : .standard
    }

    /// 答える側。`tools`・`folder`：外のエージェントに開ける道具の段階と、作業フォルダ（Apple には、効かない）。
    /// `acp`：ACP に対応したエージェント（`speaksACP`）は、常駐の ACP で話す（使えなければ、従来の方式へ戻る）。
    public func makeBackend(tools: ChatToolLevel = .none, folder: URL? = nil, acp: Bool = true) -> ChatBackend {
        guard isExternal else { return AppleChatBackend(tools: tools, folder: folder) }
        return acp && speaksACP ? ACPChatBackend(agent: self, tools: tools, folder: folder) : ExternalChatBackend(agent: self, tools: tools, folder: folder)
    }

    /// ACP（Agent Client Protocol）で話せるエージェント：`agy`（`agy acp`）・`opencode`（`opencode acp`）。`pi` は、独自の RPC（`--mode rpc`）・`codex` は、独自の `app-server`・`claude`・`grok` は、ACP を持たない。
    /// **段階の強制は、こちらの許可の返事で行う**（`ACPPermission`）：`opencode` は、何もしなければ、書き込みも、確認なしで行うので、起動のとき、全部を「聞く」設定にして、渡す（`ACPChatBackend.liveEnvironment`）。
    public var speaksACP: Bool { self == .agy || self == .opencode }

    /// Web 検索を、使えるエージェントか（`pi` は、検索の道具を持たない。Apple は、こちらが道具を渡す）。
    public var canSearchWeb: Bool { self != .pi }

    /// 実行中の様子（いま何をしているか）を、読み取れるエージェントか。
    public var streamsActivity: Bool { isExternal }

    /// このエージェントで、実際に使う段階（`pi` は、検索がないので、「Web」は、「なし」になる）。
    public func effective(_ tools: ChatToolLevel) -> ChatToolLevel { tools == .web && !canSearchWeb ? .none : tools }
}
