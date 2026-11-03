import AppKit
import Foundation
import VoiceControlKit

// 試す用の CLI。
//   vc plan "<発話>" [--app <名前>]     選んだ操作・確率・ゲートの判定だけを出す（実行しない）
//   vc act  "<発話>" [--app <名前>] [--execute] [--yes]   --execute で実行。確認が要る判定は --yes も要る
//   vc eval corpus/plans.tsv            固定した画面での、操作の当たり率（実機を操作しない）
// 共通：--model <dir>（なければ VC_MODEL_DIR、~/.voice-control/models/tiny-jev-0.6b、./models/tiny-jev-0.6b の順）  --length <tokens>（既定 1024）


// ヘルプは、モデルの読み込みなど、他の処理より前に出す。
if Help.handle(Array(CommandLine.arguments.dropFirst())) { exit(0) }
var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
/// モデルの場所：--model、環境変数 VC_MODEL_DIR、~/.voice-control/models/tiny-jev-0.6b（`vc model download` の置き場所）、./models/tiny-jev-0.6b（開発用）の順に、最初に tokenizer.json があるもの。
/// 使うときまで解決しない（`vc skills` などは、モデルがなくても動く）。
let modelOption = option("--model")
func resolveModelDir() -> URL {
    let candidates = [modelOption, ProcessInfo.processInfo.environment["VC_MODEL_DIR"], ModelStore.defaultDirectory().path, "models/tiny-jev-0.6b"].compactMap { $0 }.filter { !$0.isEmpty }
    let found = candidates.first { FileManager.default.fileExists(atPath: $0 + "/tokenizer.json") }
    guard let found else { fail("モデルが見つかりません（探した場所: \(candidates.joined(separator: ", "))）。vc model download で取得") }
    return URL(fileURLWithPath: found)
}
let length = option("--length").flatMap(Int.init) ?? 1024
let appName = option("--app")
let execute = flag("--execute"), yes = flag("--yes"), speak = flag("--speak"), hotkeyMode = flag("--hotkey"), llmMode = flag("--llm"), llmSplit = flag("--llm-split"), noContext = flag("--no-context"), noLocation = flag("--no-location")
let audioFile = option("--audio")
let triggerOption = option("--trigger")
/// 声の流れ（`vc listen --hotkey`）で、スキルのコマンドを実行せず、表示だけにするか（`vc run` の `--dry-run` と同じ）。
let dryRunRequested = args.contains("--dry-run")
/// これまでに実行した手（前の指示を、次の判断の文脈に使う）。`--no-context` なら、使わない。
let sessionHistory = HistoryStore()
var gate = Gate()
if let f = option("--floor").flatMap(Double.init) { gate.floor = f }
guard let command = args.first else { print(Help.overview()); exit(0) }

func loadJev() -> TinyJev {
    do {
        let t0 = Date()
        let jev = try TinyJev(directory: resolveModelDir(), length: length)
        _ = try jev.choose(state: "テスト", question: "テスト", options: ["a", "b"])  // グラフのコンパイルを、計測の外へ出す
        eprint(Style.dim(String(format: "model loaded %.1fs (length %d)", Date().timeIntervalSince(t0), length)))
        return jev
    } catch {
        fail("モデルを読めません: \(error)（vc model download で取得）")
    }
}


func describe(_ plan: Plan) {
    kv("選択", "\(plan.choice)  \(pct(plan.probability))" + Style.dim("（採点 \(plan.rounds) 回）"))
    if let risk = plan.risk { kv("危険度", pct(risk) + Style.dim("（取り消しにくい確率）")) }
    if let step = plan.step { kv("手", step.summary) }
    let verdict: String
    switch plan.verdict {
    case .execute: verdict = Style.green("✓ 実行")
    case .confirm: verdict = Style.yellow("? 確認が要る")
    case .reject: verdict = Style.red("✗ 実行しない")
    }
    kv("判定", verdict + (plan.rejection.map { Style.dim("（\($0)）") } ?? ""))
    if let note = plan.note { notice(note) }
}

/// 利用者が足したキー操作の定義（JSON。`vc plan`・`vc act` の候補）。`--keys <dir>`、`VC_KEYS_DIR`、`./keys`、`~/.voice-control/keys` の、あるものを全部読む。
let skillCatalog: SkillCatalog.Loaded = {
    let support = VoiceControlHome.root.appendingPathComponent("keys").path
    let dirs = [option("--keys"), ProcessInfo.processInfo.environment["VC_KEYS_DIR"], "keys", support].compactMap { $0 }.filter { !$0.isEmpty }
    var seen = Set<String>()
    let unique = dirs.map { URL(fileURLWithPath: $0).standardizedFileURL }.filter { seen.insert($0.path).inserted }
    let loaded = SkillCatalog.load(directories: unique)
    for p in loaded.problems { FileHandle.standardError.write(Data("skill: \(p)\n".utf8)) }
    return loaded
}()

/// トリガー（押している間だけ聞く）：`--trigger` → `~/.voice-control/settings.json` の `hotkey` → 既定（`shift` の長押し）。書き方は `HotKeySpec`。
func resolveHotKey() -> (spec: HotKeySpec, source: String) {
    if let triggerOption {
        switch HotKeySpec.parse(triggerOption) {
        case let .success(spec): return (spec, "--trigger")
        case let .failure(f): fail("--trigger \(triggerOption): \(f.reason)")
        }
    }
    let settings = Settings.load()
    switch settings.hotkeySpec {
    case let .success(spec): return (spec, settings.hotkey == nil ? "既定" : "設定")
    case let .failure(f): fail("settings.json の hotkey「\(settings.hotkey ?? "")」: \(f.reason)（vc hotkey set で直す）")
    }
}

