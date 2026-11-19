import Foundation
import Testing
@testable import VCSpeech
import VCCore

@Suite struct VoiceActivityTests {
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func add(_ v: Bool) { lock.lock(); values.append(v); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
    }

    @Test func escWhileRecordingDiscardsTheRecordingAndIgnoresTheLaterRelease() {
        let activity = VoiceActivity()
        let changes = Changes()
        activity.onChange = { changes.add($0) }
        activity.startRecording()
        #expect(activity.isActive)
        #expect(activity.escape() == .recording)
        #expect(!activity.isActive)
        #expect(activity.consumeCancelledRecording())    // 離したときの処理は、何もしない
        #expect(!activity.consumeCancelledRecording())   // 1 度だけ
        #expect(changes.all == [true, false])
    }

    @Test func escWhileWorkingCancelsTheTokenAndTheTask() async {
        let activity = VoiceActivity()
        let token = CancelToken()
        activity.beginWork(token)
        let task = Task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) } }
        activity.setTask(task)
        #expect(activity.escape() == .work)
        #expect(token.isCancelled)
        await task.value   // 取りやめられて、終わる
        #expect(task.isCancelled)
        activity.endWork()
        #expect(!activity.isActive)
    }

    @Test func recordingTakesPriorityOverWorkWhenBothAreActive() {
        // 確認の返事を録音している間の Esc：まず録音を捨てる（処理は、続く。もう一度 Esc で取りやめる）
        let activity = VoiceActivity()
        let token = CancelToken()
        activity.beginWork(token)
        activity.startRecording()
        #expect(activity.escape() == .recording)
        #expect(!token.isCancelled && activity.isActive)
        #expect(activity.escape() == .work)
        #expect(token.isCancelled)
    }

    @Test func escWhenIdleDoesNothing() {
        let activity = VoiceActivity()
        #expect(activity.escape() == .nothing)
        #expect(!activity.isActive)
    }

    @Test func queuedAudioKeepsTheActivityActiveUntilItIsConsumed() {
        let activity = VoiceActivity()
        activity.startRecording()
        activity.stopRecording(queuedAudio: true)
        #expect(activity.isActive)   // 認識の待ち
        activity.consumedAudio()
        #expect(!activity.isActive)
    }

    @Test func cancelSignalWakesAWaitingReader() async {
        let queue = VoiceInputQueue()
        let waiting = Task { await queue.next() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        queue.push(.cancel)
        guard case .cancel = await waiting.value else { Issue.record("expected .cancel"); return }
        queue.push(.audio(URL(fileURLWithPath: "/tmp/a.caf")))   // 待っていないときの入力は、たまる
        guard case .audio = await queue.next() else { Issue.record("expected .audio"); return }
    }
}

/// 入力を待っている処理が取りやめられたら、`.cancel` で戻る（確認で、パネルのボタンが先に押されたとき、声の返事を待つ処理が、次の発話を横取りしない）。
@Suite struct VoiceInputQueueCancellationTests {
    @Test func aWaitingTaskThatIsCancelledReturnsCancelAndDoesNotTakeTheNextInput() async {
        let queue = VoiceInputQueue()
        let waiting = Task { await queue.next() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        waiting.cancel()
        if case .cancel = await waiting.value {} else { Issue.record("取りやめで、.cancel が返らなかった") }
        // そのあとに来た発話は、次に待つ処理が受け取る
        let url = URL(fileURLWithPath: "/tmp/next.caf")
        queue.push(.audio(url))
        if case .audio(let got) = await queue.next() { #expect(got == url) } else { Issue.record("次の発話が、横取りされた") }
    }

    @Test func aNewUtteranceOfTheSameKindCanWaitInsteadOfCancellingTheRunningWork() {
        let activity = VoiceActivity()
        let token = CancelToken()
        activity.beginWork(token, tag: "chat")
        #expect(!activity.interruptForNewUtterance(keepsRunning: { $0 == "chat" }))   // 会話に、会話が続く：待たせる
        #expect(!token.isCancelled && !token.isSuperseded)
        #expect(activity.takeDeferred() == 1 && activity.takeDeferred() == 0)         // Esc で捨てる数
        #expect(activity.interruptForNewUtterance(keepsRunning: { $0 == "listen" }))  // 別の流れ：従来どおり、取って代わる
        #expect(token.isSuperseded)
    }

    @Test func forcedInterruptWorksEvenWhileWaitingForAConfirmationReply() {
        let activity = VoiceActivity()
        let token = CancelToken()
        activity.beginWork(token, tag: "chat")
        activity.beginAwaitingReply()
        #expect(!activity.interruptForNewUtterance())     // 返事を待っている間は、新しい発話は、返事
        #expect(activity.interruptRunning() && token.isSuperseded)
        activity.endAwaitingReply(); activity.endWork()
        #expect(!activity.interruptRunning())             // 何もしていなければ、何もしない
    }

    @Test func discardingWaitingAudioRemovesTheFilesAndKeepsOtherInputs() async throws {
        let queue = VoiceInputQueue()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = (0..<2).map { directory.appendingPathComponent("\($0).wav") }
        for file in files { try Data([0]).write(to: file) }
        queue.push(.audio(files[0])); queue.push(.cancel); queue.push(.audio(files[1]))
        #expect(queue.discardAudio(limit: 1) == 1)                                       // 古いほうから、数だけ
        #expect(!FileManager.default.fileExists(atPath: files[0].path) && FileManager.default.fileExists(atPath: files[1].path))
        guard case .cancel = await queue.next() else { Issue.record("音声以外の入力まで、捨てた"); return }
        #expect(queue.discardAudio(limit: 5) == 1 && !FileManager.default.fileExists(atPath: files[1].path))
    }
}

