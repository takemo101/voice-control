import AVFoundation
import Foundation
import VCCore
import VCSkill
import VCSpeech

/// システム音声（相手の音声）の文字起こし（SPEC F80）：Mac から出ている音を、文にして、記録（メモリ）に足し、整理（F79。設定 `tidySystem`）して、履歴（設定 `history`）に残す。
/// **自分の声は、ここではなく、音声入力**（別のキー・別の設定。`DictationFlow`）。
/// **文字起こし専用**：文は、画面に出し、履歴に残すだけ。スキル・会話・コマンドへは、回さない（N2）。音声は、残さない。
/// 失敗（許可がない・モデルがない）は、`state` に出す（黙って、何もしない、をしない）。
@MainActor final class TranscriptSession: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var log = TranscriptLog()
    /// 履歴に書けなかったなどの、知らせ（記録は、続ける）。
    @Published private(set) var notice: String?

    private var capture: SystemAudioCapture?
    private var transcriber: SegmentTranscriber?
    private var reader: Task<Void, Never>?
    private var tidyTail: Task<Void, Never>?
    private var settings = Settings()
    private var engine: Engine = .apple

    var isActive: Bool { state == .starting || state == .running }

    /// 始める（利用者の操作の中で、呼ぶ：画面収録の許可の確認が、出うる）。`settings`・`engine` は、動いている間、使う。
    func start(settings: Settings, engine: Engine) async {
        guard !isActive else { return }
        state = .starting
        notice = nil
        self.settings = settings
        self.engine = engine
        let language = (try? settings.recognitionLanguage.get()) ?? .ja
        let transcriber = SegmentTranscriber(locale: Locale(identifier: language.resolved.bcp47)) { [weak self] update in Task { @MainActor in self?.apply(update) } }
        do {
            try await transcriber.start()
            let capture = SystemAudioCapture()
            let target: SystemAudioTarget = (settings.transcribeApps ?? []).isEmpty ? .allApps : .apps(settings.transcribeApps ?? [])
            let audio: AsyncStream<AVAudioPCMBuffer>
            do { audio = try await capture.start(target: target) } catch { await transcriber.finish(); throw error }
            self.capture = capture
            self.transcriber = transcriber
            reader = Task.detached { for await buffer in audio { transcriber.feed(buffer) } }
            state = .running
        } catch {
            state = .failed("\(error)")
        }
    }

    /// 止める：残りの認識を、確定させ、整理の最後まで、待つ。
    func stop() async {
        guard isActive else { return }
        await capture?.stop()
        capture = nil
        await reader?.value
        reader = nil
        await transcriber?.finish()
        transcriber = nil
        await tidyTail?.value
        state = .idle
    }

    func clear() { log = TranscriptLog() }

    // MARK: 文の処理

    private func apply(_ update: SegmentTranscriber.Update) {
        guard let entry = log.apply(update) else { return }
        // 整理（F79。オンのとき）→ 履歴（F64。オンのとき）。順に処理する（前の文の整理が終わってから）
        let previous = tidyTail
        tidyTail = Task { [weak self] in
            await previous?.value
            await self?.finalize(entry)
        }
    }

    /// システム音声の文を、整理するか（設定 `tidySystem`。自分の声の整理 `tidy` とは、別）。
    nonisolated static func tidies(settings: Settings) -> Bool { settings.tidySystem ?? false }

    private func finalize(_ entry: TranscriptLog.Entry) async {
        var text = entry.text, raw: String?
        if Self.tidies(settings: settings) {
            let result = await Tidier(engine: engine, instructionsSetting: settings.tidyInstructions).tidy(entry.text)
            if case let .tidied(tidied) = result {
                log.replace(id: entry.id, tidied: tidied)
                raw = entry.text; text = tidied
            }
        }
        guard settings.history ?? false else { return }
        do { _ = try DictationHistory().append(text, days: DictationHistory.days(setting: settings.historyDays), source: .others, raw: raw, date: entry.date) }
        catch { notice = tr("履歴を書けませんでした：\(error)") }
    }
}
