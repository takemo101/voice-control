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

struct SkillsCommand: Command {
    static let info = CommandInfo(
        name: "skills", group: .skills, summary: "スキルの一覧・詳細・有効／無効・プロジェクトの信頼",
        usage: ["vc skills [list]", "vc skills show <name>", "vc skills enable <name>", "vc skills disable <name>", "vc skills trust", "vc skills untrust"],
        details: [
            "置き場所は 2 つ。グローバル：~/.voice-control/skills/<name>/SKILL.md（環境変数 VC_HOME で ~/.voice-control を変えられる）。プロジェクト：<vc を起動した場所>/.voice-control/skills/<name>/SKILL.md（起動した場所が、プロジェクトのルート）。",
            "同じ名前なら、プロジェクトのスキルが、グローバルを上書きする。",
            "既定スキル（default）：どのスキルにも当てはまらない依頼を、Apple の言語モデルが、agent-desktop と基本のコマンド（open・say・ls・pwd・date）で実行する組み込みのスキル。Tiny-Jev の選択肢には入らない。許可を広げるなら、同じ名前（default）のスキルを置く。使わないなら vc skills disable default。",
            "プロジェクトのスキルは、外から来るもの（リポジトリなど）なので、**信頼したプロジェクトだけ**読み込む。初めは、未信頼で、件数だけを出す。中身（許可するコマンド）を確かめてから、そのプロジェクトで vc skills trust。やめるのは vc skills untrust。信頼は ~/.voice-control/settings.json に、プロジェクトの場所ごとに記録する。",
            "list：name・置き場所・description・有効／無効の一覧。読み込めなかったスキルは、理由つきで、下に出る。",
            "show：許可するコマンド・確認の要否・置き場所・ファイルの場所。",
            "enable / disable：Tiny-Jev の選択肢にするか。既定は有効。設定は ~/.voice-control/settings.json（名前ごと。プロジェクトのスキルも、同じ名前なら、まとめて）。",
            "trust / untrust：起動した場所のプロジェクトのスキルを、読み込んでよいか。trust は、許可するコマンドを表示してから、信頼する。",
        ],
        options: [],
        examples: ["vc skills", "vc skills show open-app", "vc skills disable open-app", "vc skills trust"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc skills [list]               スキルの一覧（name・description・有効／無効）
        // vc skills show <name>          1 つの詳細（許可するコマンド・本文の場所）
        // vc skills enable|disable <name>  Tiny-Jev の選択肢にするか（既定は有効。設定は ~/.voice-control/settings.json）
        let positionals = arguments.positionals
        let sub = positionals.first ?? "list"
        var settings = context.currentSettings()
        let loaded = loadSkills(settings: settings)
        switch sub {
        case "list":
            let enabledCount = loaded.skills.filter { settings.isEnabled($0.name) }.count
            print(Style.bold("スキル") + " \(loaded.skills.count) 件（有効 \(enabledCount)）")
            kv("グローバル", VoiceControlHome.skillsDirectory.path, width: 12)
            if let projectDirectory = loaded.projectDirectory {
                let state = loaded.untrustedProjectCount > 0
                    ? Style.yellow("未信頼：\(loaded.untrustedProjectCount) 件を読み込んでいない。確認して vc skills trust")
                    : Style.green("信頼済み")
                kv("プロジェクト", projectDirectory.path + "（" + state + "）", width: 12)
            } else {
                kv("プロジェクト", Style.dim("なし（\(VoiceControlHome.projectSkillsDirectory(root: VoiceControlHome.launchDirectory).path)）"), width: 12)
            }
            if loaded.skills.isEmpty {
                print("\n  まだありません。\(VoiceControlHome.skillsDirectory.path)/<name>/SKILL.md（全体）か、\(VoiceControlHome.projectSkillsDirectory(root: VoiceControlHome.launchDirectory).path)/<name>/SKILL.md（このプロジェクト）に置きます。")
                print("  作り方: skills/voice-control-skill-author/SKILL.md、書式: docs/skills.md")
            } else {
                let width = max(4, loaded.skills.map { displayWidth($0.name) }.max() ?? 0)
                print("\n  " + Style.dim(pad("状態", to: 6) + pad("name", to: width + 2) + pad("置き場所", to: 14) + "説明"))
                for s in loaded.skills {
                    let on = settings.isEnabled(s.name)
                    let scope: String
                    switch s.scope { case .project: scope = "プロジェクト"; case .builtin: scope = "組み込み"; case .global: scope = "グローバル" }
                    print("  " + (on ? Style.green(pad("有効", to: 6)) : Style.dim(pad("無効", to: 6))) + pad(s.name, to: width + 2) + pad(scope, to: 14) + (on ? s.description : Style.dim(s.description)))
                }
            }
            if !loaded.overridden.isEmpty { notice("プロジェクトのスキルが、同じ名前のグローバルを上書きしている：" + loaded.overridden.joined(separator: "、")) }
            if !loaded.problems.isEmpty {
                print("\n" + Style.yellow("読み込めなかった \(loaded.problems.count) 件"))
                loaded.problems.forEach { print("  \(pad($0.location, to: 18))\($0.reason)") }
            }
        case "show":
            guard positionals.count >= 2 else { usageError("skills", "name を渡してください（例: vc skills show open-app）") }
            guard let s = loaded.skills.first(where: { $0.name == positionals[1] }) else { fail("スキルがありません: \(positionals[1])（一覧：vc skills）") }
            let on = settings.isEnabled(s.name)
            print(Style.bold(s.name) + "  " + (on ? Style.green("有効") : Style.dim("無効")))
            kv("説明", s.description, width: 6)
            kv("許可", s.allowedCommands.joined(separator: "、"), width: 6)
            kv("確認", s.confirm ? "必須" : "なし", width: 6)
            switch s.scope {
            case .project: kv("置き場所", "プロジェクト" + (loaded.overridden.contains(s.name) ? Style.dim("（同名のグローバルを上書き）") : ""), width: 6)
            case .builtin: kv("置き場所", "組み込み", width: 6)
            case .global: kv("置き場所", "グローバル", width: 6)
            }
            if s.scope != .builtin { kv("場所", s.file.path, width: 6) }
        case "enable", "disable":
            guard positionals.count >= 2 else { usageError("skills", "name を渡してください（例: vc skills \(sub) open-app）") }
            guard loaded.skills.contains(where: { $0.name == positionals[1] }) else { fail("スキルがありません: \(positionals[1])（一覧：vc skills）") }
            settings.setEnabled(positionals[1], sub == "enable")
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(sub == "enable" ? Style.green("✓") + " \(positionals[1]) を有効にしました" : Style.dim("−") + " \(positionals[1]) を無効にしました")
        case "trust", "untrust":
            // このプロジェクト（起動した場所）の .voice-control/skills を、読み込んでよいか。外から来たリポジトリのスキルは、許可したコマンドを実行できるので、確認してから信頼する。
            let root = VoiceControlHome.launchDirectory
            let directory = VoiceControlHome.projectSkillsDirectory(root: root)
            if sub == "untrust" {
                settings.setTrusted(project: root, false)
                do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
                print(Style.dim("−") + " 信頼をやめました: \(root.path)")
                break
            }
            let project = SkillStore.load(directory: directory, scope: .project)
            guard !project.skills.isEmpty || !project.problems.isEmpty else { fail("このプロジェクトに、スキルがありません（\(directory.path)）") }
            heading("信頼するプロジェクト")
            kv("場所", root.path, width: 6)
            for s in project.skills {
                print("  " + Style.bold(s.name) + Style.dim("  確認：\(s.confirm ? "必須" : "なし")"))
                print("    許可するコマンド: " + s.allowedCommands.joined(separator: "、"))
            }
            project.problems.forEach { print("  " + Style.yellow("読めない: \($0.location)：\($0.reason)")) }
            settings.setTrusted(project: root, true)
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print("\n" + Style.green("✓") + " 信頼しました。このプロジェクトで vc を起動すると、上のスキルを読み込みます（やめる：vc skills untrust）")
        default:
            usageError("skills", "知らないサブコマンド: \(sub)（list・show・enable・disable・trust・untrust）")
        }
    }
}

struct RunCommand: Command {
    static let info = CommandInfo(
        name: "run", group: .skills, summary: "スキルを選んで、コマンドを実行する",
        usage: ["vc run <依頼> [--skill <name>] [--dry-run] [--yes]"],
        details: [
            "Tiny-Jev が、有効なスキルから、呼ぶものを選ぶ。スキルの本文と依頼文を Apple の言語モデルに渡し、コマンドを実行させる。",
            "実行してよいのは、スキルの allowed-commands に一致するコマンドだけ（シェルは使わない）。実行するコマンドと結果は、すべて表示する。",
            "確信度が 0.70 未満、またはスキルが confirm: true のときは、実行の前に [y/N] で確認する。",
        ],
        options: [
            ("--skill <name>", "Tiny-Jev で選ばず、このスキルを使う（無効なスキルは使えない）"),
            ("--dry-run", "コマンドを実行せず、実行しようとするコマンドだけを表示する（モデルは出力を見られないので、途中は推測になる）"),
            ("--yes", "確認を省略する"),
        ],
        examples: ["vc run \"Safariを開いて\" --dry-run", "vc run \"設定ボタンを押して\" --skill fixture-press --yes"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc run "<依頼>" [--skill <name>] [--dry-run] [--yes]
        // Tiny-Jev が、有効なスキルから、呼ぶものを選び、スキルの本文と依頼文を Apple の言語モデルに渡して、コマンドを実行させる。
        // 実行するコマンドと結果は、すべて表示する。実行してよいコマンドは、スキルの allowed-commands だけ（シェルは使わない）。
        var arguments = arguments
        let dryRun = arguments.flag("--dry-run")
        let forced = arguments.option("--skill")
        guard let request = arguments.positionals.first else { usageError("run", "依頼を渡してください（例: vc run \"Safariを開いて\"）") }
        let settings = context.currentSettings()
        let loaded = loadSkills(settings: settings)
        loaded.problems.forEach { eprint(Style.yellow("スキルを読めない: \($0.location)：\($0.reason)")) }
        warnUntrustedProject(loaded)
        let enabled = loaded.skills.filter { settings.isEnabled($0.name) }
        guard !enabled.isEmpty else { fail("有効なスキルがありません（vc skills で確認）") }

        var skill: Skill
        var confirmReason: String?
        heading("スキルの選択")
        if let forced {
            guard let s = loaded.skills.first(where: { $0.name == forced }) else { fail("スキルがありません: \(forced)（一覧：vc skills）") }
            guard settings.isEnabled(s.name) else { fail("スキル \(forced) は無効です（vc skills enable \(forced)）") }
            skill = s
            confirmReason = s.confirm ? "このスキルは、実行の前に確認が要ります" : nil
            kv("指定", Style.bold(s.name))
        } else {
            let jev = context.loadJev()
            let t0 = Date()
            do {
                switch try SkillResolver(scorer: jev, skills: enabled, gate: context.gate).resolve(request) {
                case let .declined(reason, _):
                    kv("Tiny-Jev", Style.dim("（どのスキルでもない）") + Style.dim("（\(seconds(t0))）"))
                    print("\n  " + Style.dim("→ 実行しない（\(reason)）"))
                    exit(0)
                case let .resolved(r):
                    if r.kind == .matched {
                        kv("Tiny-Jev", Style.bold(r.skill.name) + "  \(pct(r.probability))" + Style.dim("（\(seconds(t0))）"))
                    } else {
                        kv("Tiny-Jev", Style.dim("どのスキルでもない") + " → 既定スキル " + Style.bold(r.skill.name)
                           + Style.dim("（操作の依頼 \(pct(r.probability))・取り消しにくさ \(pct(r.risk ?? 0))・\(seconds(t0))）"))
                    }
                    skill = r.skill
                    confirmReason = r.confirmReason
                }
            } catch { fail("\(error)") }
        }
        kv("説明", skill.description)
        kv("許可", skill.allowedCommands.joined(separator: "、"))

        if let reason = confirmReason {
            notice(reason + "。")
            var approved = context.options.yes
            if !context.options.yes { print("  実行しますか？ [y/N] ", terminator: ""); approved = (readLine() ?? "").lowercased().hasPrefix("y") }
            guard approved else { print("  " + Style.dim("やめた")); exit(0) }
        }

        heading(dryRun ? "実行（dry-run：コマンドは実行しない）" : "実行")
        let agent = SkillAgent(skill: skill, dryRun: dryRun, display: skillDisplay())
        let t1 = Date()
        do {
            let reply = try await agent.run(request: request)
            heading("結果")
            kv("返事", reply)
            kv("所要", seconds(t1) + "・実行したコマンド \(agent.executedCommands.count) 件" + (dryRun ? Style.dim("（dry-run）") : ""))
        } catch { fail("\(error)") }
    }
}

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
                            let skills = enabledSkills(context)
                            if !skills.isEmpty, try await runSkillByVoice(utterance, skills: skills, jev: jev, confirmation: confirmation, gate: context.gate, dryRun: context.options.dryRun, chip: spec.displayName,
                                                                          cancel: token, ask: { try await nextUtterance(token) }) { return }

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
