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
    /// 取り込みを始めた時刻（動いている間だけ）。
    @Published private(set) var startedAt: Date?
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
    func start(settings: Settings, engine: Engine, chip: String? = nil) async {
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
            // 音量は、上のパネルの波形へ（音声入力と同じカプセル。文字は、確定前・確定後を、そこへ出す）
            reader = Task.detached { for await buffer in audio { transcriber.feed(buffer); HUD.shared.pushTranscript(level: AudioLevel.level(of: buffer), text: nil) } }
            var content = HUDContent(phase: .recording, title: tr("音声入力（システム）"), hint: tr("相手の音声を、文字にしています"), chip: chip)
            content.captionSlot = true
            HUD.shared.beginTranscript(content)
            startedAt = Date()
            state = .running
        } catch {
            HUD.shared.endTranscript()
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
        HUD.shared.endTranscript()
        await tidyTail?.value
        startedAt = nil
        state = .idle
    }

    func clear() { log = TranscriptLog() }

    /// 見た目の確認用（`vc transcript-preview --demo`）：作り物の記録を、差し込む（取り込みは、しない）。
    func seed(_ log: TranscriptLog) { self.log = log }

    // MARK: 文の処理

    private func apply(_ update: SegmentTranscriber.Update) {
        let entry = log.apply(update)
        // 上のパネルの文字：直前に確定した文は濃く・いま聞こえている文は薄く
        HUD.shared.pushTranscript(level: nil, text: LiveCaptionText(confirmed: log.entries.last?.text ?? "", tentative: log.tentative ?? ""))
        guard let entry else { return }
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
