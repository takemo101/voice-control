import AppKit
import Foundation
import VCCore
import VCDecision
import VCPCControl
import VCSkill
import VCSpeech

// 試す用の CLI。引数を読み、コマンド（`Commands.all`）を探して、実行する。コマンドごとの使い方は、`vc --help`。
// 共通のオプション（`CommonOptions`）：--model <dir>（なければ VC_MODEL_DIR、~/.voice-control/models/tiny-jev-0.6b、./models/tiny-jev-0.6b の順）  --length <tokens>（既定 1024）  --floor <0〜1>  --keys <dir> ほか

@MainActor func runMain() async throws {
    // ヘルプは、モデルの読み込みなど、他の処理より前に出す。
    if Help.handle(Array(CommandLine.arguments.dropFirst())) { exit(0) }
    var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
    let options = CommonOptions(consuming: &arguments)
    guard let name = arguments.command else { print(Help.overview()); exit(0) }
    // `--keys` は、コマンド名を決めたあとに取り除く（`vc --keys <dir> plan …` は、`--keys` がコマンド名になって、不明なコマンドになる）。
    let context = CommandContext.make(options: options, keysDirectory: arguments.option("--keys"))
    guard let command = Commands.find(name) else {
        eprint(Style.errRed("不明なコマンド:") + " \(name)")
        eprint("コマンドの一覧: vc --help")
        exit(2)
    }
    try await command.init().run(arguments, context)
}

try await runMain()

struct PlanCommand: Command {
    static let info = CommandInfo(
        name: "plan", group: .pcControl, summary: "発話から選んだ操作・確率・判定を表示する（実行しない）",
        usage: ["vc plan <発話> [--app <名前>]", "vc plan --audio <ファイル> [--app <名前>]"],
        details: [
            "前面のアプリの画面・アプリ・ショートカット・スクロールなどの候補から、Tiny-Jev が 1 手を選ぶ。複数の手に分けて、それぞれ表示する。",
            "--app を付けなければ、そのとき前面にあるアプリが対象（端末から実行すると、端末自身）。",
        ],
        options: [
            ("--app <名前>", "対象のアプリ"),
            ("--audio <ファイル>", "音声ファイルから文字起こしして、発話にする"),
            ("--llm-split", "Apple の言語モデルで、発話を 1 手ずつに書き直す（既定はルール）"),
            ("--no-context", "前の指示を、文脈に使わない"),
            ("--no-location", "要素の位置情報を、選択肢に添えない"),
            ("--keys <dir>", "キー操作の JSON 定義のディレクトリ"),
        ],
        examples: ["vc plan \"下にスクロールして\"", "vc plan --app Fixture \"削除して\""])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        try await planOrAct("plan", arguments, context)
    }
}

