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
        case .apple: return tr("Apple のモデル（この Mac の中）")
        case .agy: return tr("Antigravity（agy。Google）")
        case .claude: return tr("Claude Code（claude。Anthropic）")
        case .codex: return tr("Codex（codex。OpenAI）")
        case .grok: return tr("Grok（grok。xAI）")
        case .opencode: return tr("OpenCode（opencode。設定したモデルの提供元）")
        case .pi: return tr("pi（pi。設定したモデルの提供元）")
        }
    }

    /// 声・文字での呼び名も受ける（`ask-agent` と同じ）。
    public static func parse(_ text: String) -> ChatAgent? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        let aliases: [String: ChatAgent] = [
            "apple": .apple, "fm": .apple, "アップル": .apple,   // l10n-skip：照合に使う語・名前（画面に出ない）
            "agy": .agy, "antigravity": .agy, "アンチグラビティ": .agy,   // l10n-skip：照合に使う語・名前（画面に出ない）
            "claude": .claude, "クロード": .claude,   // l10n-skip：照合に使う語・名前（画面に出ない）
            "codex": .codex, "コーデックス": .codex,   // l10n-skip：照合に使う語・名前（画面に出ない）
            "grok": .grok, "グロック": .grok,   // l10n-skip：照合に使う語・名前（画面に出ない）
            "opencode": .opencode, "open code": .opencode, "オープンコード": .opencode,   // l10n-skip：照合に使う語・名前（画面に出ない）
            "pi": .pi, "パイ": .pi,   // l10n-skip：照合に使う語・名前（画面に出ない）
        ]
        return aliases[key]
    }

    /// このエージェントの、会話の長さの決まり。Apple は 8,192 トークンなので小さく、外のエージェントは、大きな文脈を持つので、大きくする（毎回、全部を送るので、大きすぎると、遅く・高くなる）。
    public var budget: ChatBudget {
        isExternal ? ChatBudget(trigger: 24_000, keepRecent: 8_000, summaryMaxCharacters: 1500, notesMaxCharacters: 1500) : .standard
    }

    /// 答える側。`tools`・`folder`：外のエージェントに開ける道具の段階と、作業フォルダ（Apple には、効かない）。
    /// `acp`：ACP に対応したエージェント（`speaksACP`）は、常駐の ACP で話す（使えなければ、従来の方式へ戻る）。`sandbox`：その起動を、OS の制限（Seatbelt）つきにする（`ACPSandbox`）。
    public func makeBackend(tools: ChatToolLevel = .none, folder: URL? = nil, acp: Bool = true, sandbox: Bool = true, model: String? = nil, auto: Bool = false) -> ChatBackend {
        guard isExternal else { return AppleChatBackend(tools: tools, folder: folder) }
        return talksACP(enabled: acp) ? ACPChatBackend(agent: self, tools: tools, folder: folder, sandbox: sandbox, model: model, auto: auto) : ExternalChatBackend(agent: self, tools: tools, folder: folder)
    }

    /// ACP（Agent Client Protocol）で話せるエージェント：`agy`（`agy acp`）・`opencode`（`opencode acp`）は、CLI 自身が。`claude`・`codex` は、利用者が入れたアダプター（`ACPAdapter`）を通して。`pi`・`grok` は、ACP を話さない（従来の方式）。
    /// **段階の強制は、こちらの許可の返事で行う**（`ACPPermission`）：`opencode` は、何もしなければ、書き込みも、確認なしで行うので、起動のとき、全部を「聞く」設定にして、渡す（`ACPAgentProfile.launchEnvironment`）。
    public var speaksACP: Bool { ACPAgentProfile.of(self) != nil }

    /// 常駐の接続（ACP）で話すか（設定 `chatAcp` が有効で、ACP を話せるエージェント）。話すときは、操作の前に、エージェントが聞いてくる（`ACPPermission`）：設定画面の説明・確認のダイアログが、これで分ける。
    public func talksACP(enabled acp: Bool) -> Bool { acp && speaksACP }

    /// Web 検索を、使えるエージェントか（`pi` は、検索の道具を持たない。Apple は、こちらが道具を渡す）。
    public var canSearchWeb: Bool { self != .pi }

    /// 実行中の様子（いま何をしているか）を、読み取れるエージェントか。
    public var streamsActivity: Bool { isExternal }

    /// このエージェントで、実際に使う段階（`pi` は、検索がないので、「Web」は、「なし」になる）。
    public func effective(_ tools: ChatToolLevel) -> ChatToolLevel { tools == .web && !canSearchWeb ? .none : tools }
}
