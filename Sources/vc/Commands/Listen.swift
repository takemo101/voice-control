import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

struct ListenCommand: Command {
    static let info = CommandInfo(
        name: "listen", group: .skills, summary: "マイクから聞いて、スキルで実行する",
        usage: ["vc listen [--hotkey] [--trigger <キー>] [--dry-run] [--yes] [--mute|--no-mute]"],
        details: [
            "既定：Enter で録音を始め、もう一度 Enter で止める（q で終了）。マイクの許可が要る。聞こえた文は、スキルで実行する（vc run と同じ。確認が要るときは、端末で [y/N] を聞く。--yes で省略）。",
            "--hotkey：トリガーを押している間だけ録音する。離すと、文字にして、Tiny-Jev がスキルを選び、Apple の言語モデルが実行する（vc run と同じ）。**当てはまるスキルがなければ、既定スキル（default）**が、agent-desktop と基本のコマンド（open・say・ls・pwd・date）で実行する。会話・独り言は、実行しない。取り消しにくい依頼（削除・送信・購入など）は、実行の前に、声の「はい」で確認する。既定スキルを無効にする（vc skills disable default）と、当てはまるスキルがない依頼は、実行しない。",
            "--hotkey のときは、画面の上に、録音中・認識中・選んだスキル・実行したコマンドと結果・言語モデルの返事を出す（クリックを通し、フォーカスを奪わない）。",
            "**Esc で取りやめ**（--hotkey）：録音中は、録音を捨てる（認識しない）。認識中・実行中・確認の待ちは、処理を止める（実行中のコマンドも止める）。Esc を受けるのは、これらの間だけで、ふだんの Esc には触れない。録音中（Shift などを押している間）の Esc は、アクセシビリティの許可が要る。",
            "実行の既定：スキルは、vc run と同じく、**実行する**（--dry-run を付けたときだけ、表示だけ）。",
            "トリガーは、既定が Shift の長押し。変えるには vc hotkey set <キー>（~/.voice-control/settings.json に保存）か、その回だけ --trigger <キー>。長押し（修飾キーだけ）の検出には、アクセシビリティの許可が要る（vc を動かす端末アプリに）。",
        ],
        options: [
            ("--hotkey", "押している間だけ録音する"),
            ("--trigger <キー>", "この回だけのトリガー（例：shift・ctrl+opt+space・f5。書き方は vc hotkey）"),
            ("--dry-run", "スキルのコマンドを実行せず、表示だけにする"),
            ("--yes", "確認を省略する（Enter で録音する通常モードだけ。--hotkey は、声の「はい」で確認する）"),
            ("--mute / --no-mute", "録音中に、ほかの音（出力）を消す／消さない（その実行だけ。常にそうするなら vc mute on|off。既定：録音の間だけ消音にし、終わったら戻す）"),
        ],
        examples: ["vc listen", "vc listen --hotkey", "vc listen --hotkey --dry-run"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc listen [--hotkey] [--no-mute]：既定は、Enter で録音を始め、もう一度 Enter で止める。--hotkey は、トリガー（既定：Shift の長押し。vc hotkey で変更）を押している間だけ録音する。どちらも、聞こえた文は、スキルの流れ（`SkillRunner`）で動かす（違うのは、きっかけと、確認の取り方だけ）。
        // マイクの許可が要る（初回、macOS が確認を出す）。
        // **ここから `VoiceLoop.run` まで、`await` を挟まない**（`NSApplication.run()` の前の `await` は、画面の表示・長押しの判定を止める。docs/architecture.md「時間と並行」）。
        var arguments = arguments
        let muteFlag: Bool?
        switch (arguments.flag("--mute"), arguments.flag("--no-mute")) {
        case (true, true): usageError("listen", "--mute と --no-mute は、一緒に使えません")
        case (true, false): muteFlag = true
        case (false, true): muteFlag = false
        case (false, false): muteFlag = nil
        }
        let muter: OutputMuter = MutePreference.resolve(flag: muteFlag, setting: context.currentSettings().mute) ? .system : .disabled
        requireAppleIntelligence(for: context.engine)   // 使えなければ、マイクの許可を聞く前に、理由と手順を示して終わる
        guard MicRecorder.authorize() else { fail("マイクが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）") }
        let jev = context.loadJev()
        let speech = context.makeSpeechEngine()   // 選んだ音声認識（ダウンロードしたモデルは、ここで読み込む）。終わる前に close
        defer { speech.close() }
        // Ctrl+C などで終わるとき、消したままにしない（録音中に終わっても、音を戻す）。主キューは、readLine や NSApplication で塞がるので、別のキューで受ける
        let signals = Self.restoreOnSignals(muter, speech)
        defer { withExtendedLifetime(signals) {} }
        if context.options.hotkey {
            runVoiceLoop(context, jev: jev, muter: muter, speech: speech)
            return
        }
        while true {
            print("\n" + Style.bold("Enter で録音開始（q で終了）> "), terminator: "")
            guard let line = readLine(), line != "q" else { break }
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vc-\(UUID().uuidString).caf")
            // try?: 一時の録音ファイルの片付け。消せなくても、結果は変わらない
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let recorder = MicRecorder()
                try recorder.start(to: file)
                muter.engage(after: 0)   // 録音の間だけ、ほかの音を消す（失敗しても、止めても、戻す）
                defer { muter.restore() }
                print("録音中… Enter で停止", terminator: "")
                _ = readLine()
                try recorder.stop()
                muter.restore()
                let utterance = try await speech.transcriber.transcribe(file: file)
                kv("聞こえた", utterance)
                guard !utterance.isEmpty else { notice("聞き取れなかった"); continue }
                let skills = context.loadSkills()
                skills.reportProblems()
                let dryRun = context.options.dryRun
                let skillRunner = SkillRunner(selection: .resolve(skills: skills.enabled, scorer: jev, gate: context.gate), dryRun: dryRun, engine: context.engine, scorer: context.scorerProvider(loaded: jev))
                _ = try await skillRunner.run(utterance, reporter: TerminalReporter(layout: .command, dryRun: dryRun), confirm: { askOnTerminal(yes: context.options.yes) })
            } catch { print(Style.red("失敗:") + " \(error)") }
        }
    }

