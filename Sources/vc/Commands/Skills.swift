import Foundation
import VCCore
import VCSkill

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
        let catalog = context.loadSkills()
        let loaded = catalog.loaded
        var settings = catalog.settings
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
