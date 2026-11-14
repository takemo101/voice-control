import Foundation
import FoundationModels

/// 会話の答えを作る側（Apple のオンデバイスのモデル）。**毎回、指示と過去の往復から、会話を組み立てる**（状態を持たない：要約で、過去を差し替えやすい）。
public protocol ChatBackend: Sendable {
    /// `instructions`：指示（要約を含む）。`turns`：過去の往復。`user`：いまの発言。答えの文字。
    func respond(instructions: String, turns: [ChatTurn], user: String) async throws -> String
}

public enum ConversationError: Error, CustomStringConvertible, Equatable {
    /// モデルの文脈（8,192 トークン）を超えた。
    case contextOverflow
    case unavailable(String)
    case failed(String)
    public var description: String {
        switch self {
        case .contextOverflow: return "会話が長すぎて、モデルの文脈に入りません"
        case let .unavailable(reason): return reason
        case let .failed(message): return "答えを作れませんでした（\(message)）"
        }
    }
}

/// Apple の FoundationModels で、会話の答えを作る。
public struct AppleChatBackend: ChatBackend {
    public init() {}

    public func respond(instructions: String, turns: [ChatTurn], user: String) async throws -> String {
        if case let .unavailable(reason) = AppleIntelligence.current() { throw ConversationError.unavailable("\(reason.summary)。\(reason.remedy)") }
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [.text(.init(content: instructions))], toolDefinitions: []))]
        for turn in turns {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: turn.user))])))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.assistant))])))
        }
        let session = LanguageModelSession(transcript: Transcript(entries: entries))
        do {
            return try await session.respond(to: user).content
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { throw ConversationError.contextOverflow }
            throw ConversationError.failed(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConversationError.failed(error.localizedDescription)
        }
    }
}
