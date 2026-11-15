import Foundation
import FoundationModels

/// 会話の答えを作る側（Apple のオンデバイスのモデル）。**毎回、指示と過去の往復から、会話を組み立てる**（状態を持たない：要約で、過去を差し替えやすい）。
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
        case .contextOverflow: return "会話が長すぎて、モデルの文脈に入りません"
        case let .unavailable(reason): return reason
        case let .failed(message): return "答えを作れませんでした（\(message)）"
        }
    }
}

/// Apple の FoundationModels で、会話の答えを作る。
public struct AppleChatBackend: ActivityReporting {
    public let tools: ChatToolLevel
    public let folder: URL
    private let web: WebAccess

    /// `tools`：開ける道具の段階。`all` は、作業フォルダの中への書き込みと、コマンドの実行まで（**上書き・安全でないコマンドは、毎回、利用者に確認する**：`CommandGate`）。
    public init(tools: ChatToolLevel = .none, folder: URL? = nil) {
        self.tools = tools
        self.folder = folder ?? ExternalChatBackend.defaultFolder
        self.web = .live
    }

    init(tools: ChatToolLevel, folder: URL, web: WebAccess) {
        self.tools = tools; self.folder = folder; self.web = web
    }

    public var capabilityNote: String { AppleChatTools.note(tools) }

    public func respond(instructions: String, turns: [ChatTurn], user: String) async throws -> String {
        try await respond(instructions: instructions, turns: turns, user: user, onActivity: nil, confirm: nil)
    }

    public func respond(instructions: String, turns: [ChatTurn], user: String, onActivity: (@Sendable (String) -> Void)?, confirm: ToolConfirm?) async throws -> String {
        if case let .unavailable(reason) = AppleIntelligence.current() { throw ConversationError.unavailable("\(reason.summary)。\(reason.remedy)") }
        if tools.usesFolder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let calls = CallCounter()
        let available = AppleChatTools.make(level: tools, folder: folder, web: web, confirm: confirm.map { ask -> ToolConfirm in { @Sendable detail in calls.markAsked(); return await ask(detail) } },
                                            activity: { calls.record($0); onActivity?($0) })
        let definitions = available.map { Transcript.ToolDefinition(tool: $0) }
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [.text(.init(content: instructions))], toolDefinitions: definitions))]
        for turn in turns {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: turn.user))])))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.assistant))])))
        }
        let session = LanguageModelSession(tools: available, transcript: Transcript(entries: entries))
        do {
            var reply = try await session.respond(to: user).content
            // 小さなモデルは、道具を呼ばずに、「調べます」「読み取ります」と、予告だけで終えることがある：1 回だけ、いま呼ぶよう促す
            let needed = AppleChatTools.needsTool(user, level: tools)
            if !available.isEmpty, calls.count == 0, needed || AppleChatTools.looksLikeAPromise(reply) {
                reply = try await session.respond(to: AppleChatTools.nudge).content
            }
            // それでも道具を呼ばなかった：**作り話の答え**（読んでいないファイルの中身・調べていないニュース）を、返さない
            if !available.isEmpty, calls.count == 0, needed {
                // 名前の出たファイルは、コードが読んで、結果を渡す（モデルが、道具を呼ばなくても、読めるように）
                if tools.usesFolder, !AppleChatTools.wantsToChange(user), let name = AppleChatTools.mentionedFile(in: user, folder: folder), let text = try? FolderReader(root: folder).read(name) {
                    onActivity?("読む: " + name)
                    return try await session.respond(to: AppleChatTools.fileResult(name: name, text: text)).content
                }
                throw ConversationError.failed("道具（検索・ファイル）を使えませんでした。言い方を変えて、もう一度お願いします（例：「note.txt を読んで」「〇〇のニュースを検索して」）")
            }
            // 書く・実行する依頼なのに、書く道具・コマンドの道具が、呼ばれていない（「作成します」と予告だけ）：1 回促し、それでも呼ばなければ、した、とは言わず、失敗として知らせる
            if tools == .all, needed, AppleChatTools.wantsToChange(user), !calls.acted {
                reply = try await session.respond(to: AppleChatTools.nudgeToAct).content
                if !calls.acted {
                    throw ConversationError.failed("ファイルの書き込み・コマンドの実行は、できませんでした（モデルが、道具を呼びませんでした）。もう一度、具体的に頼んでください（例：「done.txt に『確認済み』と書いて作って」）")
                }
            }
            return AppleChatTools.cleaned(reply)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { throw ConversationError.contextOverflow }
            if case .guardrailViolation = error { throw ConversationError.failed("Apple のモデルの安全機能が、この依頼を止めました。言い方を変えて、もう一度お願いします") }
            throw ConversationError.failed(error.localizedDescription)
        } catch let error as ConversationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConversationError.failed(error.localizedDescription)
        }
    }
}

/// 道具が呼ばれた回数（道具は、別のスレッドで呼ばれる）。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var acting = false
    /// 道具の呼び出しを、記録する（「書く」「実行」は、書き込み・コマンドの道具）。
    func record(_ activity: String) {
        lock.lock(); value += 1; if activity.hasPrefix("書く") || activity.hasPrefix("実行") { acting = true }; lock.unlock()
    }
    /// 利用者に、確認を求めた（断られた場合も、道具は、呼ばれている）。
    func markAsked() { lock.lock(); acting = true; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    var acted: Bool { lock.lock(); defer { lock.unlock() }; return acting }
}
