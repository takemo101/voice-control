import AVFoundation
import Foundation
import VCCore
import VCSkill
import VCSpeech

/// 文字起こし（SPEC F80）：**相手の音声（システム音声）と自分の声（マイク）は、別々の経路**。それぞれ、自分の開始・停止・状態・ショートカットを持ち、片方だけ・両方を、動かせる（片方を止めても、もう片方は続く）。
/// 文にして、記録（メモリ・両方が時系列に並ぶ）に足し、整理（F79。相手と自分は、別々の設定）して、履歴（設定 `history`）に残す。
/// **文字起こし専用**：文は、画面に出し、履歴に残すだけ。スキル・会話・コマンドへは、回さない（N2）。音声は、残さない。
/// 失敗（許可がない・モデルがない）は、その経路の `states` に出す（黙って、何もしない、をしない）。
@MainActor final class TranscriptSession: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    /// 経路（相手＝システム音声・自分＝マイク）ごとの状態。
    @Published private(set) var states: [HistoryEntry.Source: State] = [.others: .idle, .me: .idle]
    @Published private(set) var log = TranscriptLog()
    /// 履歴に書けなかったなどの、知らせ（記録は、続ける）。
    @Published private(set) var notice: String?

    /// 動いている 1 つの経路：認識・音の読み取り・取り込みを止める手続き。
    private struct Channel {
        let transcriber: SegmentTranscriber
        let reader: Task<Void, Never>
        let stopSource: () async -> Void
    }

    private var channels: [HistoryEntry.Source: Channel] = [:]
    private var tidyTail: Task<Void, Never>?
    private var settings = Settings()
    private var engine: Engine = .apple

    func state(_ source: HistoryEntry.Source) -> State { states[source] ?? .idle }
    func isActive(_ source: HistoryEntry.Source) -> Bool { state(source) == .starting || state(source) == .running }
    var isAnyActive: Bool { isActive(.others) || isActive(.me) }

    /// その経路を始める（利用者の操作の中で、呼ぶ：画面収録・マイクの許可の確認が、出うる）。`settings`・`engine` は、動いている間、使う。
    func start(_ source: HistoryEntry.Source, settings: Settings, engine: Engine) async {
        guard !isActive(source) else { return }
        states[source] = .starting
        notice = nil
        self.settings = settings
        self.engine = engine
        let language = (try? settings.recognitionLanguage.get()) ?? .ja
        let transcriber = SegmentTranscriber(locale: Locale(identifier: language.resolved.bcp47)) { [weak self] update in Task { @MainActor in self?.apply(update, speaker: source) } }
        do {
            try await transcriber.start()
            switch source {
            case .others:
                let capture = SystemAudioCapture()
                let target: SystemAudioTarget = (settings.transcribeApps ?? []).isEmpty ? .allApps : .apps(settings.transcribeApps ?? [])
                let audio: AsyncStream<AVAudioPCMBuffer>
                do { audio = try await capture.start(target: target) } catch { await transcriber.finish(); throw error }
                channels[source] = Channel(transcriber: transcriber, reader: Task.detached { for await buffer in audio { transcriber.feed(buffer) } }, stopSource: { await capture.stop() })
            case .me:
                let mic = MicStream()
                let audio: AsyncStream<AVAudioPCMBuffer>
                do { audio = try mic.start() } catch { await transcriber.finish(); throw error }
                channels[source] = Channel(transcriber: transcriber, reader: Task.detached { for await buffer in audio { transcriber.feed(buffer) } }, stopSource: { mic.stop() })
            }
            states[source] = .running
        } catch {
            states[source] = .failed("\(error)")
        }
    }

    /// その経路を止める：残りの認識を、確定させ、整理の最後まで、待つ。もう片方は、続ける。
    func stop(_ source: HistoryEntry.Source) async {
        guard isActive(source), let channel = channels.removeValue(forKey: source) else { states[source] = .idle; return }
        await channel.stopSource()
        await channel.reader.value
        await channel.transcriber.finish()
        await tidyTail?.value
        states[source] = .idle
    }

    func stopAll() async {
        await stop(.others)
        await stop(.me)
    }

    func clear() { log = TranscriptLog() }

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