/// 押している間だけ聞く入り口。長押し（修飾キーだけ）には、アクセシビリティの許可が要る。
func makeTrigger(_ spec: HotKeySpec) throws -> PushToTalkTrigger {
    if spec.isHold && !ModifierHold.isTrusted {
        notice("\(spec.displayName) の長押しの検出には、アクセシビリティの許可が要ります。許可がないと、何も届きません")
        notice("システム設定 > プライバシーとセキュリティ > アクセシビリティで、vc を動かしているターミナルを許可し、そのターミナルを開き直す。許可なしで使うなら、vc hotkey set ctrl+opt+space")
    }
    return try spec.makeTrigger()
}

/// 使い方の文の頭（「…て、離す」「…ている間だけ聞きます」につなぐ）。
func holdInstruction(_ spec: HotKeySpec) -> String {
    spec.isHold ? "\(spec.description) を単独で 0.35 秒以上押し続け" : "\(spec.description) を押し"
}

/// 読み上げる（確認の問いかけ）。終わるまで待たない。
func say(_ text: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "Kyoko", text]
    try? p.run()
}

/// 文を、合成音声（say）にして、オンデバイスで文字起こしする。
func speakAndTranscribe(_ text: String) async throws -> String {
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vc-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: file) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "Kyoko", "-o", file.path, text]
    try p.run()
    p.waitUntilExit()
    return try await FileTranscriber().transcribe(file: file)
}

/// 「scroll:down」「window:maximize」「press:cmd+c」「click:名前」「open:アプリ」→ `Step`（eval-context 用）。
func stepFromCanonical(_ s: String, snapshot: Snapshot) -> Step? {
    let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    switch parts[0] {
    case "scroll": return ScrollDirection(rawValue: parts[1]).flatMap { d in snapshot.elements.first(where: \.isScrollable).map { .scroll(d, $0) } }
    case "window": return WindowAction(rawValue: parts[1]).map { .window($0, app: snapshot.app) }
    case "press": return Shortcut.all.first { $0.combo == parts[1] }.map { .press($0) }
    case "click": return snapshot.elements.first { $0.name == parts[1] && $0.canClick }.map { .click($0) }
    case "open": return .openApp(parts[1])
    default: return nil
    }
}

/// 結果を、コーパスの「期待」と同じ形の文字にする。
func canonical(_ plan: Plan) -> String { canonicalStep(plan.step) }

func canonicalStep(_ step: Step?) -> String {
    switch step {
    case nil: return "none"
    case .openApp(let n)?: return "open:" + n
    case .click(let e)?: return "click:" + e.name   // 位置つきの期待（「click:Open@右上」）は、eval が別に比べる
    case .type(let t, _)?: return "type:" + t
    case .press(let s)?: return "press:" + s.combo
    case .scroll(let d, _)?: return "scroll:" + d.rawValue
    case .window(let a, _)?: return "window:" + a.rawValue
    case .search(let q, _)?: return "search:" + q
    case .element(let v, let e)?: return v.rawValue + ":" + e.name
    case .closeApp(let n)?: return "close:" + n
    }
}

/// 発話を、1 手ずつに分ける。既定はルール（`ClauseSplitter`）。`--llm-split` なら、言語モデル（FoundationModels）で書き直す（使えない・失敗のときは、ルール）。
func clauses(for utterance: String) async -> [String] {
    guard llmSplit else { return ClauseSplitter.split(utterance) }
    do {
        let steps = try await LLMDecomposer().steps(for: utterance)
        if !steps.isEmpty { print("言語モデルで分けた：" + steps.joined(separator: " ／ ")); return steps }
    } catch { print("言語モデルで分けられない（\(error)）。ルールで分ける") }
    return ClauseSplitter.split(utterance)
}

/// 発話を 1 手ずつに分け、順に、計画し、（act かつ --execute なら）実行する。前の手を実行したあとの画面で、次の手を計画する。
/// どれかの手が「実行しない」になれば、残りも中止する。確認が要る手は、`confirm` が true を返したときだけ実行する。
/// 実行しない（plan・--execute なし）ときは、いまの画面で、各手を計画して見せるだけ（前の手の結果は、反映されない）。
func runClauses(_ clauses: [String], planner: Planner, desktop: AgentDesktop, act: Bool, hud: HUDSession? = nil, confirm: (Plan) async throws -> Bool) async throws {
    for (i, clause) in clauses.enumerated() {
        let more = i + 1 < clauses.count
        heading(clauses.count > 1 ? "[\(i + 1)/\(clauses.count)] \(clause)" : clause)
        let plan = try planner.plan(clause, history: noContext ? [] : sessionHistory.entries)
        describe(plan)
        guard let step = plan.step, plan.verdict != .reject else {
            print("  " + Style.dim("→ 実行しない" + (more ? "（残りも中止）" : "")))
            hud?.update { $0.steps.append(.init(command: "\(plan.choice)", status: .denied, output: plan.rejection ?? "確信が足りないので、実行しません")) }
            return
        }
        guard act, execute else {
            if act { print("  " + Style.dim("dry-run：実行していない（--execute で実行）")) }
            hud?.update { $0.steps.append(.init(command: step.summary, status: .denied, output: "実行していません（--execute なし）")) }
            continue
        }
        if plan.verdict == .confirm, !(try await confirm(plan)) {
            print("  " + Style.yellow("やめた（確認が取れない）" + (more ? "。残りも中止" : "")))
            hud?.update { $0.steps.append(.init(command: step.summary, status: .denied, output: "やめました")) }
            return
        }
        hud?.update { $0.steps.append(.init(command: step.summary)) }
        try desktop.perform(step)
        sessionHistory.append(Executed(step: step))
        print("  " + Style.green("✓ done"))
        hud?.update { if let last = $0.steps.indices.last { $0.steps[last].status = .ok } }
        if more { try await Task.sleep(nanoseconds: 800_000_000) }   // 画面が落ち着くのを待つ
    }
}

