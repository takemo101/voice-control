import Foundation
import VCSpeech

/// スクリーンショットを撮った直後に、**自動で録音を始め、黙ったら止める**（`vc listen --hotkey`）。キーを押さなくても、そのまま話せる。
/// しくみ：`VirtualTrigger`（コードが押す・離すトリガー）を、声で頼むトリガーの 1 つとして `ModeTrigger` に入れ、`ScreenFlow` が押す。止めるのは、
/// 黙ったとき（`SilenceEndpoint`）・Shift の長押しを離したとき（キーのトリガーの「離した」と同じ）・Esc（取りやめ）。
/// 状態は、すべてメインアクター。音の大きさは、音声のスレッドから来るので、メインへ回して受ける。
@MainActor final class AutoListen {
    static let shared = AutoListen()
    /// `ModeTrigger` に、声で頼むトリガーの印（`VoiceMode.listen`）で入れる。
    let trigger = VirtualTrigger()
    /// 録音中に、画面の上へ出す案内（自動の録音のときだけ）。
    private(set) var hint: String?
    private var endpoint: SilenceEndpoint?
    private var starting = false

    /// 録音を始める。別の録音・処理中で始められなければ、何もしない（`ModeTrigger` が、押しを無視する）。
    func begin(hint: String) {
        self.hint = hint
        starting = true
        trigger.press()   // 始まれば、`.recordingStarted` が、その場で届く
        starting = false
        if endpoint == nil { self.hint = nil }
    }

    /// 自動の録音の状態に関わる出来事だけ（メインのスレッドで届くもの）。
    nonisolated static func watches(_ event: VoiceLoopEvent) -> Bool {
        switch event {
        case .recordingStarted, .recordingDiscarded, .recognizing, .recordingEmpty, .recordingFailed: return true
        default: return false
        }
    }

    /// 出来事を受けて、画面の上に出す案内（なければ `nil`）を返す。`watches` が true の出来事だけ、メインのスレッドで呼ぶ。
    nonisolated static func process(_ event: VoiceLoopEvent) -> String? {
        MainActor.assumeIsolated { shared.handle(event) }
    }

    private func handle(_ event: VoiceLoopEvent) -> String? {
        switch event {
        case .recordingStarted:
            if starting { endpoint = SilenceEndpoint(); Self.setActive(true) }
            return endpoint == nil ? nil : hint
        case .recordingDiscarded:
            // Esc：`ModeTrigger` の「押している」を解く（人のキーなら、離して解ける）
            let wasAuto = endpoint != nil
            finish()
            if wasAuto { trigger.release() }
        case .recognizing, .recordingEmpty, .recordingFailed:
            finish()   // 離された（キー・黙った）
        default: break
        }
        return nil
    }

    private func finish() {
        endpoint = nil
        hint = nil
        Self.setActive(false)
    }

    private func level(_ level: Float, at time: TimeInterval) {
        guard var current = endpoint else { return }
        let verdict = current.feed(level: level, at: time)
        endpoint = current
        if case .stop = verdict { trigger.release() }   // `.recognizing` が届いて、`finish()` する
    }

    // MARK: 音の大きさ（音声のスレッドから）

    private nonisolated static func setActive(_ value: Bool) { activeFlag.set(value) }

    /// 録音中の音量（0〜1）を受ける。**音声のスレッドから呼ばれる**。自動の録音でなければ、何もしない。
    nonisolated static func pushLevel(_ level: Float) {
        guard activeFlag.value else { return }
        let time = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.level(level, at: time) } }
    }
}

/// 自動の録音の最中か（音声のスレッドが、読む）。`@unchecked Sendable` の理由：`flag` は、すべて `lock` で守る。
private final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ newValue: Bool) { lock.lock(); flag = newValue; lock.unlock() }
}

private let activeFlag = ActiveFlag()
