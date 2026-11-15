import AppKit
import ApplicationServices
import Foundation
import ServiceManagement
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// メニューバーのアプリの本体：声の入力（`VoiceSession`）を、アプリのイベントループの上で動かす。
/// **端末の 声の入力 とは別に、許可の持ち主が、アプリ自身になる**（マイク・アクセシビリティ）。起動できない理由は、ダイアログとメニューに出す（アプリには、端末がない）。
@MainActor final class AppRuntime {
    static let shared = AppRuntime()

    enum State: Equatable {
        case starting
        /// 聞いている。`hint`：使い方（例：「Shift を単独で 0.35 秒以上押し続けている間だけ聞きます」）。
        case listening(hint: String)
        /// 起動できなかった。`reason`：理由と直し方。
        case stopped(reason: String)
    }

    private(set) var state = State.starting { didSet { for observer in observers.values { observer() } } }
    private var observers: [UUID: () -> Void] = [:]
    private var session: VoiceSession?
    private var muter: OutputMuter?
    private var speech: SpeechEngine?
    private var speechID: String?
    private var jev: TinyJev?
    private var reloadTask: Task<Void, Never>?
    /// `start()` が呼ばれた（アプリとして動いている）。設定ウィンドウだけのプレビューなどでは、偽。
    private(set) var isActive = false

    /// 状態の変化を受け取る（メニュー・設定ウィンドウ）。返す印を持っている間だけ、届く。
    func observe(_ handler: @escaping () -> Void) -> AnyObject {
        let id = UUID()
        observers[id] = handler
        return ObserverToken { [weak self] in self?.observers[id] = nil }
    }

    private final class ObserverToken { let cancel: () -> Void; init(_ cancel: @escaping () -> Void) { self.cancel = cancel }; deinit { cancel() } }

    /// 声の入力を始める。失敗は、`state` と、ダイアログに出す（アプリは、終わらない：メニューから、直せる）。
    func start() {
        isActive = true
        state = .starting
        FailurePresenter.show = { message in AppAlerts.show(title: "vc を続けられません", message: message, style: .critical) }
        let context = Self.makeContext()
        do {
            let jev = try Self.preflight(context)
            // アクセシビリティ：許可がなければ、macOS の案内を出して、このアプリを、許可の一覧に載せる（載っていないと、利用者が見つけられない）
            if !ModifierHold.isTrusted { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
            self.jev = jev
            try bringUp(context)
        } catch {
            let reason = "\(error)"
            state = .stopped(reason: reason)
            AppAlerts.show(title: "声の入力を始められません", message: reason, style: .warning)
            // 直せる場所を、開く（モデルがなければ「モデル」・許可がなければ「一般」）
            if let page = (error as? StartupProblem)?.page { SettingsWindow.shared.show(page: page) }
        }
    }

    private static func makeContext() -> CommandContext {
        var arguments = Arguments([])
        return CommandContext(options: CommonOptions(consuming: &arguments))
    }

    /// 設定を読んで、声の流れを作り、始める。Tiny-Jev・音声認識（変わっていなければ）は、使い回す。
    private func bringUp(_ context: CommandContext) throws {
        guard let jev else { throw StartupProblem("Tiny-Jev のモデルが、まだ読まれていません") }
        let choice = context.speechChoice
        if speech == nil || speechID != choice.id {
            speech?.close()
            speech = nil
            speech = try SpeechEngine.make(choice)
            speechID = choice.id
        }
        guard let speech else { throw StartupProblem("音声認識を、用意できません") }
        var none = Arguments([])
        let muter = VoiceUI.muter(&none, context, command: "app")
        self.muter?.restore()
        self.muter = muter
        let session = try VoiceSession.make(context: context, jev: jev, muter: muter, speech: speech)
        self.session = session
        session.loop.begin(onReady: session.onReady)
        state = .listening(hint: session.hint)
    }

    /// 設定が変わった：声の流れを、作り直す（再起動は、要らない）。続けて変えたときは、まとめる。処理の最中（録音・認識・実行）は、終わるのを待つ。アプリとして動いていなければ、何もしない（偽を返す）。
    @discardableResult
    func scheduleReload() -> Bool {
        guard isActive else { return false }
        reloadTask?.cancel()
        state = .starting
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
        return true
    }

    private func reload() async {
        guard jev != nil else { start(); return }   // 最初の起動が、できていなかった：全体を、やり直す
        // 処理の最中は、待つ（最大 60 秒。それでも終わらなければ、そのまま作り直す）
        for _ in 0..<120 where session?.loop.isBusy == true {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        // 古い声の流れの、キーの受け付けを、いますぐ外す（同じキーを、二重に登録しない。手放されるのを待たない）
        session?.stop()
        session = nil
        do { try bringUp(Self.makeContext()) } catch {
            state = .stopped(reason: "\(error)")
        }
    }

    /// 始める前の確認（理由を、そのまま、利用者に見せる）。Tiny-Jev を読んで返す。
    private static func preflight(_ context: CommandContext) throws -> TinyJev {
        if context.engine == .apple, case let .unavailable(reason) = AppleIntelligence.current() {
            throw StartupProblem("\(reason.summary)。\(reason.remedy)")
        }
        guard MicRecorder.authorize() else { throw StartupProblem(MicRecorder.deniedMessage(), page: .general) }
        do { return try context.tryLoadJev() } catch let missing as CommandContext.ModelMissing {
            throw StartupProblem("\(missing)。設定ウィンドウ > モデル の「Tiny-Jev」を取得してください（約 1.2 GB。取得だけが、外部との通信です）", page: .models)
        } catch { throw StartupProblem("Tiny-Jev のモデルを読めません: \(error)") }
    }

    struct StartupProblem: Error, CustomStringConvertible {
        let description: String
        /// 直せる設定のページ。
        let page: SettingsPage?
        init(_ text: String, page: SettingsPage? = nil) { description = text; self.page = page }
    }

    /// 終了の後始末（消音を戻す・認識を閉じる・撮ったスクリーンショットを消す）。
    func shutdown() {
        muter?.restore()
        speech?.close()
        ScreenshotStore.clear()
    }
}

enum AppAlerts {
    @MainActor static func show(title: String, message: String, style: NSAlert.Style) {
        let present = {
            NSApplication.shared.activate()
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = style
            alert.addButton(withTitle: "閉じる")
            alert.runModal()
        }
        if Thread.isMainThread { present() } else { DispatchQueue.main.sync(execute: present) }
    }
}

/// メニューバーのアプリ。Dock にもウィンドウにも出さず、メニューバーの項目だけを置く。
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenu(runtime: AppRuntime.shared)
        // SIGTERM も、通常の終了と同じ道（後始末）を通す
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termination = source
        AppRuntime.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) { AppRuntime.shared.shutdown() }
}

enum AppEntry {
    /// メニューバーのアプリを起動する。終了するまで戻らない。
    @MainActor static func launch() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
