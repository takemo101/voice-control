import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, keys, voice, models, skills
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keys: return "キー"
        case .voice: return "音声"
        case .models: return "モデル"
        case .skills: return "スキル"
        case .general: return "一般"
        }
    }
    var symbol: String {
        switch self {
        case .keys: return "keyboard"
        case .voice: return "waveform"
        case .models: return "cpu"
        case .skills: return "puzzlepiece.extension"
        case .general: return "gearshape"
        }
    }
}

/// モデルのダウンロードの状態（`ModelStore`。再開・SHA-256 の検証つき）。
enum DownloadState: Equatable {
    case idle
    case downloading(file: String, fraction: Double)
    case failed(String)
}

/// 設定ウィンドウの状態。設定ファイル（`~/.voice-control/settings.json`）を読み書きする（CLI の `vc` と同じファイル）。**変えた設定は、すぐ保存する**。声の入力は、起動のときに設定を読むので、**反映には、再起動が要る**（`needsRestart`）。
@MainActor final class SettingsModel: ObservableObject {
    @Published private(set) var settings: Settings
    /// 設定ファイルを読めない・書けない理由（読めないファイルは、上書きしない）。
    @Published private(set) var problem: String?
    @Published private(set) var needsRestart = false
    @Published var page: SettingsPage = .general
    /// キー欄の入力中の文字と、その問題。
    @Published var keyDrafts: [KeyKind: String] = [:]
    @Published private(set) var keyProblems: [KeyKind: String] = [:]
    @Published var engineKind: SettingsRules.EngineKind = .apple
    @Published var engineRest = ""
    @Published private(set) var engineProblem: String?
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published var fillersText = ""
    /// 許可の状態などを、画面を開くたびに読み直すための印。
    @Published private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    /// キーを記録しているところ（「クリックして、キーを押す」）。
    @Published private(set) var recording: KeyKind?
    @Published private(set) var recordingHint: String?
    /// ログイン時の起動を変えられなかった理由。
    @Published private(set) var loginMessage: String?
    private var recorder = KeyRecorder()
    private var monitor: Any?

    init() {
        let loaded = Settings.loadOrDefault()
        settings = loaded.settings
        problem = loaded.problem?.description
        syncDrafts()
    }

    /// ファイルから読み直す（ウィンドウを開くとき）。
    func reload() {
        let loaded = Settings.loadOrDefault()
        settings = loaded.settings
        problem = loaded.problem?.description
        syncDrafts()
        revision += 1
    }

    private func syncDrafts() {
        for kind in KeyKind.allCases { keyDrafts[kind] = settings[keyPath: kind.keyPath] ?? "" }
        keyProblems = [:]
        let split = SettingsRules.splitEngine(settings.engine)
        engineKind = split.kind
        engineRest = split.rest
        engineProblem = nil
        fillersText = (settings.fillers ?? []).joined(separator: "\n")
    }

    /// 設定を変えて、保存する。書けなければ、理由を出して、変えない。`restart`：声の入力の起動のときに読む設定か。
    func update(restart: Bool = true, _ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        do {
            try next.save()
            settings = next
            problem = nil
            if restart { needsRestart = true }
        } catch {
            problem = "\(error)"
        }
    }

    // MARK: キー

    func setDraft(_ kind: KeyKind, _ text: String) {
        keyDrafts[kind] = text
        keyProblems[kind] = SettingsRules.keyProblem(kind, text: text, in: settings)
    }

    /// 入力中のキーを、問題がなければ、保存する（空なら、外す。声で頼むキーは、既定に戻る）。
    func commitKey(_ kind: KeyKind) {
        let text = (keyDrafts[kind] ?? "").trimmingCharacters(in: .whitespaces)
        if let why = SettingsRules.keyProblem(kind, text: text, in: settings) { keyProblems[kind] = why; return }
        keyProblems[kind] = nil
        update { $0[keyPath: kind.keyPath] = text.isEmpty ? nil : text }
    }

    func setLoginItem(_ on: Bool) {
        loginMessage = AppActions.setLoginItem(on)
        reload()
    }

    // MARK: キーの記録

