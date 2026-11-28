import AVFoundation
import Foundation
import VCCore
import VCSkill
import VCSpeech

/// 会議の文字起こし（SPEC F80・F81・F82）：Mac から出ている音（相手）を、文にして、記録（メモリ）に足し、整理（F79。設定 `tidySystem`）して、履歴（設定 `history`）に残す。
/// 設定 `transcribeMic` がオンなら、**自分のマイクも、常時、文字にして、同じ記録に並べる**（整理は、自分の声の設定 `tidy`）。マイクの失敗は、システム音声を止めない（`micState` に出す）。
/// キーを押して話す「音声入力（マイク）」（`DictationFlow`）は、別の機能：ここには、出ない。
/// **会議**＝最初に始めてから、「新しい会議」（`clear`）まで。**止めて、また始めたら、同じ会議の続き**。止めたとき、設定があれば、要約して、Markdown を書く（`wrapUp`）。
/// **文字起こし専用**：文は、画面に出し、履歴・設定したフォルダに残すだけ。スキル・会話・コマンドへは、回さない（N2）。音声は、残さない。
/// 失敗（許可がない・モデルがない・書けない）は、状態・知らせに出す（黙って、何もしない、をしない）。
@MainActor final class TranscriptSession: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    /// 要約の状態（画面の「要約」のカード）。
    enum SummaryState: Equatable {
        case idle
        /// 要約している（テーマがあれば、そのテーマ）。
        case working(String?)
        case failed(String)
        /// テーマに合う話が、なかった。
        case nothing(String?)
    }

    /// 止めたあとの、後始末（自動の要約・Markdown の保存）の状態。
    enum WrapUp: Equatable {
        case idle
        case working(String)
        case saved(URL)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var log = TranscriptLog()
    /// 履歴に書けなかったなどの、知らせ（記録は、続ける）。
    @Published private(set) var notice: String?
    /// 取り込みを始めた時刻（動いている間だけ）。
    @Published private(set) var startedAt: Date?
    /// 自分のマイクの状態（設定 `transcribeMic` がオフなら、idle のまま）。
    @Published private(set) var micState = State.idle
    /// 作った要約（会議全体は、最新の 1 つ・ピックアップは、全部）。
    @Published private(set) var summaries: [MeetingSummary] = []
    @Published private(set) var summaryState = SummaryState.idle
    @Published private(set) var wrapUp = WrapUp.idle

    private var capture: SystemAudioCapture?
    private var transcriber: SegmentTranscriber?
    private var reader: Task<Void, Never>?
    private var mic: MicStream?
    private var micTranscriber: SegmentTranscriber?
    private var micReader: Task<Void, Never>?
    private var tidyTail: Task<Void, Never>?
    private var wrapUpTask: Task<Void, Never>?
    private var settings = Settings()
    private var engine: Engine = .apple
    /// その話し手の認識の「0 秒」が、会議の始まりから、何秒あとか（止めて、また始めたとき、ずれる）。
    private var origins: [HistoryEntry.Source: TimeInterval] = [:]
    /// この会議が、すでに書いたファイル（同じ会議は、同じファイルを書き直す）。
    private var meetingFile: URL?
    /// 最後に止めた時刻（Markdown の「終わり」）。
    private var endedAt: Date?

    var isActive: Bool { state == .starting || state == .running }

    // MARK: 始める・止める

    /// 始める（利用者の操作の中で、呼ぶ：画面収録の許可の確認が、出うる）。`settings`・`engine` は、動いている間、使う。
    func start(settings: Settings, engine: Engine, chip: String? = nil) async {
        guard !isActive else { return }
        await wrapUpTask?.value   // 前の止めたあとの後始末が、終わってから
        state = .starting
        notice = nil
        self.settings = settings
        self.engine = engine
        let began = Date()
        log.begin(at: began)
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
            origins[.others] = Date().timeIntervalSince(log.meetingStart ?? began)
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
            origins[.me] = Date().timeIntervalSince(log.meetingStart ?? Date())
            micReader = Task.detached { for await buffer in audio { transcriber.feed(buffer); HUD.shared.pushTranscript(level: AudioLevel.level(of: buffer), text: nil) } }
            micState = .running
        } catch {
            micState = .failed("\(error)")
        }
    }

    /// 止める：残りの認識を、確定させ、整理の最後まで、待つ。そのあと、**後始末**（自動の要約・Markdown の保存）は、別に走る（止めたことは、すぐ、返る）。
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
        endedAt = Date()
        state = .idle
        let settings = self.settings, engine = self.engine
        if !log.entries.isEmpty, (settings.summaryAuto ?? false) || !(settings.meetingFolder ?? "").trimmingCharacters(in: .whitespaces).isEmpty { wrapUp = .working(tr("会議の記録を、まとめています…")) }   // 後始末が、ある
        wrapUpTask = Task { [weak self] in await self?.finishMeeting(settings: settings, engine: engine) }
    }

    /// 新しい会議にする（画面の記録・要約・保存先の記憶を、消す。履歴・書いたファイルは、残る）。
    func clear() {
        log = TranscriptLog()
        summaries = []
        summaryState = .idle
        wrapUp = .idle
        meetingFile = nil
        endedAt = nil
        origins = [:]
    }

    /// 見た目の確認用（`vc transcript-preview --demo`）：作り物の記録を、差し込む（取り込みは、しない）。
    func seed(_ log: TranscriptLog, summaries: [MeetingSummary] = []) { self.log = log; self.summaries = summaries }

    // MARK: 後始末（止めたとき）

    /// 止めたとき：設定があれば、会議を要約して（`summaryAuto`）、Markdown を書く（`meetingFolder`）。**どちらも、失敗しても、文字起こしは、残る**。
    private func finishMeeting(settings: Settings, engine: Engine) async {
        guard !log.entries.isEmpty else { wrapUp = .idle; return }
        if settings.summaryAuto ?? false {
            wrapUp = .working(tr("要約を作っています…"))
            await summarize(.all, entryIDs: nil, settings: settings, engine: engine)
        }
        await saveToFolder(settings: settings, announce: true)
        if case .working = wrapUp { wrapUp = .idle }
    }

    /// 設定のフォルダへ、会議の Markdown を書く（なければ、何もしない）。同じ会議は、同じファイルを書き直す。
    private func saveToFolder(settings: Settings, announce: Bool) async {
        guard let path = settings.meetingFolder?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return }
        wrapUp = .working(tr("会議の記録を書いています…"))
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let document = document()
        do {
            let url = try MeetingWriter.write(document.markdown(), fileName: document.fileName, in: folder, existing: meetingFile)
            meetingFile = url
            wrapUp = .saved(url)
            if announce { HUD.shared.show(HUDContent(phase: .info, title: tr("会議の記録を保存しました"), hint: url.lastPathComponent), hideAfter: 3) }
        } catch {
            wrapUp = .failed("\(error)")
            if announce { HUD.shared.show(HUDContent(phase: .failure, title: tr("会議の記録を保存できません"), hint: "\(error)"), hideAfter: 5) }
        }
    }

    /// いまの会議の文書（Markdown・字幕の元）。
    func document() -> MeetingDocument {
        MeetingDocument(start: log.meetingStart ?? Date(), end: endedAt ?? Date(), entries: log.entries, summaries: summaries)
    }

    // MARK: 要約（F82）

    /// 要約を作る。`entryIDs` があれば、その発話だけ（選んだ発話）。`scope` が `.focus` なら、そのテーマに絞る。
    /// 結果は、`summaries`（会議全体は、前のものを置き換える）。失敗・該当なしは、`summaryState`。**文字起こしは、止めない**。
    func summarize(_ scope: MeetingSummary.Scope, entryIDs: Set<UUID>?, settings: Settings, engine: Engine) async {
        if case .working = summaryState { return }
        let source = log.entries.filter { entryIDs?.contains($0.id) ?? true }
        let lines = source.map { SummaryLine(speaker: TranscriptLog.name($0.speaker), text: $0.text) }
        var focus: String?
        if case let .focus(topic) = scope { focus = topic }
        summaryState = .working(focus)
        let result = await Summarizer(engine: engine, instructionsSetting: settings.summaryInstructions).summarize(lines, focus: focus)
        switch result {
        case let .summary(text):
            if scope == .all { summaries.removeAll { $0.scope == .all } }
            summaries.append(MeetingSummary(date: Date(), scope: scope, text: text))
            summaryState = .idle
        case .nothingRelevant:
            summaryState = .nothing(focus)
        case let .failed(why):
            summaryState = .failed("\(why)")
        }
        // 止めたあと、すでに書いたファイルがあれば、要約を入れて、書き直す
        if !isActive, meetingFile != nil { await saveToFolder(settings: settings, announce: false) }
    }

    func dismissSummaryState() { summaryState = .idle }

    func removeSummary(id: UUID) { summaries.removeAll { $0.id == id } }

    // MARK: 1 行削除（F81）

    /// 発話を、1 件、消す（画面の記録と、履歴〔あれば〕から）。
    func delete(entryID: UUID) {
        log.remove(id: entryID)
        if settings.history ?? false { do { try DictationHistory().delete(id: entryID) } catch { notice = tr("履歴から消せませんでした：\(error)") } }
        if !isActive, meetingFile != nil { Task { await saveToFolder(settings: settings, announce: false) } }   // 書いたファイルからも、消す
    }

    // MARK: 文の処理

    private func apply(_ update: SegmentTranscriber.Update, speaker: HistoryEntry.Source) {
        let entry = log.apply(update, speaker: speaker, origin: origins[speaker] ?? 0)
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
        // 履歴の id は、画面の発話と、同じ（1 行削除が、履歴からも消せる）。消されたあとなら、書かない
        guard log.entries.contains(where: { $0.id == entry.id }) else { return }
        do { _ = try DictationHistory().append(text, days: DictationHistory.days(setting: settings.historyDays), source: entry.speaker, raw: raw, date: entry.date, id: entry.id) }
        catch { notice = tr("履歴を書けませんでした：\(error)") }
    }
}
