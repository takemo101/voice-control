import Foundation
import VCCore
import VCDecision
import VCPCControl
import VCSkill

/// スキルを読む：グローバル（`~/.voice-control/skills`）と、プロジェクト（起動した場所の `.voice-control/skills`。信頼したものだけ）。
func loadSkills(settings: Settings) -> SkillStore.Loaded {
    SkillStore.loadAll(projectRoot: VoiceControlHome.launchDirectory, settings: settings)
}

/// 未信頼のプロジェクトのスキルがあれば、読み込んでいないことを伝える。
func warnUntrustedProject(_ loaded: SkillStore.Loaded) {
    guard loaded.untrustedProjectCount > 0, let directory = loaded.projectDirectory else { return }
    eprint(Style.yellow("このプロジェクトのスキル \(loaded.untrustedProjectCount) 件（\(directory.path)）は、未信頼のため、読み込んでいません。内容を確かめて、vc skills trust"))
}

/// 有効なスキル（グローバル＋プロジェクト。そのつど読み直す。起動したまま、足したり、有効・無効を変えたりできる）。読めなかったものは、理由を出す。
func enabledSkills(_ context: CommandContext) -> [Skill] {
    let settings = context.currentSettings()
    let loaded = loadSkills(settings: settings)
    loaded.problems.forEach { eprint(Style.yellow("スキルを読めない: \($0.location)：\($0.reason)")) }
    warnUntrustedProject(loaded)
    return loaded.skills.filter { settings.isEnabled($0.name) }
}

/// スキルの実行の表示（ターミナル）。`hud` があれば、画面の上の表示にも、コマンドと結果を出す。
func skillDisplay(hud: HUDSession? = nil) -> ExecutionDisplay {
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

/// 声の依頼を、スキルで実行する（スキルを選ぶ → 選ばれなければ既定スキル → 必要なら声で確認 → 言語モデルがコマンドを実行 → 経過と結果を、画面の上に出す）。
/// 既定スキルが無効（または、ない）で、スキルも選ばれなければ false を返す（呼び出し側が、従来の PC 操作へ回す）。
func runSkillByVoice(_ utterance: String, skills: [Skill], jev: TinyJev, confirmation: Confirmation, gate: Gate, dryRun: Bool, chip: String,
                     cancel: CancelToken? = nil, ask: () async throws -> String?) async throws -> Bool {
    let t0 = Date()
    let resolution: SkillResolver.Resolution
    switch try SkillResolver(scorer: jev, skills: skills, gate: gate).resolve(utterance) {
    case let .declined(reason, fallbackAvailable):
        kv("Tiny-Jev", Style.dim("（どのスキルでもない）") + Style.dim("（\(seconds(t0))）"))
        guard fallbackAvailable else { return false }
        print("  " + Style.dim("→ 実行しない（\(reason)）"))
        HUD.shared.show(HUDContent(phase: .info, title: "操作の依頼ではありませんでした", hint: reason, chip: chip, heard: utterance), hideAfter: 3)
        return true
    case let .resolved(r):
        resolution = r
    }
    let skill = resolution.skill
    if resolution.kind == .matched {
        kv("Tiny-Jev", Style.bold(skill.name) + "  \(pct(resolution.probability))" + Style.dim("（\(seconds(t0))）"))
    } else {
        kv("Tiny-Jev", Style.dim("どのスキルでもない") + " → 既定スキル " + Style.bold(skill.name)
           + Style.dim("（操作の依頼 \(pct(resolution.probability))・取り消しにくさ \(pct(resolution.risk ?? 0))・\(seconds(t0))）"))
    }
    kv("許可", skill.allowedCommands.joined(separator: "、"))

    let hud = HUDSession(HUDContent(phase: .working, title: dryRun ? "確認のみ（--dry-run）" : "実行中", chip: chip, heard: utterance, skill: skill.name))
    hud.update()
    if let reason = resolution.confirmReason {
        say("\(skill.name)を実行しますか")
        notice("確認待ち：もう一度トリガーを押して「はい」と言う（\(reason)）")
        hud.update { $0.phase = .confirm; $0.title = "実行しますか？"; $0.hint = reason + "。もう一度トリガーを押して、「はい」と言う" }
        guard let answer = try await ask(), try confirmation.isYes(answer) else {
            print("  " + Style.dim("やめた"))
            hud.update(hideAfter: 2.5) { $0.phase = .info; $0.title = "やめました"; $0.hint = nil }
            return true
        }
        hud.update { $0.phase = .working; $0.title = dryRun ? "確認のみ（--dry-run）" : "実行中"; $0.hint = nil }
    }

    let agent = SkillAgent(skill: skill, dryRun: dryRun, display: skillDisplay(hud: hud), cancel: cancel)
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
        if cancel?.isCancelled == true || error is CancellationError {
            print("  " + Style.yellow("取りやめました（Esc）"))
            hud.update(hideAfter: 2) { $0.phase = .info; $0.title = "取りやめました"; $0.hint = nil; $0.reply = nil }
        } else {
            print(Style.red("失敗:") + " \(error)")
            hud.update(hideAfter: 7) { $0.phase = .failure; $0.title = "失敗"; $0.reply = "\(error)" }
        }
    }
    return true
}
