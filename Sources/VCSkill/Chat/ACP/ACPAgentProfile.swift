import Foundation

/// ACP で話せるエージェント 1 つの、**エージェントごとの違い**（起動・環境・自身の置き場・モード・モデルの選び方）を、**1 か所**に集める（`ACPChatBackend`・`ACPSandbox` が使う）。
/// エージェントを足すときは、ここに 1 つ足す（許可の挙動は、エージェントごとに、**実測してから**：`opencode`・`grok` は、既定で、聞かなかった。`claude`・`codex` は、モードによる）。
struct ACPAgentProfile {
    let agent: ChatAgent
    /// 起動する実行ファイルの名前。CLI 本体が ACP を話すもの（`agy`・`opencode`）は、CLI の名前。**アダプター**（`claude`・`codex`：CLI を ACP に変える、別のプログラム）は、その名前。
    /// アダプターは、**利用者が自分で入れたものだけ**を使う（`PATH` と、よくある置き場所から探す。`npx` で、自動に取りに行かない：知らない第三者のコードを、確認なしで動かさない）。なければ、従来の方式へ戻る。
    let executable: String
    /// 起動の引数（実行ファイル名のあと）。
    let arguments: [String]
    /// 「すべて」でないとき、足す引数（端末の制限：agy の `--sandbox`）。
    let restrictedArguments: [String]
    /// 起動に足す環境変数。
    let environment: [String: String]
    /// エージェント自身が、書く場所（ホームからの相対。会話・認証・設定・キャッシュ）。OS の制限（`ACPSandbox`）で、書き込みを許す。
    let stateDirectories: [String]
    /// 同じく、書く**絶対の場所で、名前の頭が決まっているもの**（一時の場所：Claude の Bash の道具は、`/private/tmp/claude-…` に、作業の目印を書く）。頭が一致する場所を、すべて許す。
    let statePrefixes: [String]
    /// 同じく、書く**ファイル**（ホームからの相対。名前の頭が同じ一時・ロック・退避のファイルも含む：`.claude.json`）。
    let stateFiles: [String]
    /// 設定（`ASK_AGENT_AGY_MODEL`・既定）のモデルを、`session/set_model` で選ぶか。
    let choosesModel: Bool
    /// 「すべて」のときの、モード（上から、使えるものを選ぶ）：**書き込み・コマンドの前に、聞いてくる**もの。
    let askingModes: [String]
    /// 「すべて」でないときの、モード（上から）：読むだけ。
    let readingModes: [String]
    /// モードが決められなかったとき、ACP で話さない（従来の方式へ戻る）か。**決められないと、確認なしで操作するモードのまま**になるもの（`claude` は、初期が `auto`）。
    let requiresMode: Bool
    /// セッションを作るときに渡す、追加の設定（`session/new` の `_meta`）。`grok`：`yoloMode: false`（**利用者の設定が、確認なしでも、このアプリの会話は、聞いてもらう**：実測）。
    var sessionMeta: JSONValue?
    /// 「なし（会話だけ）」の段階で、Web 検索を、**止められるか**。許可の要求で止めるエージェントは、止められる。`grok` は、Web 検索を、許可の要求なしで行う（実測）ので、「なし」は、従来の CLI（`--disable-web-search`）で話す。
    var canDisableWebSearch = true
    /// 相手と話す言葉。ACP を話すものは、そのまま。`piRPC`：pi の RPC モード（行ごとの JSON）を、`PiRPCDialect` で、ACP に訳す。
    var wire: Wire = .acp
    /// 段階ごとに、足す引数（pi：道具の許可リスト `--tools`・確認の拡張 `-e`）。なければ、`restrictedArguments` だけ。
    var levelArguments: (@Sendable (ChatToolLevel) -> [String])?

    enum Wire { case acp, piRPC }

    /// 接続に付ける、訳し役（ACP を話すものは、なし）。
    func makeDialect() -> ACPWireDialect? { wire == .piRPC ? PiRPCDialect() : nil }

