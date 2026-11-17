import Foundation
import VCCore

/// 1 回の質問の間に、一度だけ立つ印（時間切れ。別のタスクが立てる）。`@unchecked Sendable`：中身（`on`）は、すべて、ロックの下。
final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock(); private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

/// 1 回の質問の、受け取り（相手からの通知・許可の要求）：答えの文字・実行中の操作・許可の確認。
/// `@unchecked Sendable`：相手の通知・要求は、別のタスクから、来る。**可変の持ち物（下の `lock` の欄）は、すべて、ロックの下**。ほかは、不変。
final class ACPTurnState: @unchecked Sendable {
    private let lock = NSLock()
    // — ここから `lock` の下 —
    private var collected = ""
    private var calls: [String: (call: ACPToolCall, activity: ChatActivity, terminal: String)] = [:]   // ツール呼び出しの番号 → 呼び出し・出した操作・端末の出力（題・結果が、あとから届いたとき、同じ操作を、置き換える）
    private var refused = 0
    private var blocked = 0
    private var lastProgress = Date()
    private var confirming = 0
    private var confirmTask: Task<Bool, Never>?
    private var cancelRequested = false
    // — ここまで —
    private let tools: ChatToolLevel
    private let folder: URL
    private let sessionID: String
    private let confirm: ToolConfirm?
    private let onActivity: ActivityHandler?

    init(tools: ChatToolLevel, folder: URL, sessionID: String, confirm: ToolConfirm?, onActivity: ActivityHandler?) {
        self.tools = tools; self.folder = folder; self.sessionID = sessionID; self.confirm = confirm; self.onActivity = onActivity
    }

    var text: String { lock.withLock { collected } }
    /// 相手から何も来ていない時間（秒）。**利用者の確認を待っている間は、0**。
    var idleSeconds: TimeInterval { lock.withLock { confirming > 0 ? 0 : Date().timeIntervalSince(lastProgress) } }
    /// 断った操作の数（確認で断った・段階で許されていない・取り返しのつかないコマンド）。
    var refusals: Int { lock.withLock { refused } }
    /// 取り返しのつかないコマンドとして、断った数。
    var blockedCommands: Int { lock.withLock { blocked } }

    /// 確認の待ちを、取りやめる（Esc・時間切れ・終わり）。**相手からの要求は、別のタスクで処理されるので、質問の取りやめが、届かない**：ここで、確認の待ち（パネル）を、止める。
    func cancelPendingConfirm() {
        let task = lock.withLock { () -> Task<Bool, Never>? in cancelRequested = true; return confirmTask }
        task?.cancel()
    }

    func handleNotification(_ method: String, _ params: JSONValue) {
        guard method == "session/update", params["sessionId"]?.string == sessionID, let update = params["update"] else { return }
        lock.withLock { lastProgress = Date() }
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            if let chunk = update["content"]?["text"]?.string { lock.withLock { collected += chunk } }
        case "tool_call":
            let call = ACPToolCall(update)
            guard let callID = update["toolCallId"]?.string, lock.withLock({ calls[callID] == nil }) else { return }
            guard let activity = ACPPermissionText.activity(call)?.with(id: callID, output: nil) else { return }
            lock.withLock { calls[callID] = (call, activity, "") }
            onActivity?(activity)
        case "tool_call_update":
            // あとから届く、題（Claude：「Terminal」→「ls -la」）・結果（コマンドの出力・差分。Codex：端末の出力の断片）：同じ操作（番号が同じ）に、付けて、知らせ直す
            guard let callID = update["toolCallId"]?.string, let known = lock.withLock({ calls[callID] }) else { return }
            var call = known.call
            if let title = update["title"]?.string, !title.isEmpty { call.title = title }
            var terminal = known.terminal
            if let data = update["_meta"]?["terminal_output_delta"]?["data"]?.string { terminal += data }
            let content = update["content"]?.array ?? []
            let output = ACPToolOutput.make(kind: call.kind, content: content) ?? (call.kind == "execute" ? ACPToolOutput.terminal(terminal) : nil) ?? known.activity.output
            guard let base = ACPPermissionText.activity(call) else { return }
            let updated = base.with(id: callID, output: output)
            guard updated != known.activity || terminal != known.terminal else { return }
            lock.withLock { calls[callID] = (call, updated, terminal) }
            if updated != known.activity { onActivity?(updated) }
        default: break
        }
    }

    /// 相手からの要求。許可の確認だけに答える（ファイル・端末の機能は、こちらが宣言していないので、来ない）。
    func handleRequest(_ method: String, _ params: JSONValue) async -> JSONValue? {
        guard method == "session/request_permission", params["sessionId"]?.string == sessionID else { return nil }
        let call = ACPToolCall(params["toolCall"] ?? .null)
        let options = params["options"]?.array ?? []
        func answer(_ allow: Bool) -> JSONValue { ACPPermission.outcome(allow: allow, options: options) }
        switch ACPPermission.decide(call, folder: folder, level: tools) {
        case .allow: return answer(true)
        case .block: lock.withLock { refused += 1; blocked += 1 }; return answer(false)
        case .reject: lock.withLock { refused += 1 }; return answer(false)
        case .ask:
            guard let confirm else { lock.withLock { refused += 1 }; return answer(false) }   // 確認できない：しない
            lock.withLock { confirming += 1 }
            let detail = ACPPermissionText.detail(call, folder: folder)
            let task = Task { await confirm(detail) }   // 取りやめを、届けるため、自分のタスクで待つ
            lock.withLock { confirmTask = task }
            let allowed = await task.value
            let cancelled = lock.withLock { () -> Bool in confirmTask = nil; confirming -= 1; lastProgress = Date(); return cancelRequested }
            if cancelled { return ACPPermission.cancelledOutcome }   // 質問が、取りやめになった：仕様どおり、`cancelled` で答える
            if !allowed { lock.withLock { refused += 1 } }
            return answer(allowed)
        }
    }
}
