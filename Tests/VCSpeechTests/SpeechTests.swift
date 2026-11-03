import Foundation
import Testing
@testable import VCSpeech
import VCCore

@Suite struct HotKeySpecTests {
    private func parsed(_ text: String) throws -> HotKeySpec { try HotKeySpec.parse(text).get() }
    private func reason(_ text: String) -> String? {
        if case let .failure(f) = HotKeySpec.parse(text) { return f.reason }
        return nil
    }

    @Test func modifierOnlyIsAHold() throws {
        let shift = try parsed("shift")
        #expect(shift.isHold && shift == .default)
        let combo = try parsed("Ctrl + Opt")
        #expect(combo.isHold)
        #expect(combo.description == "ctrl+opt")
    }

    @Test func modifiersPlusKeyIsACombination() throws {
        let spec = try parsed("cmd+shift+R")
        #expect(!spec.isHold)
        #expect(spec.keyCode != nil)
        #expect(spec.description == "shift+cmd+r")  // 正規化：ctrl・opt・shift・cmd の順
    }

    @Test func legacyDashFormAndAliases() throws {
        #expect(try parsed("ctrl-opt-space") == parsed("control+alt+space"))
        #expect(try parsed("cmd+enter") == parsed("command+return"))
    }

    @Test func functionKeyMayStandAlone() throws {
        #expect(try parsed("f5").description == "f5")
    }

    @Test func rejectsWhatWouldStealTyping() {
        #expect(reason("r") != nil)       // 修飾キーなしの文字
        #expect(reason("space") != nil)
        #expect(reason("shift+a+b") != nil)  // キーが 2 つ
        #expect(reason("ctrl+") != nil)
        #expect(reason("") != nil)
        #expect(reason("ctrl+nope") != nil)
    }

    @Test func settingsFallBackToShiftAndReportBadValues() throws {
        var s = Settings()
        #expect(try s.hotkeySpec.get() == .default)
        s.hotkey = "ctrl+opt+space"
        #expect(try s.hotkeySpec.get().description == "ctrl+opt+space")
        s.hotkey = "bogus+"
        #expect(throws: HotKeySpec.Failure.self) { try s.hotkeySpec.get() }
    }

    @Test func oldSettingsFileWithoutHotkeyStillLoads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"disabledSkills":["a"]}"#.utf8).write(to: file)
        let s = try Settings.load(from: file)
        #expect(s.disabledSkills == ["a"] && s.hotkey == nil)
        var next = s
        next.hotkey = "f5"
        try next.save(to: file)
        #expect(try Settings.load(from: file) == next)
    }
}

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
