import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, keys, voice, dictation, transcribe, history, chat, models, skills
    var id: String { rawValue }

    /// サイドバーの区切り（見出し・ページ）。上から：全体・声の入力・会話と実行。
    static var sections: [(title: String?, pages: [SettingsPage])] {
        [(nil, [.general]), (tr("入力"), [.keys, .voice, .dictation, .transcribe, .history]), (tr("会話と実行"), [.chat, .models, .skills])]
    }

    var title: String {
        switch self {
        case .keys: return tr("キー")
        case .voice: return tr("音声")
        case .dictation: return tr("音声入力")
        case .transcribe: return tr("文字起こし")
        case .history: return tr("履歴")
        case .chat: return tr("会話")
        case .models: return L10n.shared.language == .ja ? "モデル" : tr(verbatim: "Models")   // l10n-skip：行の「モデル」（Model）と、訳が違う。日本語以外は、英語の文を鍵にして引く（表の「Models」）
        case .skills: return tr("スキル")
        case .general: return tr("一般")
        }
    }
    var symbol: String {
        switch self {
        case .keys: return "keyboard"
        case .voice: return "waveform"
        case .dictation: return "text.cursor"
        case .transcribe: return "captions.bubble.fill"
        case .history: return "clock.arrow.circlepath"
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
    /// エンジンの入力（状態と規則は、`EngineDraft`）。
    @Published private(set) var engineDraft = EngineDraft(settings: Settings())
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published var fillersText = ""
    /// 整理の整え方の編集中の文字（設定になければ、既定を、出す）。
    @Published var tidyInstructionsText = ""
    /// 文字起こしで選べるアプリ（「一覧を読む」で、はじめて読む：画面収録の許可の確認が、出うる）と、読めなかった理由。
    @Published var captureApps: [CaptureApp] = []
    @Published var captureAppsMessage: String?
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
        // ショートカット・メニューで、送るキーを切り替えたとき：開いているウィンドウも、読み直す（古い値で、上書きしない）
        externalChange = NotificationCenter.default.addObserver(forName: DictationActions.settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private var externalChange: NSObjectProtocol?

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
        for kind in KeyKind.fixed { keyDrafts[kind] = kind.value(in: settings) ?? "" }
        keyProblems = [:]
        engineDraft = EngineDraft(settings: settings)
        fillersText = (settings.fillers ?? []).joined(separator: "\n")
        tidyInstructionsText = TidyPrompt.instructions(setting: settings.tidyInstructions)
    }

    /// 表示言語（設定ウィンドウとダイアログ）と、音声認識の言語。どちらも、ja・en。なければ日本語。
    var uiLanguage: AppLanguage { settings.displayLanguage }
    var sttLanguage: SpeechLanguage { settings.recognitionLanguageOrDefault }
    func setUILanguage(_ language: AppLanguage) { update(restart: false) { $0.uiLanguage = language == .ja ? nil : language.rawValue } }
    /// ダウンロードした音声認識のモデルを、使っているか（言語の「自動」は、これだけが、音声から判定できる）。
    var usesLocalSpeechModel: Bool { if case .local = (try? settings.speechChoice.get()) ?? .apple { return true } else { return false } }
    /// 入力のあとに送るキーの候補を、選ぶ（入力のたびに読む設定：声の入力は、作り直さない）。
    func setDictateMode(_ index: Int) { update(restart: false) { $0.dictateMode = index } }

    /// 送るキーを、一覧の `index` 番目に決める（一覧の長さ以上なら、足す）。書き方が読めなければ、直さずに、理由を出す。
    func setSendKey(_ index: Int, _ text: String) {
        let kind = KeyKind.sendKey(index)
        if let why = SettingsRules.keyProblem(kind, text: text, in: settings) { keyProblems[kind] = why; return }
        keyProblems[kind] = nil
        guard index < DictateSendModes.maxKeys else { return }
        update(restart: false) { kind.set(text, in: &$0) }
    }

    /// 送るキーを、一覧から外す。いま使っている候補は、そのまま（外したキーなら、「送らない」。後ろのキーは、番号が 1 つ繰り上がる）。
    func removeSendKey(_ index: Int) {
        let before = settings.dictateSend
        guard before.modes.indices.contains(index + 1) else { return }
        let active = before.active == index + 1 ? 0 : (before.active > index + 1 ? before.active - 1 : before.active)
        update(restart: false) {
            KeyKind.sendKey(index).set(nil, in: &$0)
            $0.dictateMode = active
        }
        keyProblems[.sendKey(index)] = nil
    }

    func setSTTLanguage(_ language: SpeechLanguage) { update { $0.sttLanguage = language == .ja ? nil : language.rawValue } }

    /// 設定を変えて、保存する。書けなければ、理由を出して、変えない。`restart`：声の入力の起動のときに読む設定か。
    func update(restart: Bool = true, _ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        do {
            try next.save()
            settings = next
            AppLocalization.apply(next)   // 言語（表示言語・答えの言語）
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
        update { kind.set(text, in: &$0) }
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
            if case let .sendKey(index) = kind { setSendKey(index, text) } else {
                setDraft(kind, text)
                commitKey(kind)
            }
        }
    }

    // MARK: エンジン

    /// Ollama・OpenAI 互換のサーバーの場所（書き方が正しいとき。Ollama は、省くと既定）。
    var engineServer: ServerAddress? { engineDraft.server }
    /// その場所を、通信してよいか（この Mac は、いつも。LAN は、利用者が、その場所を許可しているときだけ）。
    var engineLANApproved: Bool { engineServer?.isApproved(by: settings.engineApproved) ?? false }
    /// そのサーバーの APIキーを、保管庫に持っているか（値は、見せない）。
    var engineKeyConfigured: Bool { _ = engineKeyRevision; return engineServer.map { EngineKeyStore.standard.hasKey(for: $0.endpoint) } ?? false }
    @Published private(set) var engineKeyRevision = 0
    @Published private(set) var engineKeyProblem: String?
    /// 入力中の APIキー（保存したら、空にする。画面に、残さない）。
    @Published var engineKeyDraft = ""

    func setEngineKey(_ key: String) {
        guard let server = engineServer else { return }
        do { try EngineKeyStore.standard.set(key, for: server.endpoint); engineKeyProblem = nil } catch { engineKeyProblem = "\(error)" }
        engineKeyDraft = ""
        engineKeyRevision += 1
    }

    /// 種類（Apple・Ollama・OpenAI 互換）を切り替える。**種類ごとの入力は、別々**（`EngineDraft`）。
    func switchEngineKind(_ kind: EngineKind) {
        guard kind != engineDraft.kind else { return }
        engineDraft.switchKind(kind, settings: settings)
        resetEngineCheck()
        saveEngineDraft()
    }

    /// モデルの名前・エンドポイントの入力（片方だけ、渡す）。問題がなければ、保存する。
    func setModelEndpoint(model name: String? = nil, endpoint: String? = nil) {
        let previous = engineServer
        engineDraft.edit(model: name, endpoint: endpoint)
        engineKeyDraft = ""   // 入力中のキーは、前のサーバーのもの：残さない
        if previous != engineServer { engineModels = [] }   // 一覧は、そのサーバーのもの
        engineProbe = .idle   // 確認の結果は、入力が変わったら、古い
        guard engineDraft.problem == nil else { return }
        saveEngineDraft()
    }

    func chooseEngineModel(_ name: String) { setModelEndpoint(model: name) }

    /// LAN の場所への許可：オンにするとき、何が出るかを見せて、確認する。**許可と一緒に、いまの入力を保存する**（許可するまでは、保存していない）。外すと、Apple のモデルに戻る。
    func setEngineLANApproved(_ on: Bool) {
        guard let server = engineServer, !server.isLoopback else { return }
        if on {
            guard AppAlerts.confirm(title: tr("\(server.endpoint) へ、音声・画面の内容を送りますか？"), message: tr("スキルを実行するモデルへ、話した内容・選んだ画面の内容・実行結果が、同じ LAN の \(server.endpoint) へ送られます。通信は、暗号化されません（HTTP）。このサーバーを、信頼できるときだけ、許可してください。"), confirm: tr("許可する"), cancel: tr("やめる"), style: .warning) else { return }
        }
        let approved = on ? server.endpoint : nil
        let draft = engineDraft
        update {
            $0.engineApproved = approved
            if draft.problem == nil { $0.engine = draft.persistedEngine(approved: approved) }
        }
    }

    /// 入力を、設定ファイルへ保存する（`engine`：使うもの。`engineRests`：種類ごとの、最後の入力）。
    private func saveEngineDraft() {
        let engine = engineDraft.persistedEngine(approved: settings.engineApproved)
        let rests = engineDraft.persistedRests(base: settings.engineRests)
        update { $0.engine = engine; $0.engineRests = rests }
    }

    // MARK: 一覧・接続の確認（質問は送らない：一覧の取得と、モデルの有無の確認だけ）

    enum EngineProbe: Equatable {
        case idle, working
        case ok(String)
        case failed(String)
    }
    @Published private(set) var engineProbe: EngineProbe = .idle
    /// サーバーが持っているモデル（「一覧」で取ったもの）。
    @Published private(set) var engineModels: [String] = []

    private func resetEngineCheck() {
        engineKeyDraft = ""
        engineModels = []
        engineProbe = .idle
    }

    /// 「一覧」：サーバーのモデルの一覧を取る。
    func loadEngineModels() {
        guard let server = engineServer, let kind = engineDraft.kind.serverKind else { return }
        engineProbe = .working
        Task { [weak self] in
            do {
                let names = try await ModelServerCatalog.list(kind: kind, server: server)
                guard let self, self.engineServer == server else { return }   // 取っている間に、場所が変わった：捨てる
                self.engineModels = names
                self.engineProbe = .ok(tr("\(names.count) 件のモデルがあります"))
            } catch {
                guard let self, self.engineServer == server else { return }
                self.engineModels = []
                self.engineProbe = .failed("\(error)")
            }
        }
    }

    /// 「確かめる」：サーバーが動いていて、キーが通り、モデルがあるか。
    func checkEngine() {
        let draft = engineDraft
        guard draft.kind != .apple, draft.problem == nil, let engine = try? Engine.parse(EngineRules.engineText(kind: draft.kind, rest: draft.rest)) else { return }   // try?: 書き方の問題は、`problem` が出している
        let server = engineServer
        engineProbe = .working
        Task { [weak self] in
            do {
                try await engine.verify()
                guard let self, self.engineServer == server else { return }
                self.engineProbe = .ok(tr("使えます（サーバーに、モデルがあります）"))
            } catch {
                guard let self, self.engineServer == server else { return }
                self.engineProbe = .failed("\(error)")
            }
        }
    }

    // MARK: 音声認識・モデル

    var sttChoices: [(id: String, title: String)] {
        [("apple", tr("Apple の SpeechTranscriber（既定）"))] + SpeechModelCatalog.all.map { ($0.id, "\($0.name)" + (isInstalled($0.spec) ? "" : tr("（未取得）"))) }
    }

    func setSTT(_ id: String) {
        if id != "apple", let model = SpeechModelCatalog.all.first(where: { $0.id == id }), !isInstalled(model.spec) {
            downloads[id] = .failed(tr("先に、取得してください"))
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
        do { try FileManager.default.removeItem(at: ModelStore.defaultDirectory(for: spec)) } catch { downloads[id] = .failed(tr("消せませんでした: \(error.localizedDescription)")) }
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
            adapterWork[adapter.agent.rawValue] = .failed(tr("同梱の固定ファイル（adapters/\(adapter.directoryName)）が、見つかりません（ビルドしたままのアプリ？）"))
            return
        }
        let message = [
            tr("\(adapter.package) \(adapter.version)（\(adapter.license)）を、npm から、入れます。約 \(adapter.approximateSizeMB) MB。"),
            "",
            tr("入れる先：\(ACPAdapterStore.directory(for: adapter).path)"),
            tr("・版は固定です（アプリに同梱の lock どおり。すべての部品を SHA-512 で照合し、取得先は npm の公式のレジストリだけ）。"),
            tr("・インストール時のスクリプトは、動かしません。あなたの \(adapter.agent.rawValue) の本体を使います（二重に取り込みません）。"),
            tr("・これは、第三者のプログラムを、この Mac で動かすことになります（会話のたびに、起動します）。消すときは、ここから「消す」か、そのフォルダを消します。"),
            tr("・Node.js（npm）を使います。"),
        ].joined(separator: "\n")
        guard AppAlerts.confirm(title: tr("\(adapter.agent.rawValue) の ACP アダプターを、入れますか？"), message: message, confirm: tr("入れる")) else { return }
        adapterWork[adapter.agent.rawValue] = .working(tr("入れています…（数十秒かかることがあります）"))
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

    /// 自動モードを、オン・オフにする。**オンにするときは、確認のダイアログ**（何が、確認なしになり、何が、確認のままか）。
    func setChatAuto(_ on: Bool) {
        if on {
            let message = [
                tr("作業フォルダの中の書き込みと、安全なコマンドは、確認なしで実行します。"),
                tr("消す・外へ送る・システムを動かす操作は、これまでどおり、確認します。"),
                tr("コードの中の操作は、見抜けないことがあります。"),
            ].joined(separator: "\n\n")
            guard AppAlerts.confirm(title: tr("自動モードを、オンにしますか？"), message: message, confirm: tr("オンにする"), style: .warning) else { objectWillChange.send(); return }
        }
        update { $0.chatAuto = on ? true : nil }
    }

    // MARK: 会話の道具

    var chatToolLevel: ChatToolLevel { settings.chatTools.flatMap(ChatToolLevel.init(rawValue:)) ?? .none }
    var chatFolderPath: String { settings.chatFolder ?? ExternalChatBackend.defaultFolder.path }

    /// 会話のエージェントに開ける道具の段階を決める。**すべて**は、聞き間違い・Web のページの命令で、意図しない操作が起きえるので、確認を出す。
    func setChatTools(_ level: ChatToolLevel) {
        if level == .all {
            let chosen = ChatAgent.parse(settings.chatAgent ?? "apple") ?? .apple
            let message = ChatToolLevel.allToolsDialogBody(agent: chosen, acp: settings.chatAcp ?? true) + "\n\n" + tr("作業フォルダ：\(chatFolderPath)")
            guard AppAlerts.confirm(title: tr("すべての道具を、開けますか？"), message: message, confirm: tr("開ける"), style: .warning) else { objectWillChange.send(); return }
        }
        update { $0.chatTools = level == .none ? nil : level.rawValue }
    }

    func chooseChatFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("このフォルダにする")
        panel.message = tr("会話のエージェントが、読む・書く、作業フォルダを選んでください（大切なファイルのあるフォルダは、避けてください）")
        panel.directoryURL = URL(fileURLWithPath: chatFolderPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.chatFolder = url.path }
    }

    // MARK: 音声

    func saveFillers() {
        let lines = fillersText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        update { $0.fillers = lines.isEmpty ? nil : lines }
    }

    /// 整理の整え方を、保存する（既定と同じ・空なら、設定から外す：既定が、更新されたとき、追いつく）。
    func saveTidyInstructions() {
        let text = tidyInstructionsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.isEmpty || text == TidyPrompt.defaultInstructions ? nil : String(text.prefix(TidyPrompt.maxInstructionLength))
        update(restart: false) { $0.tidyInstructions = value }
        tidyInstructionsText = TidyPrompt.instructions(setting: value)
    }

    func loadCaptureApps() {
        Task { @MainActor in
            do { captureApps = try await SystemAudioCapture.availableApps(); captureAppsMessage = captureApps.isEmpty ? tr("取り込めるアプリが、ありません") : nil }
            catch { captureAppsMessage = "\(error)" }
        }
    }

    func resetTidyInstructions() {
        update(restart: false) { $0.tidyInstructions = nil }
        tidyInstructionsText = TidyPrompt.defaultInstructions
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
