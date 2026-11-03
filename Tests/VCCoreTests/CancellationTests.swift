import Foundation
import Testing
import VCCore

/// 取りやめの合図（`CancelToken`）。コマンドを止める側は `VCSkill`、録音を捨てる側は `VCSpeech` のテスト（同じ名前のスイート）。
@Suite struct CancellationTests {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @Test func tokenRunsHandlersOnceAndImmediatelyWhenAlreadyCancelled() {
        let token = CancelToken()
        let calls = LockedCounter()
        token.onCancel { calls.increment() }
        #expect(!token.isCancelled)
        token.cancel()
        token.cancel()
        #expect(token.isCancelled && calls.value == 1)
        token.onCancel { calls.increment() }   // 取りやめ済みなら、すぐ呼ぶ
        #expect(calls.value == 2)
    }
}
