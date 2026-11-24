import Foundation

/// 会話に使う外のエージェントの CLI（`agy`・`claude`・`codex`・`grok`・`opencode`・`pi`）が、**この Mac に入っているか**を調べる。入っていないものは、設定の選択肢に出さない。
/// アプリは、Finder などから起動すると、シェルの `PATH`（`~/.local/bin`・`~/.bun/bin` など）を、受け取らない。そこで、`PATH` に加えて、**よくある置き場所**も探す（探すだけ。実行するのは、設定で選んだものだけ）。
public enum AgentLocator {
    /// `PATH` の次に探す、よくある置き場所（ホームからの相対と、決まった場所）。
    static func commonDirectories(home: String) -> [String] {
        ["\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/.deno/bin",
         "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + nodeVersionDirectories(home: home)
    }

    /// `nvm` の、入っている Node の `bin`（新しい版から）。`npm i -g` で入れた ACP アダプター（`#!/usr/bin/env node`）は、ここに置かれ、動かすのにも、ここの `node` が要る。なければ、空。
    static func nodeVersionDirectories(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return versions.map { "\(root)/\($0)/bin" }
    }

    /// 探す場所（`PATH` の順に、よくある置き場所。重複は、除く）。
    public static func searchDirectories(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> [String] {
        var seen = Set<String>()
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (fromPath + commonDirectories(home: home)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// エージェントの実行ファイルの、絶対パス（なければ nil）。Apple のモデルは、CLI がない（nil）。
    public static func executablePath(for agent: ChatAgent, directories: [String] = searchDirectories(), isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        guard agent.isExternal else { return nil }
        return directories.map { "\($0)/\(agent.rawValue)" }.first(where: isExecutable)
    }

    /// ACP で話すための、**アダプター**（`claude-agent-acp`・`codex-acp`）の、絶対パス（なければ nil。CLI 本体が ACP を話すもの〔`agy`・`opencode`〕は、CLI 本体）。
    /// **利用者が自分で入れたもの（`PATH`・よくある置き場所・`nvm`）を先に**、なければ、アプリが入れたもの（`~/.voice-control/adapters`）。
    public static func acpExecutablePath(for agent: ChatAgent, directories: [String] = searchDirectories(), managedRoot: URL = ACPAdapterStore.root, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        guard let name = ACPAgentProfile.of(agent)?.executable else { return nil }
        let own = directories.map { "\($0)/\(name)" }.first(where: isExecutable)
        if let own { return own }
        guard let adapter = ACPAdapter.of(agent) else { return nil }
        let managed = ACPAdapterStore.binDirectory(for: adapter, root: managedRoot) + "/" + name
        return isExecutable(managed) ? managed : nil
    }

    /// アダプターが、**利用者の CLI 本体**を使うための環境変数（`CLAUDE_CODE_EXECUTABLE`・`CODEX_PATH`。本体を、二重に取り込まない）。CLI が見つからなければ、空。
    public static func cliEnvironment(for agent: ChatAgent, directories: [String] = searchDirectories(), isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [String: String] {
        guard let adapter = ACPAdapter.of(agent), let cli = executablePath(for: agent, directories: directories, isExecutable: isExecutable) else { return [:] }
        return [adapter.cliEnvironmentKey: cli]
    }

    /// 使えるか（Apple・サーバーは、いつも選べる〔サーバーは、行き先の有無を `ChatAgent.canAnswer` が見る〕。外のエージェントは、CLI が入っていれば）。
    public static func isAvailable(_ agent: ChatAgent, directories: [String] = searchDirectories(), isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        agent == .apple || agent == .server || executablePath(for: agent, directories: directories, isExecutable: isExecutable) != nil
    }

    /// 選択肢に出す、使えるエージェント（Apple を先頭に）。
    public static func available(directories: [String] = searchDirectories(), isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [ChatAgent] {
        ChatAgent.allCases.filter { isAvailable($0, directories: directories, isExecutable: isExecutable) }
    }

    /// 子プロセスに渡す `PATH`（探す場所を、すべて含める：`#!/usr/bin/env node` のような CLI が、`node` を見つけられるように）。
    public static func childPATH(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String {
        searchDirectories(environment: environment, home: home).joined(separator: ":")
    }
}
