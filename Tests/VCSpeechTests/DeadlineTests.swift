import Foundation
import Testing
@testable import VCSpeech

@Suite(.timeLimit(.minutes(1))) struct DeadlineTests {
    /// 取りやめに応えず、止まったままの処理。`release()` まで、再開しない（取りやめを、わざと無視する）。スレッドも、タイマーも、使わない。
    private final class Stuck: @unchecked Sendable {   // 偽物：テストの数行。lock で守る
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Int, Never>?
        private var released = false
        func run() async -> Int {
            await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
                lock.lock()
                if released { lock.unlock(); c.resume(returning: 0) } else { continuation = c; lock.unlock() }
            }
        }
        /// 後始末：止まった処理を終わらせる（継続を、漏らさない）。
        func release() {
            lock.lock(); released = true; let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: 0)
        }
    }

    /// 結果が決まるまで、待つ（GCD のタイマーで、時間切れを測るので、Swift の並行処理のスレッドが塞がっていても、動く）。
    private func elapsed(_ body: () async -> Void) async -> TimeInterval {
        let started = Date()
        await body()
        return Date().timeIntervalSince(started)
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
        defer { stuck.release() }
        let seconds = await elapsed {
            await #expect(throws: DeadlineExceeded.self) { try await withDeadline(seconds: 0.2) { await stuck.run() } }
        }
        #expect(seconds < 5)
    }

    /// Esc（呼び出し側の取りやめ）で、すぐ抜ける。時間切れを待たない。処理が取りやめに応えなくても。
    @Test func cancellingTheCallerReturnsAtOnceEvenIfTheOperationIgnoresIt() async {
        let stuck = Stuck()
        defer { stuck.release() }
        let task = Task { try await withDeadline(seconds: 60) { await stuck.run() } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let seconds = await elapsed {
            task.cancel()
            let result = await task.result
            #expect({ if case .failure(let e) = result { return e is CancellationError } else { return false } }())
        }
        #expect(seconds < 5)
    }

    /// すでに取りやめられた状態で呼ばれても、処理を待たずに抜ける。
    @Test func aCallerThatWasAlreadyCancelledReturnsAtOnce() async {
        let stuck = Stuck()
        defer { stuck.release() }
        let task = Task { () async throws -> Int in
            while !Task.isCancelled { await Task.yield() }   // 取りやめられるまで、withDeadline を呼ばない（取りやめ済みの経路を通すため）
            return try await withDeadline(seconds: 60) { await stuck.run() }
        }
        task.cancel()
        let result = await task.result
        #expect({ if case .failure(let e) = result { return e is CancellationError } else { return false } }())
    }
}

/// 認識の時間の上限は、録音の長さで決める（短くても 10 秒は待つ。長い録音は、それに応じて）。
@Suite struct AnalysisTimeoutTests {
    @Test func theLimitFollowsTheRecordingLengthWithAFloor() {
        #expect(FileTranscriber.analysisTimeout(forSeconds: 0.5) == 10)
        #expect(FileTranscriber.analysisTimeout(forSeconds: 3) == 14)
        #expect(FileTranscriber.analysisTimeout(forSeconds: 30) == 95)
    }
}
