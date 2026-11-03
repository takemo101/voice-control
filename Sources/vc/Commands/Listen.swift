import AppKit
import Foundation
import VCCore
import VCDecision
import VCPCControl
import VCSkill
import VCSpeech

struct ListenCommand: Command {
    static let info = CommandInfo(
        name: "listen", group: .pcControl, summary: "マイクから聞いて、スキルまたは PC 操作で実行する",
        usage: ["vc listen [--hotkey] [--trigger <キー>] [--dry-run] [--app <名前>] [--execute] [--yes]"],
        details: [
            "既定：Enter で録音を始め、もう一度 Enter で止める（q で終了）。マイクの許可が要る。",
            "--hotkey：トリガーを押している間だけ録音する。離すと、文字にして、Tiny-Jev がスキルを選び、Apple の言語モデルが実行する（vc run と同じ）。**当てはまるスキルがなければ、既定スキル（default）**が、agent-desktop と基本のコマンド（open・say・ls・pwd・date）で実行する。会話・独り言は、実行しない。取り消しにくい依頼（削除・送信・購入など）は、実行の前に、声の「はい」で確認する。既定スキルを無効にする（vc skills disable default）と、従来の PC 操作へ回す。",
            "画面の上に、録音中・認識中・選んだスキル・実行したコマンドと結果・言語モデルの返事を出す（クリックを通し、フォーカスを奪わない）。",
            "**Esc で取りやめ**：録音中は、録音を捨てる（認識しない）。認識中・実行中・確認の待ちは、処理を止める（実行中のコマンドも止める）。Esc を受けるのは、これらの間だけで、ふだんの Esc には触れない。録音中（Shift などを押している間）の Esc は、アクセシビリティの許可が要る。",
            "実行の既定：スキルは、vc run と同じく、**実行する**（--dry-run を付けたときだけ、表示だけ）。PC 操作（既定スキルも使えないとき）は、**--execute を付けたときだけ**実行する（なければ、計画の表示だけ）。",
            "トリガーは、既定が Shift の長押し。変えるには vc hotkey set <キー>（~/.voice-control/settings.json に保存）か、その回だけ --trigger <キー>。長押し（修飾キーだけ）の検出には、アクセシビリティの許可が要る（vc を動かす端末アプリに）。",
        ],
        options: [
            ("--hotkey", "押している間だけ録音する"),
            ("--trigger <キー>", "この回だけのトリガー（例：shift・ctrl+opt+space・f5。書き方は vc hotkey）"),
            ("--dry-run", "スキルのコマンドを実行せず、表示だけにする"),
            ("--app <名前> / --execute / --yes", "act と同じ（--execute：PC 操作を実行する）"),
        ],
        examples: ["vc listen --hotkey", "vc listen --hotkey --execute", "vc listen --hotkey --dry-run"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc listen [--app <名前>] [--execute] [--hotkey]：既定は、Enter で録音を始め、もう一度 Enter で止める。--hotkey は、トリガー（既定：Shift の長押し。vc hotkey で変更）を押している間だけ録音する。
        // マイクの許可が要る（初回、macOS が確認を出す）。
        // **ここから `VoiceLoop.run` まで、`await` を挟まない**（`NSApplication.run()` の前の `await` は、画面の表示・長押しの判定を止める。docs/architecture.md「時間と並行」）。
        guard MicRecorder.authorize() else { fail("マイクが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）") }
        let desktop = AgentDesktop(app: context.options.app)
        let jev = context.loadJev()
        let planner = Planner(scorer: jev, desktop: desktop, gate: context.gate, skills: context.skillCatalog.shortcuts, useLocation: !context.options.noLocation)
        if context.options.hotkey {
            runVoiceLoop(context, jev: jev, planner: planner, desktop: desktop)
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
                print("録音中… Enter で停止", terminator: "")
                _ = readLine()
                try recorder.stop()
                let utterance = try await FileTranscriber().transcribe(file: file)
                kv("聞こえた", utterance)
                guard !utterance.isEmpty else { notice("聞き取れなかった"); continue }
                try await runClauses(await clauses(for: utterance, llmSplit: context.options.llmSplit), planner: planner, desktop: desktop, act: true, context: context, confirm: { _ in context.options.yes })
            } catch { print(Style.red("失敗:") + " \(error)") }
        }
    }