    /// ACP で話せるエージェントの、違い。話せなければ nil。
    static func of(_ agent: ChatAgent) -> ACPAgentProfile? {
        switch agent {
        case .agy:
            return ACPAgentProfile(agent: .agy, executable: "agy", arguments: ["acp"], restrictedArguments: ["--sandbox"], environment: [:], stateDirectories: [".gemini"], statePrefixes: [], stateFiles: [],
                                   choosesModel: true, askingModes: ["default"], readingModes: ["plan"], requiresMode: false)
        case .opencode:
            // **何もしないと、書き込み・コマンドを、確認なしで行う**（実測：build でも plan でも、`session/request_permission` が来ない）ので、**全部を「聞く」にする設定**を、起動のときに、環境変数で渡す。
            // 利用者の設定（`~/.config/opencode`）・作業フォルダの `opencode.json` が、「許可」でも、この設定が、優先された（実測）。
            return ACPAgentProfile(agent: .opencode, executable: "opencode", arguments: ["acp"], restrictedArguments: [], environment: ["OPENCODE_CONFIG_CONTENT": #"{"permission":{"*":"ask"}}"#],
                                   stateDirectories: [".local/share/opencode", ".local/state/opencode", ".cache/opencode", ".config/opencode", ".opencode"], statePrefixes: [], stateFiles: [],
                                   choosesModel: false, askingModes: ["build"], readingModes: ["plan"], requiresMode: false)
        case .claude:
            // アダプター `@agentclientprotocol/claude-agent-acp`（Apache-2.0。Claude Agent SDK）。**初期のモードは `auto`（実測：確認なしで、書き込み・コマンドを行う）**：`default`（実測：書き込みの前に、聞いてくる）に替える。替えられなければ、使わない。
            return ACPAgentProfile(agent: .claude, executable: "claude-agent-acp", arguments: [], restrictedArguments: [], environment: [:],
                                   stateDirectories: [".claude", ".config/claude", ".cache/claude", "Library/Caches/claude-cli-nodejs"], statePrefixes: ["/private/tmp/claude-"], stateFiles: [".claude.json"],   // Bash の道具が、シェルの作業に使う一時の場所（実測：書けないと、`ls` も動かない）
                                   choosesModel: false, askingModes: ["default"], readingModes: ["plan"], requiresMode: true)
        case .codex:
            // アダプター `@agentclientprotocol/codex-acp`（Apache-2.0。`codex` を包む）。モードは、**`read-only` だけが、書き込み・コマンドの前に、聞いてくる**（実測：`agent`・`workspace-write` は、作業フォルダの中を、聞かずに書く）。
            // 「読む」までの段階も、`read-only`（書き込みの要求は、こちらが断る）。
            return ACPAgentProfile(agent: .codex, executable: "codex-acp", arguments: [], restrictedArguments: [], environment: [:],
                                   stateDirectories: [".codex"], statePrefixes: [], stateFiles: [],
                                   choosesModel: false, askingModes: ["read-only"], readingModes: ["read-only"], requiresMode: true)
        case .grok:
            // 本体が ACP を話す（`grok agent stdio`。アダプター不要）。`--no-leader`：共有の常駐プロセスに、つなげない（作業フォルダ・OS の制限が、効かなくなる）。
            // **許可**：`modes` がなく、利用者の設定（`permission_mode = "always-approve"`）が、そのまま効く（実測：書き込み・コマンドが、聞かずに実行された）。`session/new` の `_meta.yoloMode: false` で、**聞いてくる**ようになる（実測：書き込みの許可の要求が来て、断れば、ファイルは作られない）。
            // 読む・Web 検索は、聞かずに実行される（実測）：段階の「なし」は、Web 検索を止められないので、従来の CLI で話す。書き込み・コマンドは、聞いてくる（こちらが決める）＋ OS の制限。
            return ACPAgentProfile(agent: .grok, executable: "grok", arguments: ["agent", "--no-leader", "stdio"], restrictedArguments: [], environment: [:],
                                   stateDirectories: [".grok"], statePrefixes: [], stateFiles: [],
                                   choosesModel: false, askingModes: [], readingModes: [], requiresMode: false,
                                   sessionMeta: .object(["yoloMode": .bool(false)]), canDisableWebSearch: false)
        case .pi:
            // 本体の RPC モード（`pi --mode rpc`）を、こちらが ACP に訳す（`PiRPCDialect`）。**第三者のアダプター（`pi-acp`）は使わない**。pi には、許可の要求の仕組みがないので、
            // **こちらが書く拡張（`PiGateExtension`）が、読む組み込み以外の、すべての道具の前に、確認を求める**（利用者の拡張・MCP が足した道具も）：ACP のエージェントと同じく、利用者の拡張・MCP・スキル・文脈ファイルは、そのまま使う。判断は、`ACPPermission`（段階で、断る・確認）。
            // 段階は、さらに、起動の引数で、組み込みの道具そのものを無くす（なし・Web＝道具なし／読む＝read・grep・find・ls）。`--no-approve`：フォルダの `.pi`（拡張・設定）は、読まない（信頼していない実行コードを、動かさない）。
            return ACPAgentProfile(agent: .pi, executable: "pi", arguments: ["--mode", "rpc", "--no-session", "--no-themes", "--no-approve"],
                                   restrictedArguments: [], environment: [:], stateDirectories: [".pi"], statePrefixes: [], stateFiles: [],
                                   choosesModel: false, askingModes: [], readingModes: [], requiresMode: false,
                                   sessionMeta: nil, canDisableWebSearch: true, wire: .piRPC,
                                   levelArguments: { level in
                                       // 確認の拡張は、いつも読む。置けなければ、確認できない：利用者の拡張・MCP を止めて、組み込みの読む道具だけにする
                                       guard let gate = PiGateExtension.install() else { return ["--no-extensions", "--no-mcp", "--tools", "read,grep,find,ls"] }
                                       switch level {
                                       case .none, .web: return ["-e", gate, "--no-tools"]
                                       case .read: return ["-e", gate, "--tools", "read,grep,find,ls"]
                                       case .all: return ["-e", gate]
                                       }
                                   })
        default:
            return nil
        }
    }

    /// 起動の引数（実行ファイル名から）。
    func launch(level: ChatToolLevel) -> [String] {
        // アダプターは、見つかった場所の、絶対のパスで起動する（利用者が入れたもの → アプリが入れたもの）。見つからなければ、名前のまま（起動に失敗して、従来の方式へ戻る）
        [AgentLocator.acpExecutablePath(for: agent) ?? executable] + arguments + (level == .all ? [] : restrictedArguments) + (levelArguments?(level) ?? [])
    }

    /// 起動に渡す環境変数：探す場所（`PATH`）・エージェントごとの設定・**利用者の CLI 本体の場所**（アダプターが、本体を、二重に取り込まない）。
    func launchEnvironment() -> [String: String] {
        ["PATH": AgentLocator.childPATH()].merging(AgentLocator.cliEnvironment(for: agent)) { _, new in new }.merging(environment) { _, new in new }
    }

    /// その段階で、決めたい、モード（上から）。
    func wantedModes(level: ChatToolLevel) -> [String] { level == .all ? askingModes : readingModes }
}
