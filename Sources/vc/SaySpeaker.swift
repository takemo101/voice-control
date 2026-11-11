import AVFoundation
import Foundation
import VCSpeech

/// 読み上げ（確認の問いかけ・結果）。**入っている日本語の声のうち、品質がいちばん高いもの**を使う（`SpeechVoice`。利用者が決めた声があれば、それ）。
/// `AVSpeechSynthesizer` は、メインスレッドで使う（声で頼む `vc listen --hotkey` は、メインのイベントのループが回っている）。取りやめたときは、止める。
/// `@unchecked Sendable` の理由：`synthesizer` は、メインスレッドだけで触る。`preferred` は、`lock` で守る。
final class SaySpeaker: @unchecked Sendable {
    static let shared = SaySpeaker()
    private let lock = NSLock()
    private var preferredVoice: String?
    private var synthesizer: AVSpeechSynthesizer?   // メインスレッドだけ

    /// 使う声（識別子か名前。なければ、自動）。聞き始める前に、決める。
    func prefer(_ voice: String?) { lock.lock(); preferredVoice = voice; lock.unlock() }

    /// いま使う声。
    func currentVoice() -> SpeechVoice.Info? {
        lock.lock(); let preferred = preferredVoice; lock.unlock()
        return SpeechVoice.resolve(preferred: preferred, voices: SpeechVoice.installed())
    }

    func say(_ text: String) {
        let voice = currentVoice()
        DispatchQueue.main.async { [self] in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: "ja-JP")
            let synthesizer = self.synthesizer ?? AVSpeechSynthesizer()
            self.synthesizer = synthesizer
            synthesizer.speak(utterance)   // 続けて呼ばれたら、順に読む
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in _ = synthesizer?.stopSpeaking(at: .immediate) }
    }
}

/// 読み上げる（確認の問いかけ・結果）。終わるまで待たない。取りやめたときは、止める（`SaySpeaker`）。
func say(_ text: String) { SaySpeaker.shared.say(text) }
