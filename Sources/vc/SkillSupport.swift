import Foundation
import VCCore
import VCSkill

/// 読んだスキルと、そのときの設定。
struct LoadedSkills {
    let loaded: SkillStore.Loaded
    let settings: Settings

    /// 有効なスキル（無効にしたものを除く）。
    var enabled: [Skill] { loaded.skills.filter { settings.isEnabled($0.name) } }

    /// 読めなかったスキルの理由と、未信頼のプロジェクトのスキルを読み込んでいないことを、標準エラーへ出す。
    func reportProblems() {
        loaded.problems.forEach { eprint(Style.yellow("スキルを読めない: \($0.location)：\($0.reason)")) }
        if loaded.untrustedProjectCount > 0, let directory = loaded.projectDirectory {
            eprint(Style.yellow("このプロジェクトのスキル \(loaded.untrustedProjectCount) 件（\(directory.path)）は、未信頼のため、読み込んでいません。内容を確かめて、vc skills trust"))
        }
    }
}

extension CommandContext {
    /// スキルを読む：グローバル（`~/.voice-control/skills`）と、プロジェクト（起動した場所の `.voice-control/skills`。信頼したものだけ）。そのつど読み直す（起動したまま、足したり、有効・無効を変えたりできる）。
    func loadSkills() -> LoadedSkills {
        let settings = currentSettings()
        return LoadedSkills(loaded: SkillStore.loadAll(projectRoot: VoiceControlHome.launchDirectory, settings: settings), settings: settings)
    }
}
