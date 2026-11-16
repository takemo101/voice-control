import Foundation

/// ACP で話せるエージェント 1 つの、**エージェントごとの違い**（起動・環境・自身の置き場・モデルの選び方）を、**1 か所**に集める（`ACPChatBackend`・`ACPSandbox`・`ChatAgent.speaksACP` が、それぞれ、エージェント名で、場合分けしていた）。
/// エージェントを足すときは、ここに 1 つ足す（許可の挙動は、エージェントごとに、実測してから：`opencode`・`grok` は、既定で、聞かなかった）。
struct ACPAgentProfile {
    let agent: ChatAgent
    /// 起動の引数（実行ファイル名のあと）。
    let arguments: [String]
    /// 「すべて」でないとき、足す引数（端末の制限：agy の `--sandbox`）。
    let restrictedArguments: [String]
    /// 起動に足す環境変数。
    let environment: [String: String]
    /// エージェント自身が、書く場所（ホームからの相対。会話・認証・設定・キャッシュ）。OS の制限（`ACPSandbox`）で、書き込みを許す。
    let stateDirectories: [String]
    /// 設定（`ASK_AGENT_AGY_MODEL`・既定）のモデルを、`session/set_model` で選ぶか。
    let choosesModel: Bool

    /// ACP で話せるエージェントの、違い。話せなければ nil。
    static func of(_ agent: ChatAgent) -> ACPAgentProfile? {
        switch agent {
        case .agy:
            return ACPAgentProfile(agent: .agy, arguments: ["acp"], restrictedArguments: ["--sandbox"], environment: [:], stateDirectories: [".gemini"], choosesModel: true)
        case .opencode:
            // **何もしないと、書き込み・コマンドを、確認なしで行う**（実測：build でも plan でも、`session/request_permission` が来ない）ので、**全部を「聞く」設定**にして渡す。
            // 利用者の設定（`~/.config/opencode`）・作業フォルダの `opencode.json` が、「許可」でも、この設定が、優先された（実測）。
            return ACPAgentProfile(agent: .opencode, arguments: ["acp"], restrictedArguments: [], environment: ["OPENCODE_CONFIG_CONTENT": #"{"permission":{"*":"ask"}}"#],
                                   stateDirectories: [".local/share/opencode", ".local/state/opencode", ".cache/opencode", ".config/opencode", ".opencode"], choosesModel: false)
        default:
            return nil
        }
    }

    /// 起動の引数（実行ファイル名から）。
    func launch(level: ChatToolLevel) -> [String] {
        [agent.rawValue] + arguments + (level == .all ? [] : restrictedArguments)
    }
}