    func startRecording(_ kind: KeyKind) {
        stopRecording()
        recording = kind
        recordingHint = nil
        recorder = KeyRecorder()
        keyProblems[kind] = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil   // 記録中の入力は、ほかへ渡さない
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        recordingHint = nil
    }

    private func handle(_ event: NSEvent) {
        guard let kind = recording else { return }
        let input: KeyRecorder.Input
        let flags = event.modifierFlags
        switch event.type {
        case .flagsChanged:
            guard let info = HotKeySpec.modifier(forCode: event.keyCode) else { return }
            let flag: NSEvent.ModifierFlags = [.command: .command, .shift: .shift, .option: .option, .control: .control][info.modifier]!
            input = .modifier(code: event.keyCode, down: flags.contains(flag))
        case .keyDown:
            if event.isARepeat { return }
            var mods: Set<HotKeySpec.Modifier> = []
            if flags.contains(.control) { mods.insert(.control) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.command) { mods.insert(.command) }
            input = .key(code: event.keyCode, modifiers: mods)
        default: return
        }
        switch recorder.handle(input) {
        case .waiting: break
        case .cancelled: stopRecording()
        case let .rejected(reason): recordingHint = reason
        case let .recorded(text):
            stopRecording()
            setDraft(kind, text)
            commitKey(kind)
        }
    }

    // MARK: エンジン

    func setEngine(kind: SettingsRules.EngineKind, rest: String) {
        engineKind = kind
        engineRest = rest
        engineProblem = SettingsRules.engineProblem(kind: kind, rest: rest)
        guard engineProblem == nil else { return }
        let text = SettingsRules.engineText(kind: kind, rest: rest)
        update { $0.engine = text == "apple" ? nil : text }
    }

    // MARK: 音声認識・モデル

    var sttChoices: [(id: String, title: String)] {
        [("apple", "Apple の SpeechTranscriber（既定）")] + SpeechModelCatalog.all.map { ($0.id, "\($0.name)" + (isInstalled($0.spec) ? "" : "（未取得）")) }
    }

    func setSTT(_ id: String) {
        if id != "apple", let model = SpeechModelCatalog.all.first(where: { $0.id == id }), !isInstalled(model.spec) {
            downloads[id] = .failed("先に、取得してください")
            return
        }
        update { $0.stt = id == "apple" ? nil : id }
    }

    func isInstalled(_ spec: ModelSpec) -> Bool { ModelStore.isInstalled(spec, in: ModelStore.defaultDirectory(for: spec)) }

    func download(id: String, spec: ModelSpec) {
        guard tasks[id] == nil else { return }
        downloads[id] = .downloading(file: "", fraction: 0)
        tasks[id] = Task { [weak self] in
            do {
                try await ModelStore.download(spec, to: ModelStore.defaultDirectory(for: spec)) { progress in
                    let fraction = progress.total > 0 ? Double(progress.received) / Double(progress.total) : 0
                    Task { @MainActor in self?.downloads[id] = .downloading(file: progress.file, fraction: fraction) }
                }
                self?.downloads[id] = .idle
            } catch {
                self?.downloads[id] = .failed("\(error)")
            }
            self?.tasks[id] = nil
            self?.revision += 1
        }
    }

    func deleteSpeechModel(id: String, spec: ModelSpec) {
        do { try FileManager.default.removeItem(at: ModelStore.defaultDirectory(for: spec)) } catch { downloads[id] = .failed("消せませんでした: \(error.localizedDescription)") }
        if settings.stt == id { update { $0.stt = nil } }
        revision += 1
    }

    // MARK: 音声

    func saveFillers() {
        let lines = fillersText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        update { $0.fillers = lines.isEmpty ? nil : lines }
    }

    func resetFillers() {
        update { $0.fillers = nil }
        fillersText = ""
    }

    // MARK: スキル

    func loadedSkills() -> SkillStore.Loaded { SkillStore.loadAll(projectRoot: VoiceControlHome.launchDirectory, settings: settings) }

    func setSkill(_ name: String, enabled: Bool) {
        update(restart: false) { $0.setEnabled(name, enabled) }   // スキルは、発話のたびに読み直す：再起動は要らない
    }
}