    /// トリガーを押している間だけ録音し（その間、画面の上に「録音中」を出す）、離したら、文字にする。
    /// 有効なスキルがあれば、Tiny-Jev がスキルを選び、Apple の言語モデルが実行する（経過と結果を、画面の上に出す）。スキルが選ばれなければ、PC 操作（前面のアプリ。--app があればそのアプリ）へ回す。
    /// --execute がなければ、実行しない（スキルは dry-run、PC 操作は計画の表示だけ）。確認が要る判定は、問いかけを読み上げ、次の発話の「はい」で実行する。
    /// 聞く・録る・Esc・待ち行列の調整は `VoiceLoop`（VCSpeech）。ここは、発話の処理（`UtteranceHandler`）と、出来事の表示だけを渡す。
    /// 同期の関数：`await` を挟まない（`VoiceLoop.run` の不変条件 1）。
    @MainActor private func runVoiceLoop(_ context: CommandContext, jev: TinyJev, planner: Planner, desktop: AgentDesktop) {
        do {
            let (spec, _) = context.resolveHotKey()
            let chip = spec.displayName
            let trigger = try makeTrigger(spec)
            let loop = VoiceLoop(
                trigger: trigger, escape: EscapeKey(), recorder: PopRecorder(RecordingSession()), transcriber: FileTranscriber(),
                handler: Self.utteranceHandler(context, jev: jev, planner: planner, desktop: desktop, chip: chip),
                onEvent: { Self.show($0, chip: chip) })
            loop.run {
                print(Style.bold("\(holdInstruction(spec))ている間だけ聞きます") + Style.dim("（Ctrl+C で終了。録音中・実行中に Esc で取りやめ）"))
                kv("スキル", context.options.dryRun ? Style.yellow("実行しない（--dry-run）") : Style.green("実行する"), width: 8)
                kv("PC 操作", context.options.execute ? Style.green("実行する（--execute）") : Style.yellow("実行しない（計画の表示だけ。--execute で実行）"), width: 8)
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
    private static func show(_ event: VoiceLoopEvent, chip: String) {
        switch event {
        case .recordingStarted:
            HUD.shared.show(HUDContent(phase: .recording, title: "録音中", hint: "離すと、認識して実行します（Esc で取りやめ）", chip: chip))
        case .recordingDiscarded:
            print("  " + Style.yellow("録音を取りやめました（Esc）"))
            HUD.shared.show(HUDContent(phase: .info, title: "録音を取りやめました", chip: chip), hideAfter: 1.5)
        case .recognizing:
            NSSound(named: "Tink")?.play()
            HUD.shared.show(HUDContent(phase: .working, title: "認識中…", hint: "Esc で取りやめ", chip: chip))
        case .recordingEmpty:
            HUD.shared.hide()
        case let .recordingFailed(error):
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

    /// 1 回の発話の処理：スキル（`SkillRunner`＋`HUDReporter`）→ スキルが選ばれなければ、PC 操作。確認の返事は、`next` で待つ。
    private static func utteranceHandler(_ context: CommandContext, jev: TinyJev, planner: Planner, desktop: AgentDesktop, chip: String) -> UtteranceHandler {
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
                if !skills.enabled.isEmpty {
                    let runner = SkillRunner(selection: .resolve(skills: skills.enabled, scorer: jev, gate: context.gate), dryRun: context.options.dryRun, cancel: token)
                    let reporter = HUDReporter(chip: chip, utterance: utterance, dryRun: context.options.dryRun)
                    let outcome = try await runner.run(utterance, reporter: reporter, confirm: {
                        guard let answer = try await next() else { return false }
                        return try confirmation.isYes(answer)
                    })
                    // 既定スキルも使えず、スキルが選ばれなかったときだけ、PC 操作へ回す
                    guard case .declined(fallbackAvailable: false) = outcome else { return }
                }

                // スキルが選ばれなかった（既定スキルも使えない）：PC 操作へ
                let hud = HUDSession(HUDContent(phase: .working, title: "考え中", chip: chip, heard: utterance))
                hud.update()
                try await runClauses(await clauses(for: utterance, llmSplit: context.options.llmSplit), planner: planner, desktop: desktop, act: true, context: context, hud: hud, cancel: token, confirm: { plan in
                    say("\(plan.step?.spoken ?? "この操作")。実行しますか")
                    notice("確認待ち：もう一度トリガーを押して「はい」と言う")
                    hud.update { $0.phase = .confirm; $0.title = "実行しますか？"; $0.hint = "\(plan.step?.spoken ?? "この操作")　もう一度押して「はい」" }
                    guard let answer = try await next() else { throw CancellationError() }
                    let yes = try confirmation.isYes(answer)
                    hud.update { $0.phase = .working; $0.title = "実行中"; $0.hint = nil }
                    return yes
                })
                hud.update(hideAfter: 3) { content in
                    let done = content.steps.contains { if case .ok = $0.status { return true } else { return false } }
                    content.phase = done ? .success : .info
                    content.title = done ? "完了" : "実行しませんでした"
                    content.hint = nil
                }
            } catch {
                if token.isCancelled || error is CancellationError { showCancelled(chip: chip) } else { showFailure(error, chip: chip) }
            }
        }
    }
}

/// 録音を始めたあとに、開始の音（Pop）を鳴らす（録音の開始 → 音、の順を保つ。`VoiceLoop` は、音を知らない）。
private final class PopRecorder: Recording, @unchecked Sendable {
    private let base: Recording
    init(_ base: Recording) { self.base = base }

    func start() {
        base.start()
        NSSound(named: "Pop")?.play()
    }

    func discard() { base.discard() }
    func stop() throws -> URL? { try base.stop() }
}