/// 有効なスキル（`~/.voice-control/skills` を、そのつど読み直す。起動したまま、足したり、有効・無効を変えたりできる）。読めなかったものは、理由を出す。
func enabledSkills() -> [Skill] {
    let loaded = SkillStore.load()
    loaded.problems.forEach { eprint(Style.yellow("スキルを読めない: \($0.location)：\($0.reason)")) }
    let settings = Settings.load()
    return loaded.skills.filter { settings.isEnabled($0.name) }
}

/// スキルの実行の表示（ターミナル）。`hud` があれば、画面の上の表示にも、コマンドと結果を出す。
func skillDisplay(hud: HUDSession? = nil) -> SkillAgent.Display {
    .init(
        onCommand: { command in
            print("  " + Style.bold("$ " + command))
            hud?.update { $0.steps.append(.init(command: command)) }
        },
        onResult: { code, output in
            print("    " + (code == 0 ? Style.green("✓ exit 0") : Style.red("✗ exit \(code)")))
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.prefix(8) { print("    " + Style.dim("│ ") + line) }
            if lines.count > 8 { print("    " + Style.dim("… 他 \(lines.count - 8) 行")) }
            hud?.update { content in
                guard let last = content.steps.indices.last else { return }
                content.steps[last].status = code == 0 ? .ok : .failed(code)
                content.steps[last].output = HUDSession.firstLine(output)
            }
        },
        onDenied: { command, reason in
            print("  " + Style.red("✗ 拒否: ") + command + Style.dim("  — " + reason))
            hud?.update { $0.steps.append(.init(command: command, status: .denied, output: reason)) }
        })
}

/// 声の依頼を、スキルで実行する（スキルを選ぶ → 必要なら声で確認 → 言語モデルがコマンドを実行 → 経過と結果を、画面の上に出す）。
/// Tiny-Jev がスキルを選ばなければ false を返す（呼び出し側が、PC 操作へ回す）。
func runSkillByVoice(_ utterance: String, skills: [Skill], jev: TinyJev, confirmation: Confirmation, gate: Gate, dryRun: Bool, chip: String,
                     ask: () async throws -> String?) async throws -> Bool {
    let t0 = Date()
    let routed = try SkillRouter(scorer: jev, skills: skills).route(utterance)
    kv("Tiny-Jev", (routed.skill.map { Style.bold($0.name) } ?? Style.dim("（どれでもない）")) + "  \(pct(routed.probability))" + Style.dim("（\(seconds(t0))）"))
    guard let skill = routed.skill, routed.probability >= gate.floor else { return false }
    kv("許可", skill.allowedCommands.joined(separator: "、"))

    let hud = HUDSession(HUDContent(phase: .working, title: dryRun ? "確認のみ（--dry-run）" : "実行中", chip: chip, heard: utterance, skill: skill.name))
    hud.update()
    if skill.confirm || routed.probability < gate.execute {
        say("\(skill.name)を実行しますか")
        notice("確認待ち：もう一度トリガーを押して「はい」と言う")
        hud.update { $0.phase = .confirm; $0.title = "実行しますか？"; $0.hint = "もう一度トリガーを押して、「はい」と言う" }
        guard let answer = try await ask(), try confirmation.isYes(answer) else {
            print("  " + Style.dim("やめた"))
            hud.update(hideAfter: 2.5) { $0.phase = .info; $0.title = "やめました"; $0.hint = nil }
            return true
        }
        hud.update { $0.phase = .working; $0.title = dryRun ? "確認のみ（--dry-run）" : "実行中"; $0.hint = nil }
    }

    let agent = SkillAgent(skill: skill, dryRun: dryRun, display: skillDisplay(hud: hud))
    let t1 = Date()
    do {
        let reply = try await agent.run(request: utterance)
        kv("返事", reply)
        kv("所要", seconds(t1) + "・実行したコマンド \(agent.executedCommands.count) 件" + (dryRun ? Style.dim("（dry-run）") : ""))
        hud.update(hideAfter: HUDSession.readingTime(for: reply)) {
            if dryRun {
                // 実行していないので、成功（緑）にしない。言語モデルの返事は、実行したかのように書くことがある。
                $0.phase = .info
                $0.title = "実行していません（--dry-run）"
                $0.reply = "コマンドは実行していません。\n" + reply
            } else {
                $0.phase = .success
                $0.title = "完了"
                $0.reply = reply
            }
        }
    } catch {
        print(Style.red("失敗:") + " \(error)")
        hud.update(hideAfter: 7) { $0.phase = .failure; $0.title = "失敗"; $0.reply = "\(error)" }
    }
    return true
}

