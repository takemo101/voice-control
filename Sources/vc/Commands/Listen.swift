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
            "**実行中に、新しく話すと、前の処理を中断して、新しい依頼を実行する**（--hotkey。確認の返事を待っている間は、中断せず、返事として扱う）。",
            "**Esc で取りやめ**（--hotkey）：録音中は、録音を捨てる（認識しない）。認識中・実行中・確認の待ちは、処理を止める（実行中のコマンドも止める）。Esc を受けるのは、これらの間だけで、ふだんの Esc には触れない。録音中（Shift などを押している間）の Esc は、アクセシビリティの許可が要る。",
            "実行の既定：スキルは、vc run と同じく、**実行する**（--dry-run を付けたときだけ、表示だけ）。",
            "トリガーは、既定が Shift の長押し。変えるには vc hotkey set <キー>（~/.voice-control/settings.json に保存）か、その回だけ --trigger <キー>。長押し（修飾キーだけ）の検出には、アクセシビリティの許可が要る（vc を動かす端末アプリに）。",
        ],
        options: [
            ("--hotkey", "押している間だけ録音する"),
            ("--dictate-trigger <キー>", "この回だけの、音声入力のトリガー（例：ctrl）。声で頼むトリガーとは別のキー。押すと、スキルを使わず、文字にして前面のアプリへ入力する（vc dictate と同じ）。常にそうするなら vc hotkey set-dictate"),
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
        let muter = VoiceUI.muter(&arguments, context, command: "listen")
        requireAppleIntelligence(for: context.engine)   // 使えなければ、マイクの許可を聞く前に、理由と手順を示して終わる
        guard MicRecorder.authorize() else { fail(MicRecorder.deniedMessage()) }
        let jev = context.loadJev()
        let speech = context.makeSpeechEngine()   // 選んだ音声認識（ダウンロードしたモデルは、ここで読み込む）。終わる前に close
        defer { speech.close() }
        // Ctrl+C などで終わるとき、消したままにしない（録音中に終わっても、音を戻す）。主キューは、readLine や NSApplication で塞がるので、別のキューで受ける
        let signals = VoiceUI.restoreOnSignals(muter, speech)
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

    /// トリガーを押している間だけ録音し（その間、画面の上に「録音中」を出す）、離したら、文字にする。
    /// Tiny-Jev がスキルを選び、Apple の言語モデルが実行する（経過と結果を、画面の上に出す）。当てはまるスキルがなく、既定スキルも使えなければ、実行しない。
    /// --dry-run なら、コマンドを実行しない。確認が要る判定は、問いかけを読み上げ、次の発話の「はい」で実行する。
    /// 聞く・録る・Esc・待ち行列の調整は `VoiceLoop`（VCSpeech）。ここは、発話の処理（`UtteranceHandler`）と、出来事の表示だけを渡す。
    /// 同期の関数：`await` を挟まない（`VoiceLoop.run` の不変条件 1）。
    @MainActor private func runVoiceLoop(_ context: CommandContext, jev: TinyJev, muter: OutputMuter, speech: SpeechEngine) {
        do {
            let session = try VoiceSession.make(context: context, jev: jev, muter: muter, speech: speech)
            withExtendedLifetime(session) { session.loop.run(onReady: session.onReady) }
        } catch { fail("ホットキーを登録できません: \(error)") }
    }

    /// 確認の答え：パネルのボタンと、声の返事の、先に答えたほうが決まる（もう一方は、取りやめる）。
    @MainActor static func askByPanelOrVoice(confirmation: Confirmation, next: @escaping NextUtterance) async throws -> Bool {
        let panel = PanelAnswer()
        HUD.shared.answers.set { panel.resolve($0) }
        defer { HUD.shared.answers.set(nil) }
        return try await ConfirmationRace.decide(panel: panel) {
            guard let answer = try await next() else { return false }
            return try confirmation.isYes(answer)
        }
    }

    /// **聞き取りに自信がないとき**の確認（`vc recheck`）：聞こえた文と確信度を出して、実行するかを聞く。声で頼む以外（音声入力）は、確認しない。
    static func uncertainty(_ context: CommandContext, jev: TinyJev, chips: [String: String], fallbackChip: String) -> Uncertainty? {
        guard context.currentSettings().recheck ?? true else { return nil }
        let confirmation = Confirmation(scorer: jev)
        return Uncertainty(threshold: Recheck.threshold) { text, confidence, _, next, tag in
            if tag == VoiceMode.dictate { return true }
            let isChat = tag == VoiceMode.chat
            let chip = chips[tag] ?? fallbackChip
            say("聞き間違いかもしれません。\(text)でよいですか")
            var content = HUDContent(phase: .confirm, title: "聞き間違いかもしれません", hint: "確信度 \(Int((confidence * 100).rounded()))%。この内容で\(isChat ? "質問" : "実行")しますか？" + ConfirmGuide.howToAnswer, chip: chip, heard: text)
            content.choices = true
            HUD.shared.show(content)
            notice("聞き取りに自信がありません（\(Int((confidence * 100).rounded()))%）。確認待ち：パネルの\(ConfirmGuide.howToAnswer)")
            do {
                let yes = try await askByPanelOrVoice(confirmation: confirmation, next: next)
                if !yes { HUD.shared.show(HUDContent(phase: .info, title: "やめました", chip: chip), hideAfter: 2.5) }
                return yes
            } catch { return false }
        }
    }

    /// 1 回の発話の処理：スキル（`SkillRunner`＋`HUDReporter`）。当てはまるスキルがなく、既定スキルも使えなければ、実行しない（`HUDReporter` が、そう出す）。確認の返事は、`next` で待つ。
    static func utteranceHandler(_ context: CommandContext, jev: TinyJev, chip: String) -> UtteranceHandler {
        let confirmation = Confirmation(scorer: jev)
        let speakResults = context.currentSettings().speakResults ?? false   // 結果の読み上げ（`vc speak on`）
        SaySpeaker.shared.prefer(context.currentSettings().voice)   // 読み上げの声（なければ、自動）
        return { utterance, token, next, _ in
            do {
                guard !utterance.isEmpty else {
                    notice("聞き取れなかった")
                    HUD.shared.show(HUDContent(phase: .failure, title: "聞き取れませんでした", hint: "もう一度、はっきり話してください", chip: chip), hideAfter: 2.5)
                    return
                }
                let skills = context.loadSkills()
                skills.reportProblems()
                let skillRunner = SkillRunner(selection: .resolve(skills: skills.enabled, scorer: jev, gate: context.gate), dryRun: context.options.dryRun, cancel: token, engine: context.engine, scorer: context.scorerProvider(loaded: jev))
                let reporter = HUDReporter(chip: chip, utterance: utterance, dryRun: context.options.dryRun, isSuperseded: { token.isSuperseded }, speakResults: speakResults)
                let planner = context.makePlanner(skills: skills.enabled)
                _ = try await PlanRunner(runner: skillRunner, planner: planner, dryRun: context.options.dryRun, cancel: token).run(utterance, reporter: reporter, confirm: {
                    try await Self.askByPanelOrVoice(confirmation: confirmation, next: next)
                })
            } catch {
                if token.isSuperseded { return }   // 新しい発話に、取って代わられた：何も出さない
                if token.isCancelled || error is CancellationError { VoiceUI.showCancelled(chip: chip) } else { VoiceUI.showFailure(error, chip: chip) }
            }
        }
    }
}
