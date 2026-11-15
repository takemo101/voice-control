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

/// インストールできるスキルの一覧の状態（GitHub の公開リポジトリ。取得は、利用者が押したときだけ）。
enum CatalogState {
    case idle
    case loading
    case loaded(RemoteInstall.Listing)
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
    @Published var page: SettingsPage = .general
    /// キー欄の入力中の文字と、その問題。
    @Published var keyDrafts: [KeyKind: String] = [:]
    @Published private(set) var keyProblems: [KeyKind: String] = [:]
    @Published var engineKind: SettingsRules.EngineKind = .apple
    @Published var engineRest = ""
    @Published private(set) var engineProblem: String?
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var catalog = CatalogState.idle
    /// インストール中のスキルの名前。
    @Published private(set) var installing: Set<String> = []
    /// インストールの結果（成功・失敗）。名前ごとに、最後の 1 件。
    @Published private(set) var installResults: [String: (ok: Bool, text: String)] = [:]
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

    // MARK: 会話の道具

    var chatToolLevel: ChatToolLevel { settings.chatTools.flatMap(ChatToolLevel.init(rawValue:)) ?? .none }
    var chatFolderPath: String { settings.chatFolder ?? ExternalChatBackend.defaultFolder.path }

    /// 会話のエージェントに開ける道具の段階を決める。**すべて**は、聞き間違い・Web のページの命令で、意図しない操作が起きえるので、確認を出す。
    func setChatTools(_ level: ChatToolLevel) {
        if level == .all {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "すべての道具を、開けますか？"
            alert.informativeText = "会話のエージェントが、ファイルの書き込み・コマンドの実行まで、確認なしで、できるようになります。\n\n声の聞き間違いや、検索したページに書かれた命令で、意図しない操作が起きることがあります。実行した操作は、答えの下に出ます。\n\n作業フォルダ：\(chatFolderPath)\n（大切なファイルのあるフォルダは、選ばないでください）"
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

    // MARK: スキルのインストール（`vc skills install` と同じ流れ：`RemoteInstall`）

    private var installRef: String { "v\(AppInfo.version)" }

    /// インストールできるスキルの一覧を取る（GitHub への通信：押したときだけ）。
    func loadCatalog() {
        if case .loading = catalog { return }
        catalog = .loading
        let ref = installRef
        Task {
            do {
                let listing = try await RemoteInstall.list(explicitRef: nil, defaultRef: ref)
                catalog = .loaded(listing)
            } catch {
                catalog = .failed(Self.describe(error))
            }
        }
    }

    var installingIsEmpty: Bool { installing.isEmpty }

    /// 許可するコマンドの表示：取得のための一時フォルダの名前は出さず、`${SKILL_DIR}`（スキルのフォルダ）にする。
    static func commands(of skill: Skill) -> String {
        let directory = skill.file.deletingLastPathComponent().resolvingSymlinksInPath().path
        let raw = skill.allowedCommands.map { $0.replacingOccurrences(of: skill.file.deletingLastPathComponent().path, with: "${SKILL_DIR}").replacingOccurrences(of: directory, with: "${SKILL_DIR}") }
        return raw.isEmpty ? "（なし）" : raw.joined(separator: "、")
    }

    func isInstalled(skill name: String) -> Bool {
        FileManager.default.fileExists(atPath: VoiceControlHome.skillsDirectory.appendingPathComponent(name).path)
    }

    /// 1 つ入れる（同名があれば、置き換える：「更新」）。**入れる前に、許可するコマンド・確認・外へ送るかを見せて、確かめる**（入れたスキルは、信頼の手続きなしで、いつも読み込まれるため）。
    func install(_ skill: Skill) {
        guard !installing.contains(skill.name), case let .loaded(listing) = catalog else { return }
        let replacing = isInstalled(skill: skill.name)
        guard Self.confirmInstall([skill], replacing: replacing, source: listing.source) else { return }
        run(names: [skill.name], listing: listing, overwrite: replacing)
    }

    /// 一覧の、まだ入れていないスキルを、すべて入れる。
    func installMissing() {
        guard case let .loaded(listing) = catalog, installing.isEmpty else { return }
        let missing = listing.skills.filter { !isInstalled(skill: $0.name) }
        guard !missing.isEmpty, Self.confirmInstall(missing, replacing: false, source: listing.source) else { return }
        run(names: missing.map(\.name).sorted(), listing: listing, overwrite: false)
    }

    private func run(names: [String], listing: RemoteInstall.Listing, overwrite: Bool) {
        installing.formUnion(names)
        names.forEach { installResults[$0] = nil }
        Task {
            do {
                // 一覧と同じ版で取る（タグがなく、main に切り替えた場合も、同じ）
                let report = try await RemoteInstall.install(names: names, explicitRef: listing.source.ref, defaultRef: installRef, overwrite: overwrite)
                for outcome in report.outcomes {
                    switch outcome.result {
                    case let .success(installed): installResults[outcome.name] = (true, installed.overwritten ? "置き換えました" : "入れました")
                    case let .failure(failure): installResults[outcome.name] = (false, Self.describe(failure))
                    }
                }
            } catch {
                names.forEach { installResults[$0] = (false, Self.describe(error)) }
            }
            installing.subtract(names)
            revision += 1   // 一覧（有効・無効）を、読み直す
        }
    }

    /// 入れる前の確認（許可するコマンド・確認の有無・外へ送るか）。入れてよければ true。
    private static func confirmInstall(_ skills: [Skill], replacing: Bool, source: RemoteInstall.Source) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = skills.contains { $0.external != nil } ? .warning : .informational
        if skills.count == 1, let skill = skills.first {
            alert.messageText = "スキル「\(skill.name)」を、\(replacing ? "置き換え" : "入れ")ますか？"
            var lines = [skill.description, "", "許可するコマンド：" + commands(of: skill), "実行の前の確認：" + (skill.confirm ? "必須" : "なし")]
            if let notice = skill.externalNotice { lines.append("外へ送ります：" + notice) }
            lines += ["", "取得元：github.com/\(RemoteSkills.repository) @ \(source.ref)", "入れたスキルは、信頼の手続きなしで、どこでも、いつも読み込まれます。"]
            alert.informativeText = lines.joined(separator: "\n")
        } else {
            alert.messageText = "\(skills.count) 個のスキルを、入れますか？"
            let external = skills.filter { $0.external != nil }
            var lines = [skills.map(\.name).sorted().joined(separator: "、"), ""]
            if !external.isEmpty { lines.append("使うと、発話や画面の画像を、この Mac の外へ送ります：" + external.map { "\($0.name)（\($0.externalNotice ?? "")）" }.joined(separator: "、")) }
            lines += ["取得元：github.com/\(RemoteSkills.repository) @ \(source.ref)", "許可するコマンドは、各スキルの SKILL.md で決まります（一覧の各行で、確かめられます）。"]
            alert.informativeText = lines.joined(separator: "\n")
        }
        alert.addButton(withTitle: replacing ? "置き換える" : "入れる")
        alert.addButton(withTitle: "やめる")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func describe(_ failure: SkillInstaller.Failure) -> String {
        switch failure {
        case .notFound: return "リポジトリに、読めるスキルがありません"
        case let .unreadable(_, why): return "SKILL.md が読めません（\(why)）"
        case .alreadyInstalled: return "すでに入っています"
        case let .containsSymlink(_, path): return "シンボリックリンク（\(path)）を含むので、置きません"
        case let .copyFailed(_, why): return "置けません（\(why)）"
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let failure = error as? RemoteSkills.Failure else { return "取得できません：\(error.localizedDescription)" }
        switch failure {
        case let .network(reason): return "GitHub から取得できません（\(reason)）。ネットワークを確かめてください"
        case let .refNotFound(missing): return "版 \(missing) が、リポジトリにありません"
        default: return "取得できません：\(failure)"
        }
    }

    func setSkill(_ name: String, enabled: Bool) {
        update(restart: false) { $0.setEnabled(name, enabled) }   // スキルは、発話のたびに読み直す：再起動は要らない
    }
}
