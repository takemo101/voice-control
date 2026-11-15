import AppKit
import AVFoundation
import Foundation
import VCSpeech

/// 読み上げ（確認の問いかけ・結果・会話の答え）。**入っている日本語の声のうち、品質がいちばん高いもの**を使う（`SpeechVoice`。利用者が決めた声があれば、それ）。
/// `AVSpeechSynthesizer` は、メインスレッドで使う（アプリは、メインのイベントのループが回っている）。取りやめたときは、止める。
/// **読んでいる間は、いつでも止められる**：Esc（読んでいる間だけ、キーを見張る。**Esc を、横取りしない**：ほかのアプリにも届く。アクセシビリティの許可があるとき。自分のウィンドウが前なら、そこでも）・ウィンドウの「読み上げを止める」・メニュー・トリガーを押す（録音が始まるとき）。
/// `@unchecked Sendable` の理由：`synthesizer`・`queued`・監視は、メインスレッドだけで触る。`preferred`・`speakingFlag` は、`lock` で守る。
final class SaySpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = SaySpeaker()
    private let lock = NSLock()
    private var preferredVoice: String?
    private var speakingFlag = false
    private var synthesizer: AVSpeechSynthesizer?   // メインスレッドだけ
    private var queued = 0                           // メインスレッドだけ：読む予定・読み中の数
    private var globalMonitor: Any?                  // メインスレッドだけ
    private var localMonitor: Any?
    private var observers: [@MainActor (Bool) -> Void] = []   // メインスレッドだけ

    /// 使う声（識別子か名前。なければ、自動）。聞き始める前に、決める。
    func prefer(_ voice: String?) { lock.lock(); preferredVoice = voice; lock.unlock() }

    /// いま使う声。
    func currentVoice() -> SpeechVoice.Info? {
        lock.lock(); let preferred = preferredVoice; lock.unlock()
        return SpeechVoice.resolve(preferred: preferred, voices: SpeechVoice.installed())
    }

    /// いま、読んでいるか（どのスレッドからでも）。
    var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return speakingFlag }

    /// 読み始め・読み終わり（止めたときも）で呼ぶ（メインスレッド）。
    @MainActor func observe(_ handler: @escaping @MainActor (Bool) -> Void) { observers.append(handler) }

    func say(_ text: String) { say(chunks: [text]) }

    /// 塊ごとに、続けて読む（止めたら、残りも、読まない）。
    func say(chunks: [String]) {
        guard !chunks.isEmpty else { return }
        let voice = currentVoice()
        DispatchQueue.main.async { [self] in
            let synthesizer = self.synthesizer ?? AVSpeechSynthesizer()
            synthesizer.delegate = self
            self.synthesizer = synthesizer
            let resolved = voice.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: "ja-JP")
            for chunk in chunks {
                let utterance = AVSpeechUtterance(string: chunk)
                utterance.voice = resolved
                queued += 1
                synthesizer.speak(utterance)   // 続けて呼ばれたら、順に読む
            }
            updateSpeaking()
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            _ = synthesizer?.stopSpeaking(at: .immediate)
            queued = 0
            updateSpeaking()
        }
    }

    // MARK: AVSpeechSynthesizerDelegate（メインスレッド）

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished() }

    private func finished() {
        DispatchQueue.main.async { [self] in
            queued = max(0, queued - 1)
            updateSpeaking()
        }
    }

    /// 読んでいる間だけ、Esc を見張る。状態が変わったときだけ、知らせる。
    private func updateSpeaking() {
        let speaking = queued > 0
        lock.lock(); let changed = speakingFlag != speaking; speakingFlag = speaking; lock.unlock()
        guard changed else { return }
        if speaking {
            // 他のアプリが前のとき（グローバル。Esc を、横取りしない）と、自分のウィンドウが前のとき（ローカル）。止めた Esc は、ウィンドウを閉じない（もう一度で、閉じる）
            if AXIsProcessTrusted() {
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { self?.stop() }
                }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.isSpeaking else { return event }
                self.stop()
                return nil
            }
        } else {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil; localMonitor = nil
        }
        MainActor.assumeIsolated { for observer in observers { observer(speaking) } }
    }
}

/// 読み上げる（確認の問いかけ・結果）。終わるまで待たない。取りやめたときは、止める（`SaySpeaker`）。
func say(_ text: String) { SaySpeaker.shared.say(text) }
