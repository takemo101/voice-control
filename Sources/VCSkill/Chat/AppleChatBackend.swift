import Foundation
import FoundationModels
import VCCore

/// 会話の答えを作る側（Apple のオンデバイスのモデル）。道具（検索・ファイル・書き込み・コマンド）を、段階に応じて渡す。**毎回、指示と過去の往復から、新しい会話を作る**（状態を持たない）。
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
        try await respond(instructions: instructions, turns: turns, user: user, options: ChatCallOptions())
    }

    /// 画像は、Apple の会話では、**文字にして、質問に入れてある**（`ChatAttachments`）ので、`options.image` は、使わない。
    public func respond(instructions: String, turns: [ChatTurn], user: String, options: ChatCallOptions) async throws -> String {
        let onActivity = options.onActivity, confirm = options.confirm, allowsWeb = options.allowsWeb
        if case let .unavailable(reason) = AppleIntelligence.current() { throw ConversationError.unavailable("\(reason.summary)。\(reason.remedy)") }
        if tools.usesFolder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let calls = CallCounter()
        let available = AppleChatTools.make(level: tools, folder: folder, web: web, allowsWeb: allowsWeb, confirm: confirm.map { ask -> ToolConfirm in { @Sendable detail in calls.markAsked(); return await ask(detail) } },
                                            activity: { calls.record($0); onActivity?($0) })
        let definitions = available.map { Transcript.ToolDefinition(tool: $0) }
        // Web の道具を外した質問：モデルに、そう伝える（検索を約束して、道具がなく、困らないように）
        let instructions = allowsWeb || tools == .none ? instructions : instructions + "\n\nFor this conversation the web tools are turned off (the user shared a screenshot or copied text, which must not leave this Mac). Do not search the web; answer from the shared content and your own knowledge, and say so if you cannot."
        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [.text(.init(content: instructions))], toolDefinitions: definitions))]
        for turn in turns {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: turn.user))])))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.assistant))])))
        }
        let session = LanguageModelSession(tools: available, transcript: Transcript(entries: entries))
        do {
            var reply = try await session.respond(to: user).content
            // 道具を呼ばなかった答え（作り話・予告だけ）を、返さない（`ToolUseGuard`）
            let guardrail = ToolUseGuard(level: tools, user: user, folder: folder, allowsWeb: allowsWeb)
            var step = ToolUseGuard.Step.start
            while true {
                switch guardrail.next(step, calls: calls.count, acted: calls.acted, reply: reply) {
                case .done:
                    return ToolUseGuard.cleaned(reply)
                case let .nudge(text, then):
                    reply = try await session.respond(to: text).content
                    step = then
                case let .readFile(name, text):
                    onActivity?(.read(name))
                    return ToolUseGuard.cleaned(try await session.respond(to: ToolUseGuard.fileResult(name: name, text: text)).content)
                case let .fail(message):
                    throw ConversationError.failed(message)
                }
            }
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
    func record(_ activity: ChatActivity) {
        lock.lock(); value += 1; if activity.changesSomething { acting = true }; lock.unlock()
    }
    /// 利用者に、確認を求めた（断られた場合も、道具は、呼ばれている）。
    func markAsked() { lock.lock(); acting = true; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    var acted: Bool { lock.lock(); defer { lock.unlock() }; return acting }
}
