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

    private(set) var state = State.starting { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private var session: VoiceSession?
    private var muter: OutputMuter?
    private var speech: SpeechEngine?

    /// 声の入力を始める。失敗は、`state` と、ダイアログに出す（アプリは、終わらない：メニューから、直せる）。
    func start() {
        state = .starting
        FailurePresenter.show = { message in AppAlerts.show(title: "vc を続けられません", message: message, style: .critical) }
        var arguments = Arguments([])
        let options = CommonOptions(consuming: &arguments)
        let context = CommandContext(options: options)
        do {
            let jev = try Self.preflight(context)
            // アクセシビリティ：許可がなければ、macOS の案内を出して、このアプリを、許可の一覧に載せる（載っていないと、利用者が見つけられない）
            if !ModifierHold.isTrusted { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
            let speech = try SpeechEngine.make(context.speechChoice)
            var none = Arguments([])
            let muter = VoiceUI.muter(&none, context, command: "app")
            let session = try VoiceSession.make(context: context, jev: jev, muter: muter, speech: speech)
            self.speech = speech
            self.muter = muter
            self.session = session
            session.loop.begin(onReady: session.onReady)
            state = .listening(hint: session.hint)
        } catch {
            let reason = "\(error)"
            state = .stopped(reason: reason)
            AppAlerts.show(title: "声の入力を始められません", message: reason, style: .warning)
            // 直せる場所を、開く（モデルがなければ「モデル」・許可がなければ「一般」）
            if let page = (error as? StartupProblem)?.page { SettingsWindow.shared.show(page: page) }
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
