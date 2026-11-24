import Foundation
import VCCore

/// 会話の答える側：設定 > モデル の、Ollama・OpenAI 互換のサーバー（`ChatModel`）。**道具なしの、単純な会話**（SPEC F75）。
/// 場所・APIキー・同じ LAN の許可は、スキルを実行するモデルと同じ（`Engine`）。文脈は、`ChatConversation` が持ち（要約・長さの決まり）、ここは、1 回分を、サーバーの形にして送るだけ。
/// 画像（`options.image`）は、**いまの発言だけに付けて**、モデルへ渡す（画像に対応したモデルだけが、読める）。過去の往復には、付けない（文脈を埋めないため）。
struct ModelServerChatBackend: ChatBackend, ActivityReporting {
    let chat: any ChatModel

    func respond(instructions: String, turns: [ChatTurn], user: String) async throws -> String {
        try await respond(instructions: instructions, turns: turns, user: user, options: ChatCallOptions())
    }

    func respond(instructions: String, turns: [ChatTurn], user: String, options: ChatCallOptions) async throws -> String {
        var messages = Self.messages(instructions: instructions, turns: turns, user: user)
        if let image = options.image {
            do { messages[messages.count - 1].images = [try ImageOps.downscaledPNG(image, maxSide: VisionModel.maxSide).base64EncodedString()] }
            catch { throw ConversationError.failed(tr("画像を読めません（\(error)）")) }
        }
        let reply: ChatMessage
        do { reply = try await chat.chat(messages, tools: false) }
        catch let error as ChatError {
            // 画像つきで、サーバーが断ったら、モデルが画像に対応していないことが多い：言う
            let hint = options.image != nil ? tr("（画像を付けました。このモデルが、画像に対応しているか、確かめてください）") : ""
            throw ConversationError.failed("\(error)" + hint)
        }
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
