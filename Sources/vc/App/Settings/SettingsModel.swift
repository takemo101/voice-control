import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, keys, voice, chat, models, skills
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keys: return "キー"
        case .voice: return "音声"
        case .chat: return "会話"
        case .models: return "モデル"
        case .skills: return "スキル"
        case .general: return "一般"
        }
    }
    var symbol: String {
        switch self {
        case .keys: return "keyboard"
        case .voice: return "waveform"
        case .chat: return "bubble.left.and.bubble.right.fill"
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
    /// 変えた設定を、声の入力へ反映している様子（アプリが動いているときだけ。再起動は、要らない）。
    enum ApplyState: Equatable { case idle, applying, applied, failed(String) }
    @Published private(set) var applyState = ApplyState.idle
    private var pendingApply = false
    private var runtimeToken: AnyObject?
    /// インストールできるスキル（GitHub から取る。状態は、別の型）。入れたら、スキルの一覧を読み直す。
    lazy var skillCatalog = SkillCatalog(onInstalled: { [weak self] in self?.revision += 1 })
    @Published var page: SettingsPage = .general
    /// キー欄の入力中の文字と、その問題。
    @Published var keyDrafts: [KeyKind: String] = [:]
    @Published private(set) var keyProblems: [KeyKind: String] = [:]
    @Published var engineKind: SettingsRules.EngineKind = .apple
    @Published var engineRest = ""
    @Published private(set) var engineProblem: String?
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published var fillersText = ""
    /// 会話のエージェントごとの、モデルの一覧（取ったもの。メモリだけ）。
    @Published private(set) var modelLists: [String: ModelListState] = [:]
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
        runtimeToken = AppRuntime.shared.observe { [weak self] in MainActor.assumeIsolated { self?.runtimeChanged() } }
    }

    private func runtimeChanged() {
        guard pendingApply else { return }
        switch AppRuntime.shared.state {
        case .starting: applyState = .applying
        case .listening:
            pendingApply = false
            applyState = .applied
            Task { try? await Task.sleep(for: .seconds(3)); if applyState == .applied { applyState = .idle } }
        case let .stopped(reason):
            pendingApply = false
            applyState = .failed(reason)
        }
    }

    /// 反映に失敗したとき、もう一度、反映する。
    func retryApply() {
        pendingApply = AppRuntime.shared.scheduleReload()
        if pendingApply { applyState = .applying }
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
            if restart {
                pendingApply = AppRuntime.shared.scheduleReload()
                if pendingApply { applyState = .applying }
            }
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

    /// 画面の文字の大きさを変える（標準なら、設定から外す）。開いている画面も、すぐ変わる。声の入力の再起動は、要らない。
    func setFontSize(_ size: Int) {
        let clamped = UIScale.clamp(size)
        update(restart: false) { $0.fontSize = clamped == UIScale.standard ? nil : clamped }
        UIScale.shared.reload()
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
        recorder = KeyRecorder(recordsStroke: !kind.isTrigger)
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

    // MARK: ACP アダプター（claude・codex）

    enum AdapterWork: Equatable {
        case working(String)
        case failed(String)
    }

    /// アダプターを入れている最中・失敗（エージェント名 → 状態。メモリだけ）。
    @Published private(set) var adapterWork: [String: AdapterWork] = [:]

    /// 入れる（更新も同じ）。**確認のダイアログ**で、何を・どこへ・どれだけ入れるかを見せて、「入れる」を押したときだけ。
    func installAdapter(_ adapter: ACPAdapter) {
        if case .working = adapterWork[adapter.agent.rawValue] { return }
        guard let source = AdapterSource.directory(for: adapter) else {
            adapterWork[adapter.agent.rawValue] = .failed("同梱の固定ファイル（adapters/\(adapter.directoryName)）が、見つかりません（ビルドしたままのアプリ？）")
            return
        }
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(adapter.agent.rawValue) の ACP アダプターを、入れますか？"
        alert.informativeText = """
        \(adapter.package) \(adapter.version)（\(adapter.license)）を、npm から、入れます。約 \(adapter.approximateSizeMB) MB。

        入れる先：\(ACPAdapterStore.directory(for: adapter).path)
        ・版は固定です（アプリに同梱の lock どおり。すべての部品を SHA-512 で照合し、取得先は npm の公式のレジストリだけ）。
        ・インストール時のスクリプトは、動かしません。あなたの \(adapter.agent.rawValue) の本体を使います（二重に取り込みません）。
        ・これは、第三者のプログラムを、この Mac で動かすことになります（会話のたびに、起動します）。消すときは、ここから「消す」か、そのフォルダを消します。
        ・Node.js（npm）を使います。
        """
        alert.addButton(withTitle: "入れる")
        alert.addButton(withTitle: "やめる")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        adapterWork[adapter.agent.rawValue] = .working("入れています…（数十秒かかることがあります）")
        Task { [weak self] in
            do {
                try await ACPAdapterInstaller.install(adapter, source: source)
                self?.adapterWork[adapter.agent.rawValue] = nil
                self?.adapterChanged()
            } catch {
                self?.adapterWork[adapter.agent.rawValue] = .failed("\(error)")
            }
        }
    }

    /// 消す（アプリが入れたものだけ）。
    func removeAdapter(_ adapter: ACPAdapter) {
        do { try ACPAdapterInstaller.remove(adapter); adapterWork[adapter.agent.rawValue] = nil; adapterChanged() }
        catch { adapterWork[adapter.agent.rawValue] = .failed("\(error)") }
    }

    /// 入れた・消したあと：画面を更新し、答える側を作り直す（会話は、新しくなる。次の質問から、ACP で話す・従来の方式へ戻る）。
    private func adapterChanged() {
        revision += 1
        ChatMode.shared.invalidate()
        _ = AppRuntime.shared.scheduleReload()
    }

    // MARK: 会話のモデル

    enum ModelListState: Equatable {
        case loading
        case loaded(ACPModelListing)
        case failed(String)
    }

    /// エージェントが選べるモデルの一覧を、取る（そのエージェントを、一時的に起動する：質問は送らない）。
    func loadModels(for agent: ChatAgent) {
        if case .loading = modelLists[agent.rawValue] { return }
        modelLists[agent.rawValue] = .loading
        let sandbox = settings.chatSandbox ?? true
        Task { [weak self] in
            do {
                let listing = try await ACPModelCatalog.list(for: agent, sandbox: sandbox)
                self?.modelLists[agent.rawValue] = .loaded(listing)
            } catch {
                self?.modelLists[agent.rawValue] = .failed("\(error)")
            }
        }
    }

    /// 選んだモデル（なければ、エージェントの設定）。
    func chatModel(for agent: ChatAgent) -> String? { settings.chatModels?[agent.rawValue] }

    /// モデルを選ぶ（nil で、エージェントの設定へ戻す）。次の会話から、使う（会話は、新しくなる）。
    func setChatModel(_ id: String?, for agent: ChatAgent) {
        update { settings in
            var models = settings.chatModels ?? [:]
            models[agent.rawValue] = (id?.isEmpty == false) ? id : nil
            settings.chatModels = models.isEmpty ? nil : models
        }
    }

    // MARK: 会話の道具

    var chatToolLevel: ChatToolLevel { settings.chatTools.flatMap(ChatToolLevel.init(rawValue:)) ?? .none }
    var chatFolderPath: String { settings.chatFolder ?? ExternalChatBackend.defaultFolder.path }

    /// 会話のエージェントに開ける道具の段階を決める。**すべて**は、聞き間違い・Web のページの命令で、意図しない操作が起きえるので、確認を出す。
    func setChatTools(_ level: ChatToolLevel) {
        if level == .all {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "すべての道具を、開けますか？"
            let chosen = ChatAgent.parse(settings.chatAgent ?? "apple") ?? .apple
            let apple = chosen == .apple
            let confirms = chosen.speaksACP && (settings.chatAcp ?? true)   // 常駐の接続（ACP）：操作の前に、聞いてくる
            alert.informativeText = apple ? "Apple のモデルが、作業フォルダの中への書き込みと、コマンドの実行まで、できるようになります。\n\n既存ファイルの上書きと、安全でないコマンドは、毎回、確認します。小さなモデルは、聞き間違いや、検索したページの命令で、意図しない操作を頼むことがあります（確認の内容を、よく読んでください）。\n\n作業フォルダ：\(chatFolderPath)" : (confirms ? "会話のエージェントが、ファイルの書き込み・コマンドの実行まで、できるようになります。\n\n**毎回、確認します**（常駐の接続）。確認の内容を、よく読んでください。\n\n声の聞き間違いや、検索したページの命令で、意図しない操作を頼むことがあります。\n\n作業フォルダ：\(chatFolderPath)" : "会話のエージェントが、ファイルの書き込み・コマンドの実行まで、確認なしで、できるようになります。\n\n声の聞き間違いや、検索したページに書かれた命令で、意図しない操作が起きることがあります。実行した操作は、答えの下に出ます。\n\n作業フォルダ：\(chatFolderPath)\n（大切なファイルのあるフォルダは、選ばないでください）")
            alert.addButton(withTitle: "開ける")
            alert.addButton(withTitle: "やめる")
            guard alert.runModal() == .alertFirstButtonReturn else { objectWillChange.send(); return }
        }
        update { $0.chatTools = level == .none ? nil : level.rawValue }
    }

    func chooseChatFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "このフォルダにする"
        panel.message = "会話のエージェントが、読む・書く、作業フォルダを選んでください（大切なファイルのあるフォルダは、避けてください）"
        panel.directoryURL = URL(fileURLWithPath: chatFolderPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.chatFolder = url.path }
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
