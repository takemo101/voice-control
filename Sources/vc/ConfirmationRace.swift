import Foundation

/// 画面の上のパネルのボタン（「実行する」「やめる」）の答え。1 回だけ決まる（先に押したものが勝つ）。
/// `@unchecked Sendable` の理由：可変な状態（`answer`・`waiter`）は、すべて `lock` で守る。
final class PanelAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool?
    private var waiter: CheckedContinuation<Bool?, Never>?

    /// ボタンが押された（`true`＝実行する）。2 回目以降は、無視する。
    func resolve(_ yes: Bool) {
        lock.lock()
        guard answer == nil else { lock.unlock(); return }
        answer = yes
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: yes)
    }

    /// 答えを待つ。待っている `Task` が取りやめられたら、`nil`。
    func wait() async -> Bool? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let answer {
                    lock.unlock()
                    continuation.resume(returning: answer)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume(returning: nil)
        }
    }
}

/// 確認の答えを、2 つの口で待つ：パネルのボタンと、声の返事。**先に答えたほうが決まり、もう一方は取りやめる**。
enum ConfirmationRace {
    /// - `voice`：声の返事を待って、はいか（取りやめられたら、`false`）。失敗は、そのまま投げる（先にボタンが押されていれば、投げない）。
    static func decide(panel: PanelAnswer, voice: @escaping @Sendable () async throws -> Bool) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool?.self) { group in
            group.addTask { await panel.wait() }
            group.addTask { try await voice() }
            while let result = try await group.next() {
                if let decided = result { group.cancelAll(); return decided }
            }
            return false   // どちらも決められずに終わった（取りやめ）
        }
    }
}

/// パネルのボタンの答えの届け先（確認を待っている間だけ、つなぐ）。どのスレッドから、つないでも、よい。
/// `@unchecked Sendable` の理由：可変な状態（`handler`）は、すべて `lock` で守る。
final class AnswerRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?

    func set(_ handler: (@Sendable (Bool) -> Void)?) { lock.lock(); self.handler = handler; lock.unlock() }

    /// 届ける（つないでいなければ、何もしない：確認を待っていないときの、古いボタン）。
    func deliver(_ yes: Bool) { lock.lock(); let current = handler; lock.unlock(); current?(yes) }
}
