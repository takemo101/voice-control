import AppKit
import Foundation
import VoiceControlKit

// 試す用の CLI。
//   vc plan "<発話>" [--app <名前>]     選んだ操作・確率・ゲートの判定だけを出す（実行しない）
//   vc act  "<発話>" [--app <名前>] [--execute] [--yes]   --execute で実行。確認が要る判定は --yes も要る
//   vc eval corpus/plans.tsv            固定した画面での、操作の当たり率（実機を操作しない）
// 共通：--model <dir>（なければ VC_MODEL_DIR、./models/tiny-jev-0.6b、~/Library/Application Support/voice-control/models/tiny-jev-0.6b の順）  --length <tokens>（既定 1024）

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

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
/// モデルの場所：--model、環境変数 VC_MODEL_DIR、./models/tiny-jev-0.6b、~/Library/Application Support/voice-control/models/tiny-jev-0.6b の順に、最初に tokenizer.json があるもの。
func resolveModelDir() -> URL {
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/voice-control/models/tiny-jev-0.6b").path
    let candidates = [option("--model"), ProcessInfo.processInfo.environment["VC_MODEL_DIR"], "models/tiny-jev-0.6b", support].compactMap { $0 }.filter { !$0.isEmpty }
    let found = candidates.first { FileManager.default.fileExists(atPath: $0 + "/tokenizer.json") }
    guard let found else { fail("モデルが見つかりません（探した場所: \(candidates.joined(separator: ", "))）。just fetch-model") }
    return URL(fileURLWithPath: found)
}
let modelDir = resolveModelDir()
let length = option("--length").flatMap(Int.init) ?? 1024
let appName = option("--app")
let execute = flag("--execute"), yes = flag("--yes"), speak = flag("--speak"), hotkeyMode = flag("--hotkey"), llmMode = flag("--llm"), llmSplit = flag("--llm-split"), noContext = flag("--no-context"), noLocation = flag("--no-location")
let audioFile = option("--audio")
let triggerName = option("--trigger") ?? "shift"
/// これまでに実行した手（前の指示を、次の判断の文脈に使う）。`--no-context` なら、使わない。
let sessionHistory = HistoryStore()
var gate = Gate()
if let f = option("--floor").flatMap(Double.init) { gate.floor = f }
guard let command = args.first else { fail("usage: vc plan|act <発話> | vc eval <plans.tsv>") }

func loadJev() -> TinyJev {
    do {
        let t0 = Date()
        let jev = try TinyJev(directory: modelDir, length: length)
        _ = try jev.choose(state: "テスト", question: "テスト", options: ["a", "b"])  // グラフのコンパイルを、計測の外へ出す
        FileHandle.standardError.write(Data(String(format: "model loaded %.1fs (length %d)\n", Date().timeIntervalSince(t0), length).utf8))
        return jev
    } catch {
        fail("モデルを読めません: \(error)（scripts/fetch-model.sh で取得）")
    }
}

func pct(_ p: Double) -> String { String(format: "%5.1f%%", p * 100) }

