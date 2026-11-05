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

/// 端末での確認：`--yes` なら聞かずに承認。そうでなければ `[y/N]` を聞く（`vc run`・Enter で録音する `vc listen`）。
func askOnTerminal(yes: Bool) -> Bool {
    if yes { return true }
    print("  実行しますか？ [y/N] ", terminator: "")
    return (readLine() ?? "").lowercased().hasPrefix("y")
}

/// Apple の言語モデル（スキルの実行に使う）が使えないとき、理由と直す手順を示して終わる（実行の途中で、失敗させない。Tiny-Jev のモデルがないとき、
/// `vc model download` を案内するのと同じ）。`vc doctor` で、ほかの項目も確かめられる。
/// スキルを実行するモデルが Apple のときだけ、Apple Intelligence が要る（Ollama などのローカルのサーバーのモデルを使うなら、要らない）。
func requireAppleIntelligence(for engine: Engine) {
    guard engine == .apple else { return }
    if case .unavailable(let reason) = AppleIntelligence.current() {
        fail("\(reason.summary)。\(reason.remedy)。確認：vc doctor")
    }
}
