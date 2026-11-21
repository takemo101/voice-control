import Foundation
import VCCore

/// ACP のエージェントが選べる、モデル 1 つ。
public struct ACPModelChoice: Equatable, Sendable, Identifiable {
    /// 指示に使う値（`session/set_model` の `modelId`、または設定の選択肢の値）。
    public let id: String
    /// 表示名（なければ、値）。
    public let name: String
    /// 説明（あれば）。
    public let detail: String?

    public init(id: String, name: String? = nil, detail: String? = nil) {
        self.id = id
        self.name = (name?.isEmpty == false ? name : nil) ?? id
        self.detail = detail?.isEmpty == false ? detail : nil
    }
}

/// エージェントが返した、モデルの一覧と、いまのモデル。
public struct ACPModelListing: Equatable, Sendable {
    public let choices: [ACPModelChoice]
    /// いま選ばれているモデル（エージェントの設定）。
    public let current: String?

    public init(choices: [ACPModelChoice], current: String?) { self.choices = choices; self.current = current }
}

/// セッションを作る応答（`session/new`）から、モデルの一覧を読み、選ぶための要求を作る（**純粋**）。**一覧は、エージェント自身が返す**（こちらは、モデルの名前を、持たない）：
/// - `models.availableModels`（`modelId`・`name`・`description`）と `models.currentModelId` → 選ぶのは `session/set_model`。
/// - なければ、設定の選択肢（`configOptions`）のうち、種類（`category`）か番号（`id`）が `model` のもの（`currentValue`・`options`：平らな一覧か、`group` ごとの一覧）→ 選ぶのは `session/set_config_option`。
/// エージェントが返した文字は、非信頼：画面に出すだけ（命令として、実行しない）。
enum ACPModels {
    struct Parsed: Equatable {
        let listing: ACPModelListing
        /// 設定の選択肢で選ぶときの、選択肢の番号（`session/set_model` で選ぶときは、nil）。
        let configID: String?
    }

    static func parse(_ created: JSONValue) -> Parsed {
        if let available = created["models"]?["availableModels"]?.array, !available.isEmpty {
            let choices = available.compactMap { item -> ACPModelChoice? in
                guard let id = item["modelId"]?.string, !id.isEmpty else { return nil }
                return ACPModelChoice(id: id, name: item["name"]?.string, detail: item["description"]?.string)
            }
            if !choices.isEmpty { return Parsed(listing: ACPModelListing(choices: choices, current: created["models"]?["currentModelId"]?.string), configID: nil) }
        }
        if let option = created["configOptions"]?.array?.first(where: { $0["category"]?.string == "model" || $0["id"]?.string == "model" }), let configID = option["id"]?.string {
            let choices = flatten(option["options"]?.array ?? [])
            if !choices.isEmpty { return Parsed(listing: ACPModelListing(choices: choices, current: option["currentValue"]?.string), configID: configID) }
        }
        return Parsed(listing: ACPModelListing(choices: [], current: nil), configID: nil)
    }

    /// 選択肢の一覧（平ら、または `group` ごと）を、1 つの一覧にする。
    private static func flatten(_ items: [JSONValue]) -> [ACPModelChoice] {
        items.flatMap { item -> [ACPModelChoice] in
            if let nested = item["options"]?.array { return flatten(nested) }
            guard let value = item["value"]?.string, !value.isEmpty else { return [] }
            return [ACPModelChoice(id: value, name: item["name"]?.string, detail: item["description"]?.string)]
        }
    }

    /// 選ぶための要求（メソッドと引数）。**一覧にないモデルは、選ばない**（nil）：古い設定・知らない値を、エージェントへ渡さない。
    static func request(for modelID: String, parsed: Parsed, sessionID: String) -> (method: String, params: JSONValue)? {
        guard parsed.listing.choices.contains(where: { $0.id == modelID }) else { return nil }
        if let configID = parsed.configID {
            return ("session/set_config_option", .object(["sessionId": .string(sessionID), "configId": .string(configID), "value": .string(modelID)]))
        }
        return ("session/set_model", .object(["sessionId": .string(sessionID), "modelId": .string(modelID)]))
    }
}

/// モデルの一覧を取れなかった理由。
public struct ACPModelError: Error, CustomStringConvertible {
    public let description: String
}

/// エージェントを、**一時的に起動して**、選べるモデルの一覧を取る（設定ウィンドウの「モデル」・`vc chat-models`）。**質問は送らない**（初期化とセッションの作成だけ：モデルは、呼ばれない）。
/// 起動は、会話と同じ（OS の制限つき・アダプターの場所の探し方）。終わったら、すぐ閉じる。
public enum ACPModelCatalog {
    public static func list(for agent: ChatAgent, sandbox: Bool = true) async throws -> ACPModelListing {
        guard let profile = ACPAgentProfile.of(agent) else { throw ACPModelError(description: "\(agent.rawValue) は、ACP で話せません") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vc-models-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var argv = profile.launch(level: .none)
        if sandbox, ACPSandbox.applies(to: agent) { argv = ACPSandbox.wrap(argv, agent: agent, level: .none, folder: scratch) }
        let connection = ACPConnection(argv: argv, directory: scratch, environment: profile.launchEnvironment(), dialect: profile.makeDialect())
        do { try connection.start() } catch { throw ACPModelError(description: "\(error)（アダプター・CLI が入っているか、確かめてください）") }
        defer { connection.close() }
        do {
            _ = try await connection.request("initialize", .object([
                "protocolVersion": .number(1), "clientCapabilities": .object([:]),
                "clientInfo": ACPConnection.clientInfo]), timeout: 20)
            let created = try await connection.request("session/new", .object(["cwd": .string(scratch.path), "mcpServers": .array([])]), timeout: 30)
            let parsed = ACPModels.parse(created)
            guard !parsed.listing.choices.isEmpty else { throw ACPModelError(description: "\(agent.rawValue) は、モデルの一覧を返しませんでした") }
            return parsed.listing
        } catch let error as ACPModelError {
            throw error
        } catch {
            throw ACPModelError(description: "\(error)")
        }
    }
}
