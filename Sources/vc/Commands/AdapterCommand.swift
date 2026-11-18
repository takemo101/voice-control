import Foundation
import VCCore
import VCSkill

struct AdapterCommand: Command {
    static let info = CommandInfo(
        name: "adapter", group: .skills, summary: "会話のエージェント（claude・codex）を、ACP で話すための、アダプターを、入れる・消す・調べる",
        usage: ["vc adapter status [<エージェント>]", "vc adapter install <エージェント>", "vc adapter remove <エージェント>"],
        details: [
            "`claude`・`codex` の CLI は、ACP を話さないので、**アダプター**（npm のパッケージ：`@agentclientprotocol/claude-agent-acp`・`@agentclientprotocol/codex-acp`。Apache-2.0）が要る。**入れるのは、このコマンド（または、設定ウィンドウ > 会話）を実行したときだけ**。",
            "入れる先は `~/.voice-control/adapters/<エージェント>/`。**版は固定**（アプリに同梱の `package-lock.json` どおり：取得先は npm の公式のレジストリだけ・すべての部品に SHA-512 の整合値）。`npm ci --ignore-scripts --omit=optional` で入れる（インストール時のスクリプトは動かさない。CLI 本体は取り込まず、**あなたの CLI を使う**）。Node.js（npm）が要る。",
            "自分で入れたもの（`npm i -g …`）が、すでにあれば、そちらを使う。入れ替えの途中で失敗しても、前のものは残る。",
        ],
        options: [],
        examples: ["vc adapter status", "vc adapter install claude", "vc adapter remove codex"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let words = arguments.positionals
        guard let action = words.first, ["status", "install", "remove"].contains(action) else { usageError("adapter", "status・install・remove のどれかを指定してください") }
        let adapters: [ACPAdapter]
        if let name = words.dropFirst().first {
            guard let agent = ChatAgent.parse(name), let adapter = ACPAdapter.of(agent) else { usageError("adapter", "「\(name)」には、アダプターは要りません（claude・codex だけ。agy・opencode は、本体が ACP を話します）") }
            adapters = [adapter]
        } else {
            guard action == "status" else { usageError("adapter", "\(action) には、エージェント（claude・codex）を指定してください") }
            adapters = [.of(.claude), .of(.codex)].compactMap { $0 }
        }
        for adapter in adapters {
            switch action {
            case "status":
                let status = AdapterStatus.of(adapter)
                print("\(adapter.agent.rawValue)：\(status.summary(for: adapter))  [\(adapter.package)@\(adapter.version)]")
            case "install":
                guard let source = AdapterSource.directory(for: adapter) else { fail("同梱の固定ファイル（adapters/\(adapter.directoryName)）が、見つかりません") }
                print("\(adapter.package)@\(adapter.version) を入れます（約 \(adapter.approximateSizeMB) MB・\(adapter.license)。\(ACPAdapterStore.directory(for: adapter).path)）…")
                do { try await ACPAdapterInstaller.install(adapter, source: source) } catch { fail("\(error)") }
                print("✓ 入れました（\(adapter.package)@\(adapter.version)）")
            default:
                do { try ACPAdapterInstaller.remove(adapter) } catch { fail("\(error)") }
                print("✓ 消しました（\(ACPAdapterStore.directory(for: adapter).path)）。自分で入れたものは、触っていません")
            }
        }
    }
}