func describe(_ plan: Plan) {
    print("  選択: \(plan.choice)  \(pct(plan.probability))（採点 \(plan.rounds) 回）")
    if let risk = plan.risk { print("  取り消しにくい確率: \(pct(risk))") }
    if let note = plan.note { print("  注意：\(note)") }
    if let step = plan.step { print("  → \(step.summary)") }
    print("  gate: \(plan.verdict)" + (plan.rejection.map { "（\($0)）" } ?? ""))
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

/// 押している間だけ聞く入り口。`--trigger shift`（既定：Shift を 0.35 秒以上、単独で押し続ける）か、`--trigger ctrl-opt-space`。
func makeTrigger() throws -> PushToTalkTrigger {
    switch triggerName {
    case "shift":
        if !ModifierHold.isTrusted { print("注意：Shift の長押しの検出には、アクセシビリティの許可が要ります（この端末アプリに）。許可がないと、何も届きません") }
        return ModifierHold(modifier: .shift)
    case "ctrl-opt-space": return try HotKey()
    default: fail("知らない --trigger: \(triggerName)（shift か ctrl-opt-space）")
    }
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
func runClauses(_ clauses: [String], planner: Planner, desktop: AgentDesktop, act: Bool, confirm: (Plan) async throws -> Bool) async throws {
    for (i, clause) in clauses.enumerated() {
        if clauses.count > 1 { print("[\(i + 1)/\(clauses.count)] \(clause)") }
        let plan = try planner.plan(clause, history: noContext ? [] : sessionHistory.entries)
        describe(plan)
        guard let step = plan.step, plan.verdict != .reject else { print("→ 実行しない\(i + 1 < clauses.count ? "（残りも中止）" : "")"); return }
        guard act, execute else {
            if act { print("dry-run：実行していない（--execute で実行）") }
            continue
        }
        if plan.verdict == .confirm, !(try await confirm(plan)) { print("やめた（確認が取れない）\(i + 1 < clauses.count ? "。残りも中止" : "")"); return }
        try desktop.perform(step)
        sessionHistory.append(Executed(step: step))
        print("done")
        if i + 1 < clauses.count { try await Task.sleep(nanoseconds: 800_000_000) }   // 画面が落ち着くのを待つ
    }
}

switch command {
case "plan", "act":
    guard args.count >= 2 || audioFile != nil else { fail("usage: vc \(command) <発話> | --audio <ファイル> [--app <名前>]") }
    let desktop = AgentDesktop(app: appName)
    let planner = Planner(scorer: loadJev(), desktop: desktop, gate: gate, skills: skillCatalog.shortcuts, useLocation: !noLocation)
    do {
        var utterance = args.count >= 2 ? args[1] : ""
        if let audio = audioFile {
            utterance = try await FileTranscriber().transcribe(file: URL(fileURLWithPath: audio))
            print("heard: \(utterance)")   // 文字起こしの表示は、この検証の端末だけ（ファイルには残さない）
        }
        try await runClauses(await clauses(for: utterance), planner: planner, desktop: desktop, act: command == "act", confirm: { _ in yes })
    } catch { fail("\(error)") }

case "listen":
    // vc listen [--app <名前>] [--execute] [--hotkey]：既定は、Enter で録音を始め、もう一度 Enter で止める。--hotkey は、control + option + space を押している間だけ録音する。
    // マイクの許可が要る（初回、macOS が確認を出す）。
    guard await MicRecorder.authorize() else { fail("マイクが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）") }
    let desktop = AgentDesktop(app: appName)
    let jev = loadJev()
    let planner = Planner(scorer: jev, desktop: desktop, gate: gate, skills: skillCatalog.shortcuts, useLocation: !noLocation)
    if hotkeyMode {
        // control + option + space を押している間だけ録音し、離したら、文字にして、計画する。
        // --app がなければ、そのとき前面にあるアプリを操作する。確認が要る判定は、問いかけを読み上げ、次の発話の「はい」で実行する。
        let confirmation = Confirmation(scorer: jev)
        let (files, filesIn) = AsyncStream<URL>.makeStream()
        let session = RecordingSession()
        do {
            let hotkey = try makeTrigger()
            hotkey.onPress = { session.start(); NSSound(named: "Pop")?.play() }
            hotkey.onRelease = {
                NSSound(named: "Tink")?.play()
                do { if let file = try session.stop() { filesIn.yield(file) } } catch { print("録音に失敗: \(error)") }
            }
            Task {
                var iterator = files.makeAsyncIterator()
                /// 次の発話（確認の返事にも使う）。
                func nextUtterance() async throws -> String? {
                    guard let file = await iterator.next() else { return nil }
                    defer { try? FileManager.default.removeItem(at: file) }
                    let text = try await FileTranscriber().transcribe(file: file)
                    print("heard: \(text)")
                    return text
                }
                while true {
                    do {
                        guard let utterance = try await nextUtterance() else { break }
                        guard !utterance.isEmpty else { print("聞き取れなかった"); continue }
                        try await runClauses(await clauses(for: utterance), planner: planner, desktop: desktop, act: true, confirm: { plan in
                            say("\(plan.step?.spoken ?? "この操作")。実行しますか")
                            print("確認待ち：ホットキーを押して「はい」と言う")
                            guard let answer = try await nextUtterance() else { return false }
                            return try confirmation.isYes(answer)
                        })
                    } catch { print("失敗: \(error)") }
                }
            }
            print(triggerName == "shift" ? "Shift を単独で押し続けている間だけ聞きます（0.35 秒以上。Ctrl+C で終了）" : "control + option + space を押している間だけ聞きます（Ctrl+C で終了）")
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } catch { fail("ホットキーを登録できません: \(error)") }
    }
    while true {
        print("\nEnter で録音開始（q で終了）> ", terminator: "")
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
            print("heard: \(utterance)")
            guard !utterance.isEmpty else { print("聞き取れなかった"); continue }
            try await runClauses(await clauses(for: utterance), planner: planner, desktop: desktop, act: true, confirm: { _ in yes })
        } catch { print("失敗: \(error)") }
    }

case "llm":
    // vc llm <snapshot.json> <発話>：言語モデルが選ぶ次の 1 手を見る（VC_LLM_DEBUG=1 で、生の出力も）。
    guard args.count >= 3, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])), let snap = try? SnapshotParser.parse(data) else { fail("usage: vc llm <snapshot.json> <発話>") }
    let apps = ((try? String(contentsOfFile: "corpus/apps.txt", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    do { print(try await LLMPlanner(desktop: ReplayDesktop(snapshot: snap, apps: apps)).next(utterance: args[2], done: [])) } catch { fail("\(error)") }

case "decompose":
    // vc decompose <発話>：長い依頼の分け方を、ルール（ClauseSplitter）と言語モデル（FoundationModels）で比べる。
    guard args.count >= 2 else { fail("usage: vc decompose <発話>") }
    print("ルール:")
    for (i, c) in ClauseSplitter.split(args[1]).enumerated() { print("  \(i + 1). \(c)") }
    do {
        let t0 = Date()
        let steps = try await LLMDecomposer().steps(for: args[1])
        print(String(format: "言語モデル（%.1f 秒）:", Date().timeIntervalSince(t0)))
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
    print("文脈あり \(hitsWith)/\(total)（確認なしの誤り \(wrongSilentWith)）／ 文脈なし \(hitsWithout)/\(total)（確認なしの誤り \(wrongSilentWithout)）")

case "keys":
    // vc keys：組み込みのキー操作と、足した定義（JSON。`vc plan`・`vc act` のショートカットの候補）の一覧。
    print("組み込み \(Shortcut.all.count) 件（Action.swift）")
    print("足した定義 \(skillCatalog.shortcuts.count) 件：")
    for s in skillCatalog.shortcuts { print("  \(s.option)  keys=\(s.combo)\(s.app.map { "  app=\($0)" } ?? "")\(s.when.map { "  when=\($0)" } ?? "")\(s.needsConfirmation ? "  確認つき" : "")") }
    if !skillCatalog.problems.isEmpty { print("読み込めなかった \(skillCatalog.problems.count) 件："); skillCatalog.problems.forEach { print("  \($0)") } }

case "skills":
    // vc skills [list]               スキルの一覧（name・description・有効／無効）
    // vc skills show <name>          1 つの詳細（許可するコマンド・本文の場所）
    // vc skills enable|disable <name>  Tiny-Jev の選択肢にするか（既定は有効。設定は ~/.voice-control/settings.json）
    let sub = args.count >= 2 ? args[1] : "list"
    let loaded = SkillStore.load()
    var settings = Settings.load()
    switch sub {
    case "list":
        if loaded.skills.isEmpty { print("スキルがありません（\(VoiceControlHome.skillsDirectory.path)/<name>/SKILL.md に置く。作り方：skills/voice-control-skill-author）") }
        let width = loaded.skills.map { $0.name.count }.max() ?? 0
        for s in loaded.skills {
            print("\(settings.isEnabled(s.name) ? "[有効]" : "[無効]")  \(s.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(s.description)")
        }
        if !loaded.problems.isEmpty {
            print("\n読み込めなかった \(loaded.problems.count) 件：")
            loaded.problems.forEach { print("  \($0.location)：\($0.reason)") }
        }
    case "show":
        guard args.count >= 3, let s = loaded.skills.first(where: { $0.name == args[2] }) else { fail("usage: vc skills show <name>（一覧：vc skills list）") }
        print("name: \(s.name)（\(settings.isEnabled(s.name) ? "有効" : "無効")）")
        print("description: \(s.description)")
        print("allowed-commands: \(s.allowedCommands.joined(separator: "、"))")
        print("confirm: \(s.confirm)")
        print("file: \(s.file.path)")
    case "enable", "disable":
        guard args.count >= 3 else { fail("usage: vc skills \(sub) <name>") }
        guard loaded.skills.contains(where: { $0.name == args[2] }) else { fail("スキルがありません: \(args[2])（一覧：vc skills list）") }
        settings.setEnabled(args[2], sub == "enable")
        do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
        print("\(args[2]) を\(sub == "enable" ? "有効" : "無効")にしました")
    default:
        fail("usage: vc skills [list|show <name>|enable <name>|disable <name>]")
    }

case "run":
    // vc run "<依頼>" [--skill <name>] [--dry-run] [--yes]
    // Tiny-Jev が、有効なスキルから、呼ぶものを選び、スキルの本文と依頼文を Apple の言語モデルに渡して、コマンドを実行させる。
    // 実行するコマンドと結果は、すべて表示する。実行してよいコマンドは、スキルの allowed-commands だけ（シェルは使わない）。
    let dryRun = flag("--dry-run")
    let forced = option("--skill")
    guard args.count >= 2 else { fail("usage: vc run <依頼> [--skill <name>] [--dry-run] [--yes]") }
    let request = args[1]
    let loaded = SkillStore.load()
    loaded.problems.forEach { FileHandle.standardError.write(Data("スキルを読めない: \($0.location)：\($0.reason)\n".utf8)) }
    let settings = Settings.load()
    let enabled = loaded.skills.filter { settings.isEnabled($0.name) }
    guard !enabled.isEmpty else { fail("有効なスキルがありません（vc skills list）") }

    var skill: Skill
    var probability = 1.0
    if let forced {
        guard let s = loaded.skills.first(where: { $0.name == forced }) else { fail("スキルがありません: \(forced)") }
        guard settings.isEnabled(s.name) else { fail("スキル \(forced) は無効です（vc skills enable \(forced)）") }
        skill = s
        print("スキル: \(s.name)（指定）")
    } else {
        let jev = loadJev()
        let t0 = Date()
        do {
            let routed = try SkillRouter(scorer: jev, skills: enabled).route(request)
            print(String(format: "Tiny-Jev の選択（%.2f 秒）: %@  %.1f%%", Date().timeIntervalSince(t0), routed.skill?.name ?? "（どれでもない）", routed.probability * 100))
            guard let s = routed.skill, routed.probability >= gate.floor else { print("→ 実行しない"); exit(0) }
            skill = s
            probability = routed.probability
        } catch { fail("\(error)") }
    }
    print("  \(skill.description)")
    print("  許可するコマンド: \(skill.allowedCommands.joined(separator: "、"))")

    if skill.confirm || probability < gate.execute {
        print(skill.confirm ? "このスキルは、実行の前に確認が要ります。" : "確信度が高くないので、確認します。")
        var approved = yes
        if !yes { print("実行しますか？ [y/N] ", terminator: ""); approved = (readLine() ?? "").lowercased().hasPrefix("y") }
        guard approved else { print("やめた"); exit(0) }
    }

    let agent = SkillAgent(skill: skill, dryRun: dryRun, display: .init(
        onCommand: { print("$ \($0)\(dryRun ? "   （dry-run：実行しない）" : "")") },
        onResult: { code, output in
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).prefix(8)
            print("  exit \(code)" + (lines.isEmpty ? "" : "\n" + lines.map { "  │ \($0)" }.joined(separator: "\n")))
        },
        onDenied: { print("✗ 拒否: \($0)  — \($1)") }))
    let t1 = Date()
    do {
        let reply = try await agent.run(request: request)
        print(String(format: "返事（%.1f 秒）: %@", Date().timeIntervalSince(t1), reply))
        print("実行したコマンド: \(agent.executedCommands.count) 件")
    } catch { fail("\(error)") }

case "hotkey-check":
    // vc hotkey-check [--seconds N]：ホットキー（control + option + space）の「押した・離した」が届くかを確かめる（マイクは使わない）。
    let seconds = option("--seconds").flatMap(Double.init) ?? 10
    do {
        let hotkey = try makeTrigger()
        hotkey.onPress = { print("pressed"); fflush(stdout) }
        hotkey.onRelease = { print("released"); fflush(stdout) }
        print((triggerName == "shift" ? "Shift を単独で 0.35 秒以上押して、離す" : "control + option + space を押して、離す") + "（\(Int(seconds)) 秒間）")
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
            print("MISS \(plan.verdict) \(got) ≠ \(f[1]) [\(f[0])]: \(f[2])" + (utterance != f[2] ? " (聞こえ: \(utterance))" : "") + "  ← \(plan.choice) \(Int(plan.probability * 100))%")
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
            if llmOK { llmHits += 1 } else { print("LLM-MISS \(llmGot) ≠ \(f[1]) [\(f[0])]: \(f[2])  (\(next))") }
            // 併用：言語モデルの手を使い、Tiny-Jev と一致して、Tiny-Jev のゲートが「実行」のときだけ、確認なしで実行する。
            let agree = llmGot != "none" && llmGot == got
            let silent = agree && plan.verdict == .execute
            if llmGot != "none" && !llmOK && silent { llmHybridWrongExecuted += 1 }
            if llmGot != "none" && !llmOK { llmWrongAny += 1 }
            if f[1] != "none" && llmOK && silent { llmHybridPositiveExecuted += 1 }
            if f[1] == "none" && llmGot != "none" { llmNegativeLeaked += 1 }
        }
    }
    if speak { print("音声経由：文字起こしが、元の文と一致しなかった \(misheard)/\(heard)") }
    print("accuracy \(hits)/\(total) = \(pct(Double(hits) / Double(total)))")
    for (k, v) in byKind.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v.hit)/\(v.total)") }
    print("誤って「そのまま実行」: \(wrongExecuted) 件（確認なしで、違う操作をした数）")
    print("操作の依頼を、確認なしで実行できた: \(positiveExecuted)/\(positives)")
    print("操作でない発話が、確認か実行へ通った: \(negativeLeaked)/\(negatives)")
    let sorted = millis.sorted()
    print(String(format: "latency per utterance: median %.0f ms, p95 %.0f ms", sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]))
    if llmMode {
        let ls = llmMillis.sorted()
        print("--- Apple 言語モデル（FoundationModels）")
        print("accuracy \(llmHits)/\(total) = \(pct(Double(llmHits) / Double(total)))")
        print("操作でない発話に、手を返した: \(llmNegativeLeaked)/\(negatives)　／　違う手を返した（全体）: \(llmWrongAny)")
        print("併用（言語モデルの手＋Tiny-Jev と一致・ゲート「実行」のときだけ確認なし）：誤って確認なしで実行 \(llmHybridWrongExecuted) 件、確認なしで正しく実行 \(llmHybridPositiveExecuted)/\(positives)")
        print(String(format: "latency per utterance: median %.0f ms, p95 %.0f ms", ls[ls.count / 2], ls[min(ls.count - 1, Int(Double(ls.count) * 0.95))]))
    }

default:
    fail("unknown command: \(command)")
}
