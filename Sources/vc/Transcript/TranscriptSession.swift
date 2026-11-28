import AVFoundation
import Foundation
import VCCore
import VCSkill
import VCSpeech

/// システム音声（相手の音声）の文字起こし（SPEC F80）：Mac から出ている音を、文にして、記録（メモリ）に足し、整理（F79。設定 `tidySystem`）して、履歴（設定 `history`）に残す。
/// 設定 `transcribeMic` がオンなら、**自分のマイクも、常時、文字にして、同じ記録に並べる**（整理は、自分の声の設定 `tidy`）。マイクの失敗は、システム音声を止めない（`micState` に出す）。
/// キーを押して話す「音声入力（マイク）」（`DictationFlow`）は、別の機能：ここには、出ない。
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
    /// 取り込みを始めた時刻（動いている間だけ）。
    @Published private(set) var startedAt: Date?
    /// 履歴に書けなかったなどの、知らせ（記録は、続ける）。
    @Published private(set) var notice: String?

    /// 自分のマイクの状態（設定 `transcribeMic` がオフなら、idle のまま）。
    @Published private(set) var micState = State.idle

    private var capture: SystemAudioCapture?
    private var transcriber: SegmentTranscriber?
    private var reader: Task<Void, Never>?
    private var mic: MicStream?
    private var micTranscriber: SegmentTranscriber?
    private var micReader: Task<Void, Never>?
    private var tidyTail: Task<Void, Never>?
    private var settings = Settings()
    private var engine: Engine = .apple

    var isActive: Bool { state == .starting || state == .running }

    /// 始める（利用者の操作の中で、呼ぶ：画面収録の許可の確認が、出うる）。`settings`・`engine` は、動いている間、使う。
    func start(settings: Settings, engine: Engine, chip: String? = nil) async {
        guard !isActive else { return }
        state = .starting
        notice = nil
        self.settings = settings
        self.engine = engine
        let language = (try? settings.recognitionLanguage.get()) ?? .ja
        let transcriber = SegmentTranscriber(locale: Locale(identifier: language.resolved.bcp47)) { [weak self] update in Task { @MainActor in self?.apply(update, speaker: .others) } }
        do {
            try await transcriber.start()
            let capture = SystemAudioCapture()
            let target: SystemAudioTarget = (settings.transcribeApps ?? []).isEmpty ? .allApps : .apps(settings.transcribeApps ?? [])
            let audio: AsyncStream<AVAudioPCMBuffer>
            do { audio = try await capture.start(target: target) } catch { await transcriber.finish(); throw error }
            self.capture = capture
            self.transcriber = transcriber
            // 音量は、上のパネルの波形へ（音声入力と同じカプセル。文字は、確定前・確定後を、そこへ出す）
            reader = Task.detached { for await buffer in audio { transcriber.feed(buffer); HUD.shared.pushTranscript(level: AudioLevel.level(of: buffer), text: nil) } }
            var content = HUDContent(phase: .recording, title: tr("音声入力（会議）"), hint: tr("会議の音を、文字にしています"), chip: chip)
            content.captionSlot = true
            HUD.shared.beginTranscript(content)
            startedAt = Date()
            state = .running
            if settings.transcribeMic ?? false { await startMic(locale: Locale(identifier: language.resolved.bcp47)) }
        } catch {
            HUD.shared.endTranscript()
            state = .failed("\(error)")
        }
    }

    /// 自分のマイクを、始める（失敗しても、システム音声は、続ける：理由は `micState` に出す）。
    private func startMic(locale: Locale) async {
        micState = .starting
        let transcriber = SegmentTranscriber(locale: locale) { [weak self] update in Task { @MainActor in self?.apply(update, speaker: .me) } }
        do {
            try await transcriber.start()
            let mic = MicStream()
            let audio: AsyncStream<AVAudioPCMBuffer>
            do { audio = try mic.start() } catch { await transcriber.finish(); throw error }
            self.mic = mic
            micTranscriber = transcriber
            micReader = Task.detached { for await buffer in audio { transcriber.feed(buffer); HUD.shared.pushTranscript(level: AudioLevel.level(of: buffer), text: nil) } }
            micState = .running
        } catch {
            micState = .failed("\(error)")
        }
    }

    /// 止める：残りの認識を、確定させ、整理の最後まで、待つ。
    func stop() async {
        guard isActive else { return }
        mic?.stop()
        mic = nil
        await micReader?.value
        micReader = nil
        await micTranscriber?.finish()
        micTranscriber = nil
        if micState != .idle { micState = .idle }
        await capture?.stop()
        capture = nil
        await reader?.value
        reader = nil
        await transcriber?.finish()
        transcriber = nil
        HUD.shared.endTranscript()
        await tidyTail?.value
        startedAt = nil
        state = .idle
    }

    func clear() { log = TranscriptLog() }

    /// 見た目の確認用（`vc transcript-preview --demo`）：作り物の記録を、差し込む（取り込みは、しない）。
    func seed(_ log: TranscriptLog) { self.log = log }

    // MARK: 文の処理

    private func apply(_ update: SegmentTranscriber.Update, speaker: HistoryEntry.Source) {
        let entry = log.apply(update, speaker: speaker)
        // 上のパネルの文字：直前に確定した文は濃く・いま聞こえている文は薄く（いま動いた側）
        HUD.shared.pushTranscript(level: nil, text: LiveCaptionText(confirmed: log.entries.last?.text ?? "", tentative: log.tentative[speaker] ?? ""))
        guard let entry else { return }
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
