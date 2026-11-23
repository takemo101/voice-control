import Foundation
import VCCore

/// モデルのサーバー（Ollama・OpenAI 互換）が、**いま持っているモデルの一覧**を取る（設定ウィンドウ > モデル の「一覧」）。**質問は送らない**（一覧の取得だけ：話した内容・画面の内容は、出ない）。
/// 場所・経路・APIキーは、エンジンと同じ（`ServerAddress`・`ModelServerKind`）。
public enum ModelServerCatalog {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func list(kind: ModelServerKind, server address: ServerAddress, keys: EngineKeyStore = .standard) async throws -> [String] {
        do {
            let names = usable(try await kind.listModelNames(on: kind.server(at: address, keys: keys)))
            guard !names.isEmpty else { throw ChatError.badResponse(tr("モデルの一覧が、空です")) }
            return names
        } catch { throw Failure(description: "\(error)") }
    }

    /// 応答から、画面に出すモデルの名前（**純粋**）。読めなければ、空。
    static func parse(kind: ModelServerKind, data: Data) -> [String] { usable(kind.modelNames(in: data) ?? []) }

    /// サーバーが返した文字は、非信頼：エンジンの書き方（`Engine.isUsableModelName`）で通る名前だけ残す。重複を除き、名前順。
    private static func usable(_ names: [String]) -> [String] { Array(Set(names.filter(Engine.isUsableModelName))).sorted() }
}