    /// Ctrl+C（SIGINT）・SIGTERM・SIGHUP で終わるとき、消した出力を戻してから終わる（消したままにしない）。
    /// 受ける場所は、主キューではない：`readLine`（Enter モード）・`NSApplication.run()` が、主キューを塞ぐ。強制終了（SIGKILL）・クラッシュは、戻せない。
    private static func restoreOnSignals(_ muter: OutputMuter, _ speech: SpeechEngine) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM, SIGHUP].map { sig in
            signal(sig, SIG_IGN)   // 既定の動作（そのまま終わる）を、止める
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { muter.restore(); speech.close(); exit(128 + sig) }   // 音声認識のモデルは、開いたまま exit すると abort する
            source.resume()
            return source
        }
    }

    /// トリガーを押している間だけ録音し（その間、画面の上に「録音中」を出す）、離したら、文字にする。
    /// Tiny-Jev がスキルを選び、Apple の言語モデルが実行する（経過と結果を、画面の上に出す）。当てはまるスキルがなく、既定スキルも使えなければ、実行しない。
    /// --dry-run なら、コマンドを実行しない。確認が要る判定は、問いかけを読み上げ、次の発話の「はい」で実行する。
    /// 聞く・録る・Esc・待ち行列の調整は `VoiceLoop`（VCSpeech）。ここは、発話の処理（`UtteranceHandler`）と、出来事の表示だけを渡す。
    /// 同期の関数：`await` を挟まない（`VoiceLoop.run` の不変条件 1）。
    @MainActor private func runVoiceLoop(_ context: CommandContext, jev: TinyJev, muter: OutputMuter, speech: SpeechEngine) {
        do {
            let (spec, _) = context.resolveHotKey()
            let chip = spec.displayName
            HUD.shared.warmUp()   // トリガー（グローバルのキー監視）より先に、パネルを 1 回出す（確認のボタンが、クリックを受けられるように）
            let trigger = try makeTrigger(spec)
            let session = RecordingSession()
            session.setLevelHandler { HUD.shared.pushLevel($0) }   // 録音中の波形
            let loop = VoiceLoop(
                trigger: trigger, escape: EscapeKey(), recorder: PopRecorder(session, muter: muter), transcriber: speech.transcriber,
                handler: Self.utteranceHandler(context, jev: jev, chip: chip),
                onEvent: { Self.show($0, chip: chip, muter: muter) })
            loop.run {
                print(Style.bold("\(holdInstruction(spec))ている間だけ聞きます") + Style.dim("（Ctrl+C で終了。録音中・実行中に Esc で取りやめ）"))
                kv("音声認識", speech.choice.title, width: 8)
                kv("実行", context.engineText ?? "apple", width: 8)
                kv("ほかの音", muter === OutputMuter.disabled ? "録音中も流したまま" : "録音中は消す", width: 8)
                kv("スキル", context.options.dryRun ? Style.yellow("実行しない（--dry-run）") : Style.green("実行する"), width: 8)
                fflush(stdout)
                // 準備ができたことを、画面の上に出す（モデルの読み込みの間は、押しても反応しない）。許可がなければ、その旨を出す。
                if spec.isHold && !ModifierHold.isTrusted {
                    HUD.shared.show(HUDContent(phase: .failure, title: "アクセシビリティの許可がありません", hint: "システム設定 > プライバシーとセキュリティ > アクセシビリティで、このターミナルを許可して、開き直してください。許可なしなら vc hotkey set ctrl+opt+space", chip: chip), hideAfter: 15)
                } else {
                    HUD.shared.show(HUDContent(phase: .info, title: "準備できました", hint: "\(holdInstruction(spec))ている間だけ聞きます", chip: chip), hideAfter: 3.5)
                }
            }
        } catch { fail("ホットキーを登録できません: \(error)") }
    }

    /// `VoiceLoop` の出来事を、画面の上と端末に出す。
    private static func show(_ event: VoiceLoopEvent, chip: String, muter: OutputMuter) {
        switch event {
        case .recordingStarted:
            HUD.shared.show(HUDContent(phase: .recording, title: "録音中", hint: "離すと、認識して実行します（Esc で取りやめ）", chip: chip))
        case .recordingDiscarded:
            muter.restore()
            print("  " + Style.yellow("録音を取りやめました（Esc）"))
            HUD.shared.show(HUDContent(phase: .info, title: "録音を取りやめました", chip: chip), hideAfter: 1.5)
        case .recognizing:
            muter.restore()   // 認識の合図（Tink）を、聞こえるように、先に戻す
            NSSound(named: "Tink")?.play()
            HUD.shared.show(HUDContent(phase: .working, title: "認識中…", hint: "Esc で取りやめ", chip: chip))
        case .recordingEmpty:
            muter.restore()
            HUD.shared.hide()
        case let .recordingFailed(error):
            muter.restore()
            print("録音に失敗: \(error)")
            HUD.shared.show(HUDContent(phase: .failure, title: "録音に失敗しました", reply: "\(error)"), hideAfter: 4)
        case let .recognized(text):
            kv("聞こえた", text)
        case .recognitionCancelled:
            showCancelled(chip: chip)
        case let .recognitionFailed(error):
            showFailure(error, chip: chip)
        case .cancelling:
            SaySpeaker.shared.stop()
            HUD.shared.show(HUDContent(phase: .info, title: "取りやめています…", chip: chip))
        }
    }

    /// 取りやめた（文字にする段階も、実行の段階も、同じ表示）。
    private static func showCancelled(chip: String) {
        print("  " + Style.yellow("取りやめました（Esc）"))
        HUD.shared.show(HUDContent(phase: .info, title: "取りやめました", chip: chip), hideAfter: 2)
    }

    private static func showFailure(_ error: Error, chip: String) {
        print(Style.red("失敗:") + " \(error)")
        HUD.shared.show(HUDContent(phase: .failure, title: "失敗", chip: chip, reply: "\(error)"), hideAfter: 6)
    }

    /// 1 回の発話の処理：スキル（`SkillRunner`＋`HUDReporter`）。当てはまるスキルがなく、既定スキルも使えなければ、実行しない（`HUDReporter` が、そう出す）。確認の返事は、`next` で待つ。
    private static func utteranceHandler(_ context: CommandContext, jev: TinyJev, chip: String) -> UtteranceHandler {
        let confirmation = Confirmation(scorer: jev)
        return { utterance, token, next in
            do {
                guard !utterance.isEmpty else {
                    notice("聞き取れなかった")
                    HUD.shared.show(HUDContent(phase: .failure, title: "聞き取れませんでした", hint: "もう一度、はっきり話してください", chip: chip), hideAfter: 2.5)
                    return
                }
                let skills = context.loadSkills()
                skills.reportProblems()
                let skillRunner = SkillRunner(selection: .resolve(skills: skills.enabled, scorer: jev, gate: context.gate), dryRun: context.options.dryRun, cancel: token, engine: context.engine, scorer: context.scorerProvider(loaded: jev))
                let reporter = HUDReporter(chip: chip, utterance: utterance, dryRun: context.options.dryRun)
                _ = try await skillRunner.run(utterance, reporter: reporter, confirm: {
                    // パネルのボタンと、声の返事の、先に答えたほうが決まる（もう一方は、取りやめる）
                    let panel = PanelAnswer()
                    HUD.shared.answers.set { panel.resolve($0) }
                    defer { HUD.shared.answers.set(nil) }
                    return try await ConfirmationRace.decide(panel: panel) {
                        guard let answer = try await next() else { return false }
                        return try confirmation.isYes(answer)
                    }
                })
            } catch {
                if token.isCancelled || error is CancellationError { showCancelled(chip: chip) } else { showFailure(error, chip: chip) }
            }
        }
    }
}

/// 録音を始めたあとに、開始の音（Pop）を鳴らし、そのあと、ほかの音を消す。止めたら・捨てたら、戻す（録音の開始 → 音 → 消す、の順を保つ。`VoiceLoop` は、音も、出力の消音も知らない）。
private final class PopRecorder: Recording {
    private let base: Recording
    private let muter: OutputMuter
    init(_ base: Recording, muter: OutputMuter) { self.base = base; self.muter = muter }

    func start() {
        base.start()
        NSSound(named: "Pop")?.play()
        muter.engage()   // Pop が鳴り終わるころに、消す。離すのが先なら、消さない
    }

    func discard() { muter.restore(); base.discard() }
    func stop() throws -> URL? { muter.restore(); return try base.stop() }
}
