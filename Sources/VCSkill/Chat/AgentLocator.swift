import Foundation

/// 会話に使う外のエージェントの CLI（`agy`・`claude`・`codex`・`grok`・`opencode`・`pi`）が、**この Mac に入っているか**を調べる。入っていないものは、設定の選択肢に出さない。
/// アプリは、Finder などから起動すると、シェルの `PATH`（`~/.local/bin`・`~/.bun/bin` など）を、受け取らない。そこで、`PATH` に加えて、**よくある置き場所**も探す（探すだけ。実行するのは、設定で選んだものだけ）。
public enum AgentLocator {
    /// `PATH` の次に探す、よくある置き場所（ホームからの相対と、決まった場所）。
    static func commonDirectories(home: String) -> [String] {
        ["\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/.deno/bin",
         "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
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

    /// 使えるか（Apple は、いつも使える。外のエージェントは、CLI が入っていれば）。
    public static func isAvailable(_ agent: ChatAgent, directories: [String] = searchDirectories(), isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        agent == .apple || executablePath(for: agent, directories: directories, isExecutable: isExecutable) != nil
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