switch command {
case "plan", "act":
    guard args.count >= 2 || audioFile != nil else { usageError(command, "発話か --audio <ファイル> を渡してください（例: vc \(command) \"下にスクロールして\"）") }
    let desktop = AgentDesktop(app: appName)
    let planner = Planner(scorer: loadJev(), desktop: desktop, gate: gate, skills: skillCatalog.shortcuts, useLocation: !noLocation)
    do {
        var utterance = args.count >= 2 ? args[1] : ""
        if let audio = audioFile {
            utterance = try await FileTranscriber().transcribe(file: URL(fileURLWithPath: audio))
            kv("聞こえた", utterance)   // 文字起こしの表示は、この検証の端末だけ（ファイルには残さない）
        }
        try await runClauses(await clauses(for: utterance), planner: planner, desktop: desktop, act: command == "act", confirm: { _ in yes })
    } catch { fail("\(error)") }

case "listen":
    // vc listen [--app <名前>] [--execute] [--hotkey]：既定は、Enter で録音を始め、もう一度 Enter で止める。--hotkey は、トリガー（既定：Shift の長押し。vc hotkey で変更）を押している間だけ録音する。
    // マイクの許可が要る（初回、macOS が確認を出す）。
    guard MicRecorder.authorize() else { fail("マイクが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）") }
    let desktop = AgentDesktop(app: appName)
    let jev = loadJev()
    let planner = Planner(scorer: jev, desktop: desktop, gate: gate, skills: skillCatalog.shortcuts, useLocation: !noLocation)
    if hotkeyMode {
        // トリガーを押している間だけ録音し（その間、画面の上に「録音中」を出す）、離したら、文字にする。
        // 有効なスキルがあれば、Tiny-Jev がスキルを選び、Apple の言語モデルが実行する（経過と結果を、画面の上に出す）。スキルが選ばれなければ、PC 操作（前面のアプリ。--app があればそのアプリ）へ回す。
        // --execute がなければ、実行しない（スキルは dry-run、PC 操作は計画の表示だけ）。確認が要る判定は、問いかけを読み上げ、次の発話の「はい」で実行する。
        let confirmation = Confirmation(scorer: jev)
        let (files, filesIn) = AsyncStream<URL>.makeStream()
        let session = RecordingSession()
        do {
            let (spec, _) = resolveHotKey()
            let hotkey = try makeTrigger(spec)
            hotkey.onPress = {
                HUD.shared.show(HUDContent(phase: .recording, title: "録音中", hint: "離すと、認識して実行します", chip: spec.displayName))
                session.start(); NSSound(named: "Pop")?.play()
            }
            hotkey.onRelease = {
                NSSound(named: "Tink")?.play()
                HUD.shared.show(HUDContent(phase: .working, title: "認識中…", chip: spec.displayName))
                do {
                    if let file = try session.stop() { filesIn.yield(file) } else { HUD.shared.hide() }
                } catch {
                    print("録音に失敗: \(error)")
                    HUD.shared.show(HUDContent(phase: .failure, title: "録音に失敗しました", reply: "\(error)"), hideAfter: 4)
                }
            }
            Task {
                var iterator = files.makeAsyncIterator()
                /// 次の発話（確認の返事にも使う）。
                func nextUtterance() async throws -> String? {
                    guard let file = await iterator.next() else { return nil }
                    defer { try? FileManager.default.removeItem(at: file) }
                    let text = try await FileTranscriber().transcribe(file: file)
                    kv("聞こえた", text)
                    return text
                }
                while true {
                    do {
                        guard let utterance = try await nextUtterance() else { break }
                        guard !utterance.isEmpty else {
                            notice("聞き取れなかった")
                            HUD.shared.show(HUDContent(phase: .failure, title: "聞き取れませんでした", hint: "もう一度、はっきり話してください", chip: spec.displayName), hideAfter: 2.5)
                            continue
                        }
                        let skills = enabledSkills()
                        if !skills.isEmpty, try await runSkillByVoice(utterance, skills: skills, jev: jev, confirmation: confirmation, gate: gate, dryRun: dryRunRequested, chip: spec.displayName, ask: nextUtterance) { continue }

                        // スキルが選ばれなかった（または、スキルがない）：PC 操作へ
                        let hud = HUDSession(HUDContent(phase: .working, title: "考え中", chip: spec.displayName, heard: utterance))
                        hud.update()
                        try await runClauses(await clauses(for: utterance), planner: planner, desktop: desktop, act: true, hud: hud, confirm: { plan in
                            say("\(plan.step?.spoken ?? "この操作")。実行しますか")
                            notice("確認待ち：もう一度トリガーを押して「はい」と言う")
                            hud.update { $0.phase = .confirm; $0.title = "実行しますか？"; $0.hint = "\(plan.step?.spoken ?? "この操作")　もう一度押して「はい」" }
                            guard let answer = try await nextUtterance() else { return false }
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
                        print(Style.red("失敗:") + " \(error)")
                        HUD.shared.show(HUDContent(phase: .failure, title: "失敗", chip: spec.displayName, reply: "\(error)"), hideAfter: 6)
                    }
                }
            }
            print(Style.bold("\(holdInstruction(spec))ている間だけ聞きます") + Style.dim("（Ctrl+C で終了）"))
            kv("スキル", dryRunRequested ? Style.yellow("実行しない（--dry-run）") : Style.green("実行する"), width: 8)
            kv("PC 操作", execute ? Style.green("実行する（--execute）") : Style.yellow("実行しない（計画の表示だけ。--execute で実行）"), width: 8)
            fflush(stdout)
            // 準備ができたことを、画面の上に出す（モデルの読み込みの間は、押しても反応しない）。許可がなければ、その旨を出す。
            if spec.isHold && !ModifierHold.isTrusted {
                HUD.shared.show(HUDContent(phase: .failure, title: "アクセシビリティの許可がありません", hint: "システム設定 > プライバシーとセキュリティ > アクセシビリティで、このターミナルを許可して、開き直してください。許可なしなら vc hotkey set ctrl+opt+space", chip: spec.displayName), hideAfter: 15)
            } else {
                HUD.shared.show(HUDContent(phase: .info, title: "準備できました", hint: "\(holdInstruction(spec))ている間だけ聞きます", chip: spec.displayName), hideAfter: 3.5)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
            // トリガーは、`run()` が終わるまで、手放さない（最適化で、最後の使用のあとに解放され、ホットキーが死ぬのを防ぐ）。
            withExtendedLifetime(hotkey) { NSApplication.shared.run() }
        } catch { fail("ホットキーを登録できません: \(error)") }
    }
    while true {
        print("\n" + Style.bold("Enter で録音開始（q で終了）> "), terminator: "")
        guard let line = readLine(), line != "q" else { break }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vc-\(UUID().uuidString).caf")
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
            try await runClauses(await clauses(for: utterance), planner: planner, desktop: desktop, act: true, confirm: { _ in yes })
        } catch { print(Style.red("失敗:") + " \(error)") }
    }

case "llm":
    // vc llm <snapshot.json> <発話>：言語モデルが選ぶ次の 1 手を見る（VC_LLM_DEBUG=1 で、生の出力も）。
    guard args.count >= 3, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])), let snap = try? SnapshotParser.parse(data) else { fail("usage: vc llm <snapshot.json> <発話>") }
    let apps = ((try? String(contentsOfFile: "corpus/apps.txt", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    do { print(try await LLMPlanner(desktop: ReplayDesktop(snapshot: snap, apps: apps)).next(utterance: args[2], done: [])) } catch { fail("\(error)") }

case "decompose":
    // vc decompose <発話>：長い依頼の分け方を、ルール（ClauseSplitter）と言語モデル（FoundationModels）で比べる。
    guard args.count >= 2 else { usageError("decompose", "発話を渡してください") }
    heading("ルール")
    for (i, c) in ClauseSplitter.split(args[1]).enumerated() { print("  \(i + 1). \(c)") }
    do {
        let t0 = Date()
        let steps = try await LLMDecomposer().steps(for: args[1])
        heading("言語モデル" + Style.dim("（\(seconds(t0))）"))
        for (i, c) in steps.enumerated() { print("  \(i + 1). \(c)") }
    } catch { fail("\(error)") }

case "eval-context":
    // vc eval-context corpus/followups.tsv：前の指示を、文脈に使うときと、使わないときの、当たり率。
    // コーパスの形：snapshot<TAB>直前の操作<TAB>期待<TAB>発話（操作の書き方は、eval と同じ）。
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { fail("usage: vc eval-context <followups.tsv>") }
    let dir = URL(fileURLWithPath: args[1]).deletingLastPathComponent()
    let apps = ((try? String(contentsOf: dir.appendingPathComponent("apps.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    let jev = loadJev()
    var hitsWith = 0, hitsWithout = 0, total = 0, wrongSilentWith = 0, wrongSilentWithout = 0
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, let data = try? Data(contentsOf: dir.appendingPathComponent("snapshots/\(f[0]).json")), let snap = try? SnapshotParser.parse(data) else { continue }
        guard let prev = stepFromCanonical(f[1], snapshot: snap) else { fail("直前の操作を作れません: \(f[1])") }
        let planner = Planner(scorer: jev, desktop: ReplayDesktop(snapshot: snap, apps: apps), gate: gate, skills: skillCatalog.shortcuts, useLocation: !noLocation)
        let accepted = f[2].split(separator: "|").map(String.init)
        total += 1
        var row = "\(f[1]) → \(f[3])"
        for (name, history) in [("文脈あり", [Executed(step: prev)]), ("文脈なし", [])] {
            let plan = try planner.plan(f[3], history: history)
            let got = plan.verdict == .reject ? "none" : canonical(plan)
            let ok = accepted.contains(got)
            if name == "文脈あり" { if ok { hitsWith += 1 } else if plan.verdict == .execute { wrongSilentWith += 1 } }
            else { if ok { hitsWithout += 1 } else if plan.verdict == .execute { wrongSilentWithout += 1 } }
            row += "  [\(name): \(ok ? "○" : "×") \(got) \(plan.verdict)]"
        }
        print(row + "  （期待 \(f[2])）")
    }
    heading("結果（\(total) 文）")
    kv("文脈あり", "\(hitsWith)/\(total)" + Style.dim("（確認なしの誤り \(wrongSilentWith) 件）"), width: 10)
    kv("文脈なし", "\(hitsWithout)/\(total)" + Style.dim("（確認なしの誤り \(wrongSilentWithout) 件）"), width: 10)

case "keys":
    // vc keys：組み込みのキー操作と、足した定義（JSON。`vc plan`・`vc act` のショートカットの候補）の一覧。
    print(Style.bold("キー操作") + "  組み込み \(Shortcut.all.count) 件・足した定義 \(skillCatalog.shortcuts.count) 件")
    let optionWidth = (skillCatalog.shortcuts.map { displayWidth($0.option) }.max() ?? 0) + 2
    for s in skillCatalog.shortcuts {
        print("  " + pad(s.option, to: optionWidth) + Style.dim("keys=\(s.combo)\(s.app.map { "  app=\($0)" } ?? "")\(s.when.map { "  when=\($0)" } ?? "")") + (s.needsConfirmation ? Style.yellow("  確認つき") : ""))
    }
    if !skillCatalog.problems.isEmpty {
        print("\n" + Style.yellow("読み込めなかった \(skillCatalog.problems.count) 件"))
        skillCatalog.problems.forEach { print("  \($0)") }
    }

case "skills":
    // vc skills [list]               スキルの一覧（name・description・有効／無効）
    // vc skills show <name>          1 つの詳細（許可するコマンド・本文の場所）
    // vc skills enable|disable <name>  Tiny-Jev の選択肢にするか（既定は有効。設定は ~/.voice-control/settings.json）
    let sub = args.count >= 2 ? args[1] : "list"
    let loaded = SkillStore.load()
    var settings = Settings.load()
    switch sub {
    case "list":
        let enabledCount = loaded.skills.filter { settings.isEnabled($0.name) }.count
        print(Style.bold("スキル") + " \(loaded.skills.count) 件（有効 \(enabledCount)）  " + Style.dim(VoiceControlHome.skillsDirectory.path))
        if loaded.skills.isEmpty {
            print("\n  まだありません。\(VoiceControlHome.skillsDirectory.path)/<name>/SKILL.md に置きます。")
            print("  作り方: skills/voice-control-skill-author/SKILL.md、書式: docs/skills.md")
        } else {
            let width = max(4, loaded.skills.map { displayWidth($0.name) }.max() ?? 0)
            print("\n  " + Style.dim(pad("状態", to: 6) + pad("name", to: width + 2) + "説明"))
            for s in loaded.skills {
                let on = settings.isEnabled(s.name)
                print("  " + (on ? Style.green(pad("有効", to: 6)) : Style.dim(pad("無効", to: 6))) + pad(s.name, to: width + 2) + (on ? s.description : Style.dim(s.description)))
            }
        }
        if !loaded.problems.isEmpty {
            print("\n" + Style.yellow("読み込めなかった \(loaded.problems.count) 件"))
            loaded.problems.forEach { print("  \(pad($0.location, to: 18))\($0.reason)") }
        }
    case "show":
        guard args.count >= 3 else { usageError("skills", "name を渡してください（例: vc skills show open-app）") }
        guard let s = loaded.skills.first(where: { $0.name == args[2] }) else { fail("スキルがありません: \(args[2])（一覧：vc skills）") }
        let on = settings.isEnabled(s.name)
        print(Style.bold(s.name) + "  " + (on ? Style.green("有効") : Style.dim("無効")))
        kv("説明", s.description, width: 6)
        kv("許可", s.allowedCommands.joined(separator: "、"), width: 6)
        kv("確認", s.confirm ? "必須" : "なし", width: 6)
        kv("場所", s.file.path, width: 6)
    case "enable", "disable":
        guard args.count >= 3 else { usageError("skills", "name を渡してください（例: vc skills \(sub) open-app）") }
        guard loaded.skills.contains(where: { $0.name == args[2] }) else { fail("スキルがありません: \(args[2])（一覧：vc skills）") }
        settings.setEnabled(args[2], sub == "enable")
        do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
        print(sub == "enable" ? Style.green("✓") + " \(args[2]) を有効にしました" : Style.dim("−") + " \(args[2]) を無効にしました")
    default:
        usageError("skills", "知らないサブコマンド: \(sub)（list・show・enable・disable）")
    }

case "run":
    // vc run "<依頼>" [--skill <name>] [--dry-run] [--yes]
    // Tiny-Jev が、有効なスキルから、呼ぶものを選び、スキルの本文と依頼文を Apple の言語モデルに渡して、コマンドを実行させる。
    // 実行するコマンドと結果は、すべて表示する。実行してよいコマンドは、スキルの allowed-commands だけ（シェルは使わない）。
    let dryRun = flag("--dry-run")
    let forced = option("--skill")
    guard args.count >= 2 else { usageError("run", "依頼を渡してください（例: vc run \"Safariを開いて\"）") }
    let request = args[1]
    let loaded = SkillStore.load()
    loaded.problems.forEach { eprint(Style.yellow("スキルを読めない: \($0.location)：\($0.reason)")) }
    let settings = Settings.load()
    let enabled = loaded.skills.filter { settings.isEnabled($0.name) }
    guard !enabled.isEmpty else { fail("有効なスキルがありません（vc skills で確認）") }

    var skill: Skill
    var probability = 1.0
    heading("スキルの選択")
    if let forced {
        guard let s = loaded.skills.first(where: { $0.name == forced }) else { fail("スキルがありません: \(forced)（一覧：vc skills）") }
        guard settings.isEnabled(s.name) else { fail("スキル \(forced) は無効です（vc skills enable \(forced)）") }
        skill = s
        kv("指定", Style.bold(s.name))
    } else {
        let jev = loadJev()
        let t0 = Date()
        do {
            let routed = try SkillRouter(scorer: jev, skills: enabled).route(request)
            let chosen = routed.skill.map { Style.bold($0.name) } ?? Style.dim("（どれでもない）")
            kv("Tiny-Jev", "\(chosen)  \(pct(routed.probability))" + Style.dim("（\(seconds(t0))）"))
            guard let s = routed.skill, routed.probability >= gate.floor else { print("\n  " + Style.dim("→ 実行しない")); exit(0) }
            skill = s
            probability = routed.probability
        } catch { fail("\(error)") }
    }
    kv("説明", skill.description)
    kv("許可", skill.allowedCommands.joined(separator: "、"))

    if skill.confirm || probability < gate.execute {
        notice(skill.confirm ? "このスキルは、実行の前に確認が要ります。" : "確信度が高くないので、確認します。")
        var approved = yes
        if !yes { print("  実行しますか？ [y/N] ", terminator: ""); approved = (readLine() ?? "").lowercased().hasPrefix("y") }
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

case "model":
    // vc model [status [--verify]]／download [--force]／path：Tiny-Jev のモデル（~/.voice-control/models/tiny-jev-0.6b）の確認・取得。
    let sub = args.count >= 2 ? args[1] : "status"
    let spec = ModelSpec.tinyJev06
    let dir = ModelStore.defaultDirectory(for: spec)
    func size(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    switch sub {
    case "path":
        print(dir.path)
    case "status":
        let verify = flag("--verify")
        heading("モデル（Tiny-Jev 0.6B）")
        kv("置き場所", dir.path)
        var allGood = true
        for file in spec.files {
            let label: String
            switch ModelStore.state(of: file, in: dir) {
            case .missing: label = Style.red("なし"); allGood = false
            case let .wrongSize(actual): label = Style.red("大きさが違う（\(size(actual))。期待 \(size(file.bytes))）"); allGood = false
            case .present:
                if verify {
                    let ok = ModelStore.verify(file, in: dir)
                    label = ok ? Style.green("あり・SHA-256 一致") : Style.red("SHA-256 が一致しない")
                    allGood = allGood && ok
                } else {
                    label = Style.green("あり") + Style.dim("（\(size(file.bytes))。SHA-256 は --verify で確かめる）")
                }
            }
            kv(file.name, label, width: 18)
        }
        let candidates = [modelOption, ProcessInfo.processInfo.environment["VC_MODEL_DIR"], dir.path, "models/tiny-jev-0.6b"].compactMap { $0 }.filter { !$0.isEmpty }
        if let used = candidates.first(where: { FileManager.default.fileExists(atPath: $0 + "/tokenizer.json") }) {
            kv("使う場所", used, width: 18)
        } else {
            kv("使う場所", Style.red("見つからない"), width: 18)
        }
        if !allGood { notice("取得する：vc model download（約 \(size(spec.files.reduce(0) { $0 + $1.bytes }))。SHA-256 を検証して置く）") }
    case "download":
        let force = flag("--force")
        let total = spec.files.reduce(Int64(0)) { $0 + $1.bytes }
        heading("モデルの取得（Tiny-Jev 0.6B）")
        kv("取得元", spec.baseURL.absoluteString)
        kv("置き場所", dir.path)
        kv("大きさ", "約 \(size(total))" + Style.dim("（途中で切れたら、もう一度実行すると続きから。取得したファイルは SHA-256 で検証する）"))
        notice("モデルの取得だけが、外部との通信です。音声・画面は、送りません")
        let tty = isatty(1) != 0
        let printer = ProgressPrinter(tty: tty)
        do {
            try await ModelStore.download(spec, to: dir, force: force) { printer.report($0) }
            printer.finish()
            print(Style.green("✓") + " 取得して、SHA-256 を検証しました: \(dir.path)")
            notice("使う：vc skills・vc run \"…\"")
        } catch {
            printer.finish()
            fail("\(error)")
        }
    default:
        usageError("model", "知らないサブコマンド: \(sub)（status・download・path）")
    }

case "hotkey":
    // vc hotkey [show]／set <キー>／reset：押している間だけ聞くトリガーの設定（~/.voice-control/settings.json）。
    let sub = args.count >= 2 ? args[1] : "show"
    var settings = Settings.load()
    switch sub {
    case "show":
        let (spec, source) = resolveHotKey()
        heading("ホットキー")
        kv("いまの設定", Style.bold(spec.description) + Style.dim("（\(spec.displayName)・\(source)）"))
        kv("種類", spec.isHold ? "長押し（他のキーなしで 0.35 秒以上。アクセシビリティの許可が要る）" : "キーの組み合わせ（許可は要らない）")
        if spec.isHold { kv("許可", ModifierHold.isTrusted ? Style.green("アクセシビリティ：許可済み") : Style.red("アクセシビリティ：未許可") + Style.dim("（システム設定 > プライバシーとセキュリティ > アクセシビリティで、このターミナルを許可し、開き直す）")) }
        print("")
        notice("変える：vc hotkey set <キー>（例：shift・ctrl+opt・ctrl+opt+space・cmd+shift+r・f5）。戻す：vc hotkey reset")
        notice("確かめる：vc hotkey-check（押して、離す。画面に「録音中」が出る）")
    case "set":
        guard args.count >= 3 else { usageError("hotkey", "キーを渡してください（例: vc hotkey set ctrl+opt+space）") }
        let text = args.dropFirst(2).joined(separator: "+")
        switch HotKeySpec.parse(text) {
        case let .failure(f): fail("\(text): \(f.reason)")
        case let .success(spec):
            settings.hotkey = spec.description
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            heading("ホットキー")
            kv("設定した", Style.bold(spec.description) + Style.dim("（\(spec.displayName)）"))
            if spec.isHold && !ModifierHold.isTrusted { notice("長押しの検出には、アクセシビリティの許可が要ります（この端末アプリに。agent-desktop permissions）") }
            notice("次の vc listen --hotkey から有効（確かめる：vc hotkey-check）")
        }
    case "reset":
        settings.hotkey = nil
        do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
        print(Style.green("✓") + " 既定（shift の長押し）に戻しました")
    default:
        usageError("hotkey", "知らないサブコマンド: \(sub)（show・set・reset）")
    }

case "hud-preview":
    // vc hud-preview [--stage recording|working|confirm|success|failure|denied] [--seconds <秒>]：画面の上の表示の見本を出す（マイク・言語モデル・コマンドは使わない。見た目の確認用）。
    // --stage がなければ、順に、すべて出す。
    let seconds = option("--seconds").flatMap(Double.init) ?? 3
    let only = option("--stage")
    let chip = resolveHotKey().spec.displayName
    func sample(_ stage: String) -> HUDContent? {
        switch stage {
        case "recording": return HUDContent(phase: .recording, title: "録音中", hint: "離すと、認識して実行します", chip: chip)
        case "working":
            var c = HUDContent(phase: .working, title: "実行中", chip: chip, heard: "音量を50にして", skill: "spotify")
            c.steps = [.init(command: "osascript …/spotify.applescript volume 50")]
            return c
        case "confirm": return HUDContent(phase: .confirm, title: "実行しますか？", hint: "もう一度トリガーを押して、「はい」と言う", chip: chip, heard: "ファイルを削除して", skill: "cleanup")
        case "success":
            var c = HUDContent(phase: .success, title: "完了", chip: chip, heard: "音量を50にして", skill: "spotify")
            c.steps = [.init(command: "osascript …/spotify.applescript volume 50", status: .ok, output: "ok: volume 50")]
            c.reply = "done: 音量を50に設定しました。"
            return c
        case "failure":
            var c = HUDContent(phase: .failure, title: "失敗", chip: chip, heard: "次の曲にして", skill: "spotify")
            c.steps = [.init(command: "osascript …/spotify.applescript next", status: .failed(1), output: "error: Spotify が応答しません")]
            c.reply = "failed: Spotify が応答しません"
            return c
        case "denied":
            var c = HUDContent(phase: .info, title: "実行しませんでした", chip: chip, heard: "ターミナルで ls を実行して", skill: "open-app")
            c.steps = [.init(command: "ls", status: .denied, output: "許可されていないコマンドです（open だけ許可）")]
            return c
        default: return nil
        }
    }
    let stages = ["recording", "working", "confirm", "success", "failure", "denied"]
    if let only { guard sample(only) != nil else { usageError("hud-preview", "知らない --stage: \(only)（\(stages.joined(separator: "・"))）") } }
    for (i, stage) in (only.map { [$0] } ?? stages).enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * seconds) { HUD.shared.show(sample(stage)!) }
    }
    let total = Double(only == nil ? stages.count : 1) * seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + total) { HUD.shared.hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) } }
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()

case "hotkey-check":
    let seconds = option("--seconds").flatMap(Double.init) ?? 10
    do {
        let (spec, source) = resolveHotKey()
        let hotkey = try makeTrigger(spec)
        hotkey.onPress = {
            print(Style.green("▼ pressed")); fflush(stdout)
            HUD.shared.show("録音中（テスト）　離すと終わり（\(spec.displayName)）", mode: .recording)
        }
        hotkey.onRelease = {
            print(Style.dim("▲ released")); fflush(stdout)
            HUD.shared.show("離しました", mode: .info, hideAfter: 1)
        }
        print("\(holdInstruction(spec))て、離す" + Style.dim("（\(spec.description)・\(source)・\(Int(seconds)) 秒間。マイクは使いません）"))
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { _ = hotkey; exit(0) }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    } catch { fail("ホットキーを登録できません: \(error)") }

case "eval":
    // コーパスの形：snapshot<TAB>期待<TAB>発話。期待は open:<アプリ> click:<要素名> type:<文字> press:<キー> scroll:<向き> none。
    // snapshot は corpus/snapshots/<名前>.json（自作の fixture を agent-desktop で撮ったもの）。アプリの一覧は corpus/apps.txt。
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { fail("usage: vc eval <plans.tsv>") }
    let dir = URL(fileURLWithPath: args[1]).deletingLastPathComponent()
    let apps = ((try? String(contentsOf: dir.appendingPathComponent("apps.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    let jev = loadJev()
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
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("snapshots/\(f[0]).json")), let s = try? SnapshotParser.parse(data) else { fail("snapshot を読めません: \(f[0])") }
            snapshots[f[0]] = s
        }
        let planner = Planner(scorer: jev, desktop: ReplayDesktop(snapshot: snapshots[f[0]]!, apps: apps), gate: gate, skills: skillCatalog.shortcuts, useLocation: !noLocation)
        let t0 = Date()
        let plan: Plan
        var utterance = f[2]
        if speak {
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
        if llmMode {
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
    if speak { kv("音声経由", "文字起こしが元の文と違った \(misheard)/\(heard)", width: w) }
    kv("正解", "\(hits)/\(total)  \(pct(Double(hits) / Double(total)))", width: w)
    for (k, v) in byKind.sorted(by: { $0.key < $1.key }) { kv("  " + k, "\(v.hit)/\(v.total)", width: w) }
    let wrong = "\(wrongExecuted) 件" + Style.dim("（確認なしで、違う操作を実行した数）")
    kv("危険な誤り", wrongExecuted > 0 ? Style.red(wrong) : Style.green(wrong), width: w)
    kv("確認なしで実行", "\(positiveExecuted)/\(positives)" + Style.dim("（操作の依頼のうち）"), width: w)
    kv("会話が通った", "\(negativeLeaked)/\(negatives)" + Style.dim("（操作でない発話が、確認か実行へ通った数）"), width: w)
    let sorted = millis.sorted()
    kv("時間", String(format: "中央値 %.0f ms・p95 %.0f ms（1 発話）", sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]), width: w)
    if llmMode {
        let ls = llmMillis.sorted()
        heading("Apple の言語モデル（FoundationModels）")
        kv("正解", "\(llmHits)/\(total)  \(pct(Double(llmHits) / Double(total)))", width: w)
        kv("会話に手を返した", "\(llmNegativeLeaked)/\(negatives)", width: w)
        kv("違う手を返した", "\(llmWrongAny)（全体）", width: w)
        kv("併用", "誤って確認なしで実行 \(llmHybridWrongExecuted) 件・確認なしで正しく実行 \(llmHybridPositiveExecuted)/\(positives)" + Style.dim("（Tiny-Jev と一致・ゲート「実行」のときだけ）"), width: w)
        kv("時間", String(format: "中央値 %.0f ms・p95 %.0f ms（1 発話）", ls[ls.count / 2], ls[min(ls.count - 1, Int(Double(ls.count) * 0.95))]), width: w)
    }

default:
    eprint(Style.errRed("不明なコマンド:") + " \(command)")
    eprint("コマンドの一覧: vc --help")
    exit(2)
}
