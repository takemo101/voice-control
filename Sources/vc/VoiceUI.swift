import AppKit
import Foundation
import VCCore
import VCSpeech

/// 声の流れ（`vc listen --hotkey`・`vc dictate`）に共通の、画面の上と端末の表示・終了の後始末・録音の開始の音。
/// 録音を始めたトリガーの印（`ModeTrigger`）。`vc listen --hotkey` は、トリガーで、声で頼む／音声入力を切り替える。
enum VoiceMode {
    static let listen = "listen"
    static let dictate = "dictate"
}

enum VoiceUI {
    /// 録音中に、ほかの音を消すか：`--mute`・`--no-mute`（その実行だけ）→ 設定（`vc mute`）→ 既定（消す）。
    static func muter(_ arguments: inout Arguments, _ context: CommandContext, command: String) -> OutputMuter {
        let flag: Bool?
        switch (arguments.flag("--mute"), arguments.flag("--no-mute")) {
        case (true, true): usageError(command, "--mute と --no-mute は、一緒に使えません")
        case (true, false): flag = true
        case (false, true): flag = false
        case (false, false): flag = nil
        }
        return MutePreference.resolve(flag: flag, setting: context.currentSettings().mute) ? .system : .disabled
    }

    /// `VoiceLoop` の出来事を、画面の上と端末に出す。
    static func show(_ event: VoiceLoopEvent, chip: String, muter: OutputMuter, dictation: Bool = false) {
        switch event {
        case .recordingStarted:
            LiveCaption.shared.begin()   // 録音中の文字（途中経過）
            HUD.shared.show(HUDContent(phase: .recording, title: "録音中", hint: dictation ? "離すと、文字にして入力します（Esc で取りやめ）" : "離すと、認識して実行します（Esc で取りやめ）", chip: chip))
        case .recordingDiscarded:
            LiveCaption.shared.end()
            muter.restore()
            print("  " + Style.yellow("録音を取りやめました（Esc）"))
            HUD.shared.show(HUDContent(phase: .info, title: "録音を取りやめました", chip: chip), hideAfter: 1.5)
        case .recognizing:
            LiveCaption.shared.end()
            muter.restore()   // 認識の合図（Tink）を、聞こえるように、先に戻す
            NSSound(named: "Tink")?.play()
            HUD.shared.show(HUDContent(phase: .working, title: "認識中…", hint: "Esc で取りやめ", chip: chip))
        case .recordingEmpty:
            LiveCaption.shared.end()
            muter.restore()
            HUD.shared.hide()
        case let .recordingFailed(error):
            LiveCaption.shared.end()
            muter.restore()
            print("録音に失敗: \(error)")
            HUD.shared.show(HUDContent(phase: .failure, title: "録音に失敗しました", reply: "\(error)"), hideAfter: 4)
        case let .recognized(text):
            if !dictation { kv("聞こえた", text) }   // 入力モードは、入力した文字を、端末に出さない（画面の上のパネルだけ）
        case .recognitionCancelled:
            showCancelled(chip: chip)
        case let .recognitionFailed(error):
            showFailure(error, chip: chip)
        case .cancelling:
            SaySpeaker.shared.stop()
            HUD.shared.show(HUDContent(phase: .info, title: "取りやめています…", chip: chip))
        case .interrupted:
            // 画面の上は、新しい発話の「認識中」のまま（上書きしない）。読み上げだけ止める
            SaySpeaker.shared.stop()
            print("  " + Style.dim("前の処理を中断して、新しい依頼を受けました"))
        }
    }

    /// 取りやめた（文字にする段階も、実行の段階も、同じ表示）。
    static func showCancelled(chip: String) {
        print("  " + Style.yellow("取りやめました（Esc）"))
        HUD.shared.show(HUDContent(phase: .info, title: "取りやめました", chip: chip), hideAfter: 2)
    }

    static func showFailure(_ error: Error, chip: String) {
        print(Style.red("失敗:") + " \(error)")
        HUD.shared.show(HUDContent(phase: .failure, title: "失敗", chip: chip, reply: "\(error)"), hideAfter: 6)
    }

    /// Ctrl+C（SIGINT）・SIGTERM・SIGHUP で終わるとき、消した出力を戻してから終わる（消したままにしない）。
    /// 受ける場所は、主キューではない：`readLine`（Enter モード）・`NSApplication.run()` が、主キューを塞ぐ。強制終了（SIGKILL）・クラッシュは、戻せない。
    static func restoreOnSignals(_ muter: OutputMuter, _ speech: SpeechEngine) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM, SIGHUP].map { sig in
            signal(sig, SIG_IGN)   // 既定の動作（そのまま終わる）を、止める
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { muter.restore(); speech.close(); ScreenshotStore.clear(); exit(128 + sig) }   // 撮ったスクリーンショットも、消す   // 音声認識のモデルは、開いたまま exit すると abort する
            source.resume()
            return source
        }
    }
}

/// 録音を始めたあとに、開始の音（Pop）を鳴らし、そのあと、ほかの音を消す。止めたら・捨てたら、戻す（録音の開始 → 音 → 消す、の順を保つ。`VoiceLoop` は、音も、出力の消音も知らない）。
final class PopRecorder: Recording {
    private let base: Recording
    private let muter: OutputMuter
    init(_ base: Recording, muter: OutputMuter) { self.base = base; self.muter = muter }

    func start() {
        base.start()
        NSSound(named: "Pop")?.play()
        muter.engage()   // Pop が鳴り終わるころに、消す。離すのが先なら、消さない
    }

    func discard() { muter.restore(); base.discard() }
    func stop() throws -> URL? { muter.restore(); return try base.stop() }
}
