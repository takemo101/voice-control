import Foundation

/// 「取りやめ」の合図（Esc キーなど）。どのスレッドからでも `cancel()` でき、実行中の処理が、確かめたり、止める手続きを登録したりする。
/// `@unchecked Sendable` の理由：可変な状態（取りやめたか・手続き）は、すべて `lock` で守る。
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var superseded = false
    private var handlers: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 新しい依頼に、取って代わられた（Esc ではなく）。そのとき、表示は、「取りやめました」を出さない（新しい依頼の表示を、上書きしないため）。
    public var isSuperseded: Bool { lock.lock(); defer { lock.unlock() }; return superseded }

    /// 新しい依頼が来たので、取りやめる（`cancel()` と同じ。表示のために、理由を残す）。
    public func supersede() {
        lock.lock(); superseded = true; lock.unlock()
        cancel()
    }

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
