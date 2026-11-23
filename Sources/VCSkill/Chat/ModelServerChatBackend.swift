import Foundation
import VCCore

/// 会話の答える側：設定 > モデル の、Ollama・OpenAI 互換のサーバー（`ChatModel`）。**道具なしの、単純な会話**（SPEC F75）。
/// 場所・APIキー・同じ LAN の許可は、スキルを実行するモデルと同じ（`Engine`）。文脈は、`ChatConversation` が持ち（要約・長さの決まり）、ここは、1 回分を、サーバーの形にして送るだけ。
struct ModelServerChatBackend: ChatBackend {
    let chat: any ChatModel

    func respond(instructions: String, turns: [ChatTurn], user: String) async throws -> String {
        let reply: ChatMessage
        do { reply = try await chat.chat(Self.messages(instructions: instructions, turns: turns, user: user), tools: false) }
        catch let error as ChatError { throw ConversationError.failed("\(error)") }
        let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConversationError.failed(tr("答えが空でした")) }
        return text
    }

    /// 指示・過去の往復・いまの発言を、メッセージの並びにする（**純粋**）。
    static func messages(instructions: String, turns: [ChatTurn], user: String) -> [ChatMessage] {
        var messages = [ChatMessage(role: .system, content: instructions)]
        for turn in turns {
            messages.append(ChatMessage(role: .user, content: turn.user))
            messages.append(ChatMessage(role: .assistant, content: turn.assistant))
        }
        messages.append(ChatMessage(role: .user, content: user))
        return messages
    }
}
