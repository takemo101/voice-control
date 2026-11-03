import Foundation

/// 「取りやめ」の合図（Esc キーなど）。どのスレッドからでも `cancel()` でき、実行中の処理が、確かめたり、止める手続きを登録したりする。
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 取りやめる。登録された手続き（実行中のコマンドを止める、など）を、1 度だけ呼ぶ。
    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let pending = handlers
        handlers = []
        lock.unlock()
        pending.forEach { $0() }
    }

    /// 取りやめられたときに呼ぶ手続きを登録する（すでに取りやめられていれば、すぐ呼ぶ）。
    public func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        handlers.append(handler)
        lock.unlock()
    }
}
