import Foundation
import VCCore

/// 会話の答えを作る側（Apple のオンデバイスのモデル：`AppleChatBackend`・外のエージェント：常駐の接続の `ACPChatBackend`・CLI の `ExternalChatBackend`）。**毎回、指示と過去の往復から、会話を組み立てる**（状態を持たない：要約で、過去を差し替えやすい）。
public protocol ChatBackend: Sendable {
    /// `instructions`：指示（要約を含む）。`turns`：過去の往復。`user`：いまの発言。答えの文字。
    func respond(instructions: String, turns: [ChatTurn], user: String) async throws -> String
    /// この答える側に合う、会話の長さの決まり（文脈の大きさで違う）。
    var budget: ChatBudget { get }
    /// この答える側が、できないこと・できることの、指示（Web を見られるか）。会話の指示に、足される。
    var capabilityNote: String { get }
}

extension ChatBackend {
    public var budget: ChatBudget { .standard }
    public var capabilityNote: String { ChatToolLevel.none.note }
}

public enum ConversationError: Error, CustomStringConvertible, Equatable {
    /// モデルの文脈（8,192 トークン）を超えた。
    case contextOverflow
    case unavailable(String)
    case failed(String)
    public var description: String {
        switch self {
        case .contextOverflow: return tr("会話が長すぎて、モデルの文脈に入りません")
        case let .unavailable(reason): return reason
        case let .failed(message): return tr("答えを作れませんでした（\(message)）")
        }
    }
}

