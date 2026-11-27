import AVFoundation
import Foundation
import VCCore
import VCSkill
import VCSpeech

/// 文字起こしの 1 回（SPEC F80）：システム音声（相手）と、設定によっては、マイク（自分）を、文にして、記録（メモリ）に足し、整理（F79。相手と自分は、別々の設定）して、履歴（設定 `history`）に残す。
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
    private var mic: MicStream?
    private var transcribers: [SegmentTranscriber] = []
    private var readers: [Task<Void, Never>] = []
    private var tidyTail: Task<Void, Never>?
    private var settings = Settings()
    private var engine: Engine = .apple

    var isActive: Bool { state == .starting || state == .running }

    /// 始める（利用者の操作の中で、呼ぶ：画面収録・マイクの許可の確認が、出うる）。`settings`・`engine` は、この回の間、使う。
    func start(settings: Settings, engine: Engine) async {
        guard !isActive else { return }
        state = .starting
        notice = nil
        self.settings = settings
        self.engine = engine
        let language = (try? settings.recognitionLanguage.get()) ?? .ja
        let locale = Locale(identifier: language.resolved.bcp47)
        do {
            let others = SegmentTranscriber(locale: locale) { [weak self] update in Task { @MainActor in self?.apply(update, speaker: .others) } }
            try await others.start()
            transcribers = [others]
            let capture = SystemAudioCapture()
            let target: SystemAudioTarget = (settings.transcribeApps ?? []).isEmpty ? .allApps : .apps(settings.transcribeApps ?? [])
            let audio = try await capture.start(target: target)
            self.capture = capture
            readers = [Task.detached { for await buffer in audio { others.feed(buffer) } }]
            if settings.transcribeMic ?? false {
                let me = SegmentTranscriber(locale: locale) { [weak self] update in Task { @MainActor in self?.apply(update, speaker: .me) } }
                try await me.start()
                transcribers.append(me)
                let mic = MicStream()
                let micAudio = try mic.start()
                self.mic = mic
                readers.append(Task.detached { for await buffer in micAudio { me.feed(buffer) } })
            }
            state = .running
        } catch {
            await teardown()
            state = .failed("\(error)")
        }
    }

    /// 止める：残りの認識を、確定させ、整理の最後まで、待つ。
    func stop() async {
        guard isActive else { return }
        await teardown()
        await tidyTail?.value
        state = .idle
    }

    func clear() { log = TranscriptLog() }

    private func teardown() async {
        await capture?.stop()
        mic?.stop()
        capture = nil; mic = nil
        for reader in readers { await reader.value }
        readers = []
        for transcriber in transcribers { await transcriber.finish() }
        transcribers = []
    }

    // MARK: 文の処理

    private func apply(_ update: SegmentTranscriber.Update, speaker: HistoryEntry.Source) {
        guard let entry = log.apply(update, speaker: speaker) else { return }
        // 整理（F79。オンのとき）→ 履歴（F64。オンのとき）。順に処理する（前の文の整理が終わってから）
        let previous = tidyTail
        tidyTail = Task { [weak self] in
            await previous?.value
            await self?.finalize(entry)
        }
    }

    /// その話し手の文を、整理するか（設定：相手＝`tidySystem`・自分＝`tidy`。別々に決める）。
    nonisolated static func tidies(_ speaker: HistoryEntry.Source, settings: Settings) -> Bool {
        switch speaker {
        case .others: return settings.tidySystem ?? false
        case .me: return settings.tidy ?? false
        }
    }

    private func finalize(_ entry: TranscriptLog.Entry) async {
        var text = entry.text, raw: String?
        if Self.tidies(entry.speaker, settings: settings) {
            let result = await Tidier(engine: engine, instructionsSetting: settings.tidyInstructions).tidy(entry.text)
            if case let .tidied(tidied) = result {
                log.replace(id: entry.id, tidied: tidied)
                raw = entry.text; text = tidied
            }
        }
        guard settings.history ?? false else { return }
        do { _ = try DictationHistory().append(text, days: DictationHistory.days(setting: settings.historyDays), source: entry.speaker, raw: raw, date: entry.date) }
        catch { notice = tr("履歴を書けませんでした：\(error)") }
    }
}
