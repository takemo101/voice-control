import AppKit
import AVFoundation
import Foundation
import VCSpeech

/// 読み上げの種類。**会話のウィンドウは、会話の答えの読み上げだけに反応する**（スキルの結果・確認の問いかけの読み上げでは、「読み上げ中」を出さない）。
enum SpeechChannel: Sendable {
    /// 確認の問いかけ・スキルの結果・声の見本。
    case notice
    /// 会話の答え。
    case conversation
}

/// 読み上げ（確認の問いかけ・結果・会話の答え）。**入っている日本語の声のうち、品質がいちばん高いもの**を使う（`SpeechVoice`。利用者が決めた声があれば、それ）。
/// `AVSpeechSynthesizer` は、メインスレッドで使う（アプリは、メインのイベントのループが回っている）。取りやめたときは、止める。
/// **読んでいる間は、いつでも止められる**：Esc（読んでいる間だけ、キーを見張る。**Esc を、横取りしない**：ほかのアプリにも届く。アクセシビリティの許可があるとき。自分のウィンドウが前なら、そこでも）・ウィンドウの「読み上げを止める」・メニュー・トリガーを押す（録音が始まるとき）。
/// 読んでいる発話は、**種類（`SpeechChannel`）つきで覚える**：種類ごとに、「読んでいるか」を知らせる（`observe`）。止めたあとに、すぐ読み始めても、止めた発話の「終わり」の知らせが、新しい発話を、巻き込まない（発話ごとに覚える）。
/// `@unchecked Sendable` の理由：`synthesizer`・`pending`・監視は、メインスレッドだけで触る。`preferred`・`speakingFlags` は、`lock` で守る。
final class SaySpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = SaySpeaker()
    private let lock = NSLock()
    private var preferredVoice: String?
    private var speakingFlags: [SpeechChannel: Bool] = [:]
    private var synthesizer: AVSpeechSynthesizer?                  // メインスレッドだけ
    private var pending: [ObjectIdentifier: SpeechChannel] = [:]   // メインスレッドだけ：読む予定・読み中の発話
    private var globalMonitor: Any?                                // メインスレッドだけ
    private var localMonitor: Any?
    private struct Observer { let channel: SpeechChannel?; let handler: @MainActor (Bool) -> Void; var last: Bool }
    private var observers: [Observer] = []                         // メインスレッドだけ

    /// 使う声（識別子か名前。なければ、自動）。聞き始める前に、決める。
    func prefer(_ voice: String?) { lock.lock(); preferredVoice = voice; lock.unlock() }

    /// いま使う声。
    func currentVoice() -> SpeechVoice.Info? {
        lock.lock(); let preferred = preferredVoice; lock.unlock()
        return SpeechVoice.resolve(preferred: preferred, voices: SpeechVoice.installed())
    }

    /// いま、読んでいるか（どのスレッドからでも）。`channel` を渡すと、その種類だけ。
    func isSpeaking(_ channel: SpeechChannel? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let channel else { return speakingFlags.values.contains(true) }
        return speakingFlags[channel] == true
    }

    /// 読み始め・読み終わり（止めたときも）で呼ぶ（メインスレッド）。`channel` を渡すと、その種類だけ見る（なければ、すべて）。
    @MainActor func observe(_ channel: SpeechChannel? = nil, _ handler: @escaping @MainActor (Bool) -> Void) {
        observers.append(Observer(channel: channel, handler: handler, last: isSpeaking(channel)))
    }

    func say(_ text: String, channel: SpeechChannel = .notice) { say(chunks: [text], channel: channel) }

    /// 塊ごとに、続けて読む（止めたら、残りも、読まない）。
    func say(chunks: [String], channel: SpeechChannel = .notice) {
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
                pending[ObjectIdentifier(utterance)] = channel
                synthesizer.speak(utterance)   // 続けて呼ばれたら、順に読む
            }
            updateSpeaking()
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            pending.removeAll()   // 先に忘れる（止めたあとの「終わり」の知らせが、あとから読み始めた発話を、巻き込まない）
            _ = synthesizer?.stopSpeaking(at: .immediate)
            updateSpeaking()
        }
    }

    // MARK: AVSpeechSynthesizerDelegate（メインスレッド）

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished(utterance) }

    private func finished(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [self] in
            guard pending.removeValue(forKey: id) != nil else { return }
            updateSpeaking()
        }
    }

    /// 状態が変わった種類だけ、知らせる。読んでいる間だけ、Esc を見張る。
    private func updateSpeaking() {
        let channels = Set(pending.values)
        lock.lock()
        let wasAny = speakingFlags.values.contains(true)
        for channel in [SpeechChannel.notice, .conversation] { speakingFlags[channel] = channels.contains(channel) }
        lock.unlock()
        let anyNow = !channels.isEmpty
        if anyNow != wasAny { anyNow ? startWatchingEscape() : stopWatchingEscape() }
        for index in observers.indices {
            let speaking = observers[index].channel.map(channels.contains) ?? anyNow
            guard speaking != observers[index].last else { continue }
            observers[index].last = speaking
            let handler = observers[index].handler
            MainActor.assumeIsolated { handler(speaking) }
        }
    }

    private func startWatchingEscape() {
        // 他のアプリが前のとき（グローバル。Esc を、横取りしない）と、自分のウィンドウが前のとき（ローカル）。止めた Esc は、ウィンドウを閉じない（もう一度で、閉じる）
        if AXIsProcessTrusted() {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.stop() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.isSpeaking() else { return event }
            self.stop()
            return nil
        }
    }

    private func stopWatchingEscape() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
    }
}

/// 読み上げる（確認の問いかけ・結果）。終わるまで待たない。取りやめたときは、止める（`SaySpeaker`）。
func say(_ text: String) { SaySpeaker.shared.say(text) }