struct ActCommand: Command {
    static let info = CommandInfo(
        name: "act", group: .pcControl, summary: "発話から選んだ操作を実行する",
        usage: ["vc act <発話> [--app <名前>] [--execute] [--yes]", "vc act --audio <ファイル> [--execute] [--yes]"],
        details: [
            "plan と同じ流れ。既定は dry-run（--execute を付けたときだけ、実際に操作する）。",
            "確認が要る判定は、--yes がなければ実行しない。",
        ],
        options: [
            ("--execute", "実際に操作する"),
            ("--yes", "確認が要る判定を、承認する"),
            ("--app <名前> / --audio <ファイル> / --llm-split / --no-context / --no-location / --keys <dir>", "plan と同じ"),
        ],
        examples: ["vc act --app Fixture \"設定を開いて\" --execute"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        try await planOrAct("act", arguments, context)
    }
}

/// `vc plan`・`vc act`：同じ流れ（`act` は、`--execute` で実行する）。
@MainActor func planOrAct(_ command: String, _ arguments: Arguments, _ context: CommandContext) async throws {
    guard arguments.positionals.count >= 1 || context.options.audio != nil else { usageError(command, "発話か --audio <ファイル> を渡してください（例: vc \(command) \"下にスクロールして\"）") }
    let desktop = AgentDesktop(app: context.options.app)
    let planner = Planner(scorer: context.loadJev(), desktop: desktop, gate: context.gate, skills: context.skillCatalog.shortcuts, useLocation: !context.options.noLocation)
    do {
        var utterance = arguments.positionals.first ?? ""
        if let audio = context.options.audio {
            utterance = try await FileTranscriber().transcribe(file: URL(fileURLWithPath: audio))
            kv("聞こえた", utterance)   // 文字起こしの表示は、この検証の端末だけ（ファイルには残さない）
        }
        try await runClauses(await clauses(for: utterance, llmSplit: context.options.llmSplit), planner: planner, desktop: desktop, act: command == "act", context: context, confirm: { _ in context.options.yes })
    } catch { fail("\(error)") }
}

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
        guard MicRecorder.authorize() else { fail("マイクが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）") }
        let desktop = AgentDesktop(app: context.options.app)
        let jev = context.loadJev()
        let planner = Planner(scorer: jev, desktop: desktop, gate: context.gate, skills: context.skillCatalog.shortcuts, useLocation: !context.options.noLocation)
        if context.options.hotkey {
            // トリガーを押している間だけ録音し（その間、画面の上に「録音中」を出す）、離したら、文字にする。
            // 有効なスキルがあれば、Tiny-Jev がスキルを選び、Apple の言語モデルが実行する（経過と結果を、画面の上に出す）。スキルが選ばれなければ、PC 操作（前面のアプリ。--app があればそのアプリ）へ回す。
            // --execute がなければ、実行しない（スキルは dry-run、PC 操作は計画の表示だけ）。確認が要る判定は、問いかけを読み上げ、次の発話の「はい」で実行する。
            let confirmation = Confirmation(scorer: jev)
            let queue = VoiceInputQueue()
            let activity = VoiceActivity()
            let escape = EscapeKey()
            let session = RecordingSession()
            // Esc は、録音中・認識待ち・実行中の間だけ受ける（それ以外は、Esc は、ほかのアプリへそのまま届く）。
            activity.onChange = { active in DispatchQueue.main.async { escape.setActive(active) } }
            do {
                let (spec, _) = context.resolveHotKey()
                let hotkey = try makeTrigger(spec)
                hotkey.onPress = {
                    activity.startRecording()
                    HUD.shared.show(HUDContent(phase: .recording, title: "録音中", hint: "離すと、認識して実行します（Esc で取りやめ）", chip: spec.displayName))
                    session.start(); NSSound(named: "Pop")?.play()
                }
                hotkey.onRelease = {
                    if activity.consumeCancelledRecording() { return }   // Esc で捨てた録音の「離した」
                    NSSound(named: "Tink")?.play()
                    HUD.shared.show(HUDContent(phase: .working, title: "認識中…", hint: "Esc で取りやめ", chip: spec.displayName))
                    // 修飾キーを押している間は、Esc のホットキーを登録できない（実測）。離したあとに、登録し直す（修飾キーが離れるまでの間、数回試す）。
                    for delay in [0.05, 0.3, 0.8, 1.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if activity.isActive { escape.setActive(true) } }
                    }
                    do {
                        if let file = try session.stop() {
                            activity.stopRecording(queuedAudio: true)
                            queue.push(.audio(file))
                        } else {
                            activity.stopRecording(queuedAudio: false)
                            HUD.shared.hide()
                        }
                    } catch {
                        activity.stopRecording(queuedAudio: false)
                        print("録音に失敗: \(error)")
                        HUD.shared.show(HUDContent(phase: .failure, title: "録音に失敗しました", reply: "\(error)"), hideAfter: 4)
                    }
                }
                escape.onEscape = {
                    switch activity.escape() {
                    case .recording:
                        session.discard()
                        print("  " + Style.yellow("録音を取りやめました（Esc）"))
                        HUD.shared.show(HUDContent(phase: .info, title: "録音を取りやめました", chip: spec.displayName), hideAfter: 1.5)
                    case .work:
                        SaySpeaker.shared.stop()
                        queue.push(.cancel)   // 発話や確認の返事を待っている処理を起こす
                        HUD.shared.show(HUDContent(phase: .info, title: "取りやめています…", chip: spec.displayName))
                    case .nothing:
                        break
                    }
                }
                Task {
                    /// 列から取り出した音声を、文字にする。取りやめられていれば nil。
                    func transcribe(_ file: URL, _ token: CancelToken) async throws -> String? {
                        activity.consumedAudio()
                        // try?: 一時の録音ファイルの片付け。消せなくても、結果は変わらない
                        defer { try? FileManager.default.removeItem(at: file) }
                        if token.isCancelled { return nil }
                        let text = try await FileTranscriber().transcribe(file: file)
                        if token.isCancelled { return nil }
                        kv("聞こえた", text)
                        return text
                    }
                    /// 次の発話（確認の返事にも使う）。取りやめられたら nil。
                    func nextUtterance(_ token: CancelToken) async throws -> String? {
                        while true {
                            switch await queue.next() {
                            case .cancel: if token.isCancelled { return nil }   // 前の処理の取りやめの合図は、読み捨てる
                            case let .audio(file): return try await transcribe(file, token)
                            }
                        }
                    }
                    func handle(_ file: URL, _ token: CancelToken) async {
                        do {
                            guard let utterance = try await transcribe(file, token) else { throw CancellationError() }
                            guard !utterance.isEmpty else {
                                notice("聞き取れなかった")
                                HUD.shared.show(HUDContent(phase: .failure, title: "聞き取れませんでした", hint: "もう一度、はっきり話してください", chip: spec.displayName), hideAfter: 2.5)
                                return
                            }
                            let skills = context.loadSkills()
                            skills.reportProblems()
                            if !skills.enabled.isEmpty {
                                let runner = SkillRunner(selection: .resolve(skills: skills.enabled, scorer: jev, gate: context.gate), dryRun: context.options.dryRun, cancel: token)
                                let reporter = HUDReporter(chip: spec.displayName, utterance: utterance, dryRun: context.options.dryRun)
                                let outcome = try await runner.run(utterance, reporter: reporter, confirm: { _ in
                                    guard let answer = try await nextUtterance(token) else { return false }
                                    return try confirmation.isYes(answer)
                                })
                                // 既定スキルも使えず、スキルが選ばれなかったときだけ、PC 操作へ回す
                                guard case .declined(fallbackAvailable: false) = outcome else { return }
                            }

                            // スキルが選ばれなかった（既定スキルも使えない）：PC 操作へ
                            let hud = HUDSession(HUDContent(phase: .working, title: "考え中", chip: spec.displayName, heard: utterance))
                            hud.update()
                            try await runClauses(await clauses(for: utterance, llmSplit: context.options.llmSplit), planner: planner, desktop: desktop, act: true, context: context, hud: hud, cancel: token, confirm: { plan in
                                say("\(plan.step?.spoken ?? "この操作")。実行しますか")
                                notice("確認待ち：もう一度トリガーを押して「はい」と言う")
                                hud.update { $0.phase = .confirm; $0.title = "実行しますか？"; $0.hint = "\(plan.step?.spoken ?? "この操作")　もう一度押して「はい」" }
                                guard let answer = try await nextUtterance(token) else { throw CancellationError() }
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
                            if token.isCancelled || error is CancellationError {
                                print("  " + Style.yellow("取りやめました（Esc）"))
                                HUD.shared.show(HUDContent(phase: .info, title: "取りやめました", chip: spec.displayName), hideAfter: 2)
                            } else {
                                print(Style.red("失敗:") + " \(error)")
                                HUD.shared.show(HUDContent(phase: .failure, title: "失敗", chip: spec.displayName, reply: "\(error)"), hideAfter: 6)
                            }
                        }
                    }
                    while true {
                        guard case let .audio(file) = await queue.next() else { continue }   // 待っている処理がないときの Esc の合図は、読み捨てる
                        let token = CancelToken()
                        activity.beginWork(token)
                        let work = Task { await handle(file, token) }
                        activity.setTask(work)
                        await work.value
                        activity.endWork()
                    }
                }
                print(Style.bold("\(holdInstruction(spec))ている間だけ聞きます") + Style.dim("（Ctrl+C で終了。録音中・実行中に Esc で取りやめ）"))
                kv("スキル", context.options.dryRun ? Style.yellow("実行しない（--dry-run）") : Style.green("実行する"), width: 8)
                kv("PC 操作", context.options.execute ? Style.green("実行する（--execute）") : Style.yellow("実行しない（計画の表示だけ。--execute で実行）"), width: 8)
                fflush(stdout)
                // 準備ができたことを、画面の上に出す（モデルの読み込みの間は、押しても反応しない）。許可がなければ、その旨を出す。
                if spec.isHold && !ModifierHold.isTrusted {
                    HUD.shared.show(HUDContent(phase: .failure, title: "アクセシビリティの許可がありません", hint: "システム設定 > プライバシーとセキュリティ > アクセシビリティで、このターミナルを許可して、開き直してください。許可なしなら vc hotkey set ctrl+opt+space", chip: spec.displayName), hideAfter: 15)
                } else {
                    HUD.shared.show(HUDContent(phase: .info, title: "準備できました", hint: "\(holdInstruction(spec))ている間だけ聞きます", chip: spec.displayName), hideAfter: 3.5)
                }
                NSApplication.shared.setActivationPolicy(.accessory)
                // トリガーは、`run()` が終わるまで、手放さない（最適化で、最後の使用のあとに解放され、ホットキーが死ぬのを防ぐ）。
                withExtendedLifetime((hotkey, escape)) { NSApplication.shared.run() }
            } catch { fail("ホットキーを登録できません: \(error)") }
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
}

struct EvalCommand: Command {
    static let info = CommandInfo(
        name: "eval", group: .evaluation, summary: "固定した画面での、操作の当たり率を測る（実機は操作しない）",
        usage: ["vc eval <plans.tsv> [--speak] [--llm] [--no-location]"],
        details: [
            "コーパスの形：snapshot<TAB>期待<TAB>発話。画面は、コーパスと同じ場所の snapshots/<名前>.json、アプリの一覧は apps.txt。",
            "確認なしで実行してしまった誤りの数も出す。",
        ],
        options: [
            ("--speak", "発話を say で合成し、文字起こしを通す（聞き違いも込みで測る）"),
            ("--llm", "同じ文を、Apple の言語モデルにも選ばせて、比べる"),
            ("--no-location", "位置情報なしで測る（比較用）"),
        ],
        examples: ["vc eval corpus/plans.tsv", "vc eval corpus/plans.tsv --no-location"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // コーパスの形：snapshot<TAB>期待<TAB>発話。期待は open:<アプリ> click:<要素名> type:<文字> press:<キー> scroll:<向き> none。
        // snapshot は corpus/snapshots/<名前>.json（自作の fixture を agent-desktop で撮ったもの）。アプリの一覧は corpus/apps.txt。
        // try?: コーパスが読めなければ、usage を出して終了する
        guard let corpus = arguments.positionals.first, let text = try? String(contentsOfFile: corpus, encoding: .utf8) else { fail("usage: vc eval <plans.tsv>") }
        let dir = URL(fileURLWithPath: corpus).deletingLastPathComponent()
        // try?: apps.txt（アプリ名の一覧）は、なくてもよい（空の一覧で続ける）
        let apps = ((try? String(contentsOf: dir.appendingPathComponent("apps.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let jev = context.loadJev()
        var snapshots: [String: Snapshot] = [:]
        var hits = 0, total = 0, wrongExecuted = 0, positives = 0, positiveExecuted = 0, negatives = 0, negativeLeaked = 0
        var heard = 0, misheard = 0
        var millis: [Double] = []
        var byKind: [String: (hit: Int, total: Int)] = [:]
        var llmHits = 0, llmWrongAny = 0, llmHybridWrongExecuted = 0, llmHybridPositiveExecuted = 0, llmNegativeLeaked = 0
        var llmMillis: [Double] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3 else { continue }
            if snapshots[f[0]] == nil {
                // try?: 読めなければ、すぐ下で fail する（黙って飛ばさない）
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("snapshots/\(f[0]).json")), let s = try? SnapshotParser.parse(data) else { fail("snapshot を読めません: \(f[0])") }
                snapshots[f[0]] = s
            }
            let planner = Planner(scorer: jev, desktop: ReplayDesktop(snapshot: snapshots[f[0]]!, apps: apps), gate: context.gate, skills: context.skillCatalog.shortcuts, useLocation: !context.options.noLocation)
            let t0 = Date()
            let plan: Plan
            var utterance = f[2]
            if context.options.speak {
                // 合成音声（say）→ 文字起こし。聞き違いも込みで測る。合成音声は、きれいなので、実際の声より楽観的。
                do { utterance = try await speakAndTranscribe(f[2]) } catch { fail("\(error)") }
                heard += 1
                if utterance != f[2] { misheard += 1 }
            }
            do { plan = try planner.plan(utterance) } catch { fail("\(error)") }
            millis.append(Date().timeIntervalSince(t0) * 1000)
            // ゲートが捨てたものは、「実行しない」＝ none として扱う。
            let got = plan.verdict == .reject ? "none" : canonical(plan)
            let accepted = f[1].split(separator: "|").map(String.init)   // 同じ結果になる操作が複数あるときは、「|」で並べる
            // 位置つきの期待（「click:Open@右上」）：選んだ要素の、ウィンドウの中の位置も、添えて比べる。
            var gotRegion = got
            if case .click(let e)? = plan.step, let r = e.region(in: snapshots[f[0]]!.window) { gotRegion = got + "@" + r }
            let matches: (String) -> Bool = { $0 == got || $0 == gotRegion }
            let kind = String(accepted[0].split(separator: ":").first ?? "none")
            total += 1
            byKind[kind, default: (0, 0)].total += 1
            if accepted.contains(where: matches) { hits += 1; byKind[kind]!.hit += 1 } else {
                print(Style.red("MISS") + " \(plan.verdict) \(got) ≠ \(f[1]) [\(f[0])]: \(f[2])" + (utterance != f[2] ? " (聞こえ: \(utterance))" : "") + "  ← \(plan.choice) \(Int(plan.probability * 100))%")
                if plan.verdict == .execute { wrongExecuted += 1 }
            }
            if f[1] == "none" { negatives += 1; if plan.verdict != .reject { negativeLeaked += 1 } }
            else { positives += 1; if plan.verdict == .execute && accepted.contains(where: matches) { positiveExecuted += 1 } }
            if context.options.llm {
                // Apple の言語モデル（FoundationModels）に、同じ発話・同じ画面で、次の 1 手を決めさせる。
                let t1 = Date()
                let llm = try LLMPlanner(desktop: ReplayDesktop(snapshot: snapshots[f[0]]!, apps: apps))
                let next: LLMPlanner.Next
                do { next = try await llm.next(utterance: utterance, done: []) } catch { print("LLM 失敗: \(error)"); next = .invalid("失敗") }
                llmMillis.append(Date().timeIntervalSince(t1) * 1000)
                var llmGot = "none"
                if case .step(let s) = next { llmGot = canonicalStep(s) }
                let llmOK = accepted.contains(llmGot)
                if llmOK { llmHits += 1 } else { print(Style.red("LLM-MISS") + " \(llmGot) ≠ \(f[1]) [\(f[0])]: \(f[2])  (\(next))") }
                // 併用：言語モデルの手を使い、Tiny-Jev と一致して、Tiny-Jev のゲートが「実行」のときだけ、確認なしで実行する。
                let agree = llmGot != "none" && llmGot == got
                let silent = agree && plan.verdict == .execute
                if llmGot != "none" && !llmOK && silent { llmHybridWrongExecuted += 1 }
                if llmGot != "none" && !llmOK { llmWrongAny += 1 }
                if f[1] != "none" && llmOK && silent { llmHybridPositiveExecuted += 1 }
                if f[1] == "none" && llmGot != "none" { llmNegativeLeaked += 1 }
            }
        }
        heading("結果（\(total) 文）")
        let w = 14
        if context.options.speak { kv("音声経由", "文字起こしが元の文と違った \(misheard)/\(heard)", width: w) }
        kv("正解", "\(hits)/\(total)  \(pct(Double(hits) / Double(total)))", width: w)
        for (k, v) in byKind.sorted(by: { $0.key < $1.key }) { kv("  " + k, "\(v.hit)/\(v.total)", width: w) }
        let wrong = "\(wrongExecuted) 件" + Style.dim("（確認なしで、違う操作を実行した数）")
        kv("危険な誤り", wrongExecuted > 0 ? Style.red(wrong) : Style.green(wrong), width: w)
        kv("確認なしで実行", "\(positiveExecuted)/\(positives)" + Style.dim("（操作の依頼のうち）"), width: w)
        kv("会話が通った", "\(negativeLeaked)/\(negatives)" + Style.dim("（操作でない発話が、確認か実行へ通った数）"), width: w)
        let sorted = millis.sorted()
        kv("時間", String(format: "中央値 %.0f ms・p95 %.0f ms（1 発話）", sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]), width: w)
        if context.options.llm {
            let ls = llmMillis.sorted()
            heading("Apple の言語モデル（FoundationModels）")
            kv("正解", "\(llmHits)/\(total)  \(pct(Double(llmHits) / Double(total)))", width: w)
            kv("会話に手を返した", "\(llmNegativeLeaked)/\(negatives)", width: w)
            kv("違う手を返した", "\(llmWrongAny)（全体）", width: w)
            kv("併用", "誤って確認なしで実行 \(llmHybridWrongExecuted) 件・確認なしで正しく実行 \(llmHybridPositiveExecuted)/\(positives)" + Style.dim("（Tiny-Jev と一致・ゲート「実行」のときだけ）"), width: w)
            kv("時間", String(format: "中央値 %.0f ms・p95 %.0f ms（1 発話）", ls[ls.count / 2], ls[min(ls.count - 1, Int(Double(ls.count) * 0.95))]), width: w)
        }
    }
}
