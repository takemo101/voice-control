import Foundation

/// `withDeadline` が、時間切れのときに投げる。
struct DeadlineExceeded: Error, Equatable {}

/// `operation` を実行し、`seconds` 秒以内に終わらなければ `DeadlineExceeded` を投げる。呼び出し側のタスクが取りやめられたら（Esc）、すぐ `CancellationError` を投げる。
/// **`operation` が、取りやめに応えなくても、待たない**（放置する）：構造化された並行（`TaskGroup`）は、子が終わるまで抜けられず、止まった処理が、呼び出し側を止め続けてしまう。
/// 先に決まった結果だけを返す（あとから来た結果は、捨てる）。
func withDeadline<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            race.start(continuation)
            let work = Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            }
            // 時間切れは、GCD のタイマーで測る：Swift の並行処理のスレッド（`Task.sleep`）は、ほかの処理（止まった認識・外部コマンドの待ち）で塞がると、タイマーが遅れる。ここは、遅れてはいけない
            let timer = DispatchWorkItem { race.finish(.failure(DeadlineExceeded())) }
            DispatchQueue.global().asyncAfter(deadline: .now() + min(max(0, seconds), 1e9), execute: timer)   // 上限（約 31 年）を置く：極端に大きい値で、変換が落ちないように
            race.onSettled { work.cancel(); timer.cancel() }
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// 先に着いた結果を 1 回だけ、待っている側へ渡す。
/// `@unchecked Sendable` の理由：可変な状態（`continuation`・`result`・`settled`）は、すべて `lock` で守る。
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var settled: (@Sendable () -> Void)?

    /// 待つ側を登録する。取りやめが先に決まっていれば、すぐ渡す。
    func start(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
    }

    /// 結果が決まったときの後始末（作業・タイマーの取りやめ）。すでに決まっていれば、すぐ実行する。
    func onSettled(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if result != nil { lock.unlock(); handler(); return }
        settled = handler
        lock.unlock()
    }

    func finish(_ value: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation
        let settled = self.settled
        self.continuation = nil
        self.settled = nil
        lock.unlock()
        continuation?.resume(with: value)
        settled?()
    }
}
