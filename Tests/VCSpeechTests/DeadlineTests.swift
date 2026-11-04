import Foundation
import Testing
@testable import VCSpeech

@Suite struct DeadlineTests {
    /// 取りやめに応えず、止まったままの処理（`stop` が立つまで、取りやめを無視して回り続ける）。
    private final class Stuck: @unchecked Sendable {   // 偽物：テストの数行。lock で守る
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func run() async -> Int {
            while !isStopped { _ = try? await Task.sleep(nanoseconds: 5_000_000) }   // 取りやめを、わざと無視する
            return 0
        }
    }

    @Test func returnsTheResultOfAnOperationThatFinishesInTime() async throws {
        let value = try await withDeadline(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test func anErrorFromTheOperationIsPassedOn() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await withDeadline(seconds: 5) { () async throws -> Int in throw Boom() } }
    }

    /// 認識が止まったままでも、時間が来たら抜ける（待ち続けない）。処理が取りやめに応えなくても。
    @Test func aStuckOperationEndsWithATimeoutEvenIfItIgnoresCancellation() async {
        let stuck = Stuck()
        defer { stuck.stop() }
        let started = Date()
        await #expect(throws: DeadlineExceeded.self) { try await withDeadline(seconds: 0.2) { await stuck.run() } }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    /// Esc（呼び出し側の取りやめ）で、すぐ抜ける。時間切れを待たない。処理が取りやめに応えなくても。
    @Test func cancellingTheCallerReturnsAtOnceEvenIfTheOperationIgnoresIt() async {
        let stuck = Stuck()
        defer { stuck.stop() }
        let task = Task { try await withDeadline(seconds: 60) { await stuck.run() } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 3)
        #expect({ if case .failure(let e) = result { return e is CancellationError } else { return false } }())
    }

    /// すでに取りやめられた状態で呼ばれても、処理を待たずに抜ける。
    @Test func aCallerThatWasAlreadyCancelledReturnsAtOnce() async {
        let stuck = Stuck()
        defer { stuck.stop() }
        let task = Task { () async throws -> Int in
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000) }
            return try await withDeadline(seconds: 60) { await stuck.run() }
        }
        task.cancel()
        let result = await task.result
        #expect({ if case .failure(let e) = result { return e is CancellationError } else { return false } }())
    }
}
