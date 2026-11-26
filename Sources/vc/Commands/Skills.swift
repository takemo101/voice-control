import Foundation
import VCCore
import VCSkill

struct SkillsCommand: Command {
    static let info = CommandInfo(
        name: "skills", group: .skills, summary: tr("スキルの一覧・詳細・有効／無効・プロジェクトの信頼・GitHub からのインストール"),
        usage: ["vc skills [list]", "vc skills show <name>", "vc skills enable <name>", "vc skills disable <name>", "vc skills trust", "vc skills untrust", "vc skills install [<name>…|--all] [--force] [--ref <tag|branch>]"],
        details: [
            tr("置き場所は 2 つ。グローバル：~/.voice-control/skills/<name>/SKILL.md（環境変数 VC_HOME で ~/.voice-control を変えられる）。プロジェクト：<vc を起動した場所>/.voice-control/skills/<name>/SKILL.md（起動した場所が、プロジェクトのルート）。"),
            tr("同じ名前なら、プロジェクトのスキルが、グローバルを上書きする。"),
            tr("既定スキル（default）：どのスキルにも当てはまらない依頼を、Apple の言語モデルが、agent-desktop と基本のコマンド（open・say・ls・pwd・date）で実行する組み込みのスキル。Tiny-Jev の選択肢には入らない。許可を広げるなら、同じ名前（default）のスキルを置く。使わないなら vc skills disable default。"),
            tr("プロジェクトのスキルは、外から来るもの（リポジトリなど）なので、**信頼したプロジェクトだけ**読み込む。初めは、未信頼で、件数だけを出す。中身（許可するコマンド）を確かめてから、そのプロジェクトで vc skills trust。やめるのは vc skills untrust。信頼は ~/.voice-control/settings.json に、プロジェクトの場所ごとに記録する。"),
            tr("list：name・置き場所・description・有効／無効の一覧。読み込めなかったスキルは、理由つきで、下に出る。"),
            tr("show：許可するコマンド・確認の要否・置き場所・ファイルの場所。"),
            tr("enable / disable：Tiny-Jev の選択肢にするか。既定は有効。設定は ~/.voice-control/settings.json（名前ごと。プロジェクトのスキルも、同じ名前なら、まとめて）。"),
            tr("trust / untrust：起動した場所のプロジェクトのスキルを、読み込んでよいか。trust は、許可するコマンドを表示してから、信頼する。"),
            tr("install：GitHub の公開リポジトリ（takemo101/voice-control）の `.voice-control/skills/<name>` を、グローバルへ、スクリプトごと置く。名前を渡さなければ、インストールできるスキルの一覧。版は、入っている vc と同じタグ（見つからなければ main。--ref で、タグ・ブランチを指定）。置いたスキルは、信頼の手続きなしで、どこでも、いつも読み込まれる：取得元と許可するコマンドを表示するので、確かめる。同名があれば、--force で置き換える。シンボリックリンクを含むスキル・読めないスキルは、置かない。"),
        ],
        options: [("--all", tr("install：リポジトリの、すべてのスキルを置く（名前は、渡さない）")), ("--force", tr("install：同名のスキルがあっても、置き換える")), ("--ref <tag|branch>", tr("install：取得する版（既定は、入っている vc と同じタグ）"))],
        examples: ["vc skills", "vc skills show open-app", "vc skills disable open-app", "vc skills trust", "vc skills install", "vc skills install spotify clipboard-note", "vc skills install --all"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc skills [list]               スキルの一覧（name・description・有効／無効）
        // vc skills show <name>          1 つの詳細（許可するコマンド・本文の場所）
        // vc skills enable|disable <name>  Tiny-Jev の選択肢にするか（既定は有効。設定は ~/.voice-control/settings.json）
        // vc skills trust|untrust        このプロジェクトのスキルを、読み込んでよいか
        // vc skills install [<name>…] [--force] [--ref <tag|branch>]  GitHub のスキルを、グローバルへ置く
        var arguments = arguments
        let force = arguments.flag("--force")
        let all = arguments.flag("--all")
        let explicitRef = arguments.option("--ref")
        let positionals = arguments.positionals
        let sub = positionals.first ?? "list"
        let names = Array(positionals.dropFirst())
        let catalog = context.loadSkills()
        switch sub {
        case "list": list(catalog)
        case "show": show(names.first, catalog)
        case "enable", "disable": setEnabled(names.first, sub == "enable", catalog)
        case "trust": trust(catalog)
        case "untrust": untrust(catalog)
        case "install":
            if all && !names.isEmpty { usageError("skills", tr("--all には、名前を渡せません（すべてを置きます）")) }
            await install(names: names, all: all, explicitRef: explicitRef, overwrite: force)
        default: usageError("skills", tr("知らないサブコマンド: \(sub)（list・show・enable・disable・trust・untrust・install）"))
        }
    }

    // MARK: 一覧・詳細・有効／無効

    private func list(_ catalog: LoadedSkills) {
        let loaded = catalog.loaded, settings = catalog.settings
        let enabledCount = loaded.skills.filter { settings.isEnabled($0.name) }.count
        print(Style.bold(tr("スキル")) + tr(" \(loaded.skills.count) 件（有効 \(enabledCount)）"))
        kv(tr("グローバル"), VoiceControlHome.skillsDirectory.path, width: 12)
        let projectSkills = VoiceControlHome.projectSkillsDirectory(root: VoiceControlHome.launchDirectory)
        if let projectDirectory = loaded.projectDirectory {
            let state = loaded.untrustedProjectCount > 0
                ? Style.yellow(tr("未信頼：\(loaded.untrustedProjectCount) 件を読み込んでいない。確認して vc skills trust"))
                : Style.green(tr("信頼済み"))
            kv(tr("プロジェクト"), projectDirectory.path + tr("（\(state)）"), width: 12)
        } else {
            kv(tr("プロジェクト"), Style.dim(tr("なし（\(projectSkills.path)）")), width: 12)
        }
        if loaded.skills.isEmpty {
            print("\n  " + tr("まだありません。\(VoiceControlHome.skillsDirectory.path)/<name>/SKILL.md（全体）か、\(projectSkills.path)/<name>/SKILL.md（このプロジェクト）に置きます。"))
            print("  " + tr("作り方: skills/voice-control-skill-author/SKILL.md、書式: docs/skills.md"))
        } else {
            let width = max(4, loaded.skills.map { displayWidth($0.name) }.max() ?? 0)
            print("\n  " + Style.dim(pad(tr("状態"), to: colWidth(ja: 6, en: 9)) + pad("name", to: width + 2) + pad(tr("置き場所"), to: 14) + tr("説明")))
            for s in loaded.skills {
                let on = settings.isEnabled(s.name)
                print("  " + (on ? Style.green(pad(tr("有効"), to: colWidth(ja: 6, en: 9))) : Style.dim(pad(tr("無効"), to: colWidth(ja: 6, en: 9)))) + pad(s.name, to: width + 2) + pad(Self.scopeName(s.scope), to: 14) + (on ? s.description : Style.dim(s.description)))
            }
        }
        if !loaded.overridden.isEmpty { notice(tr("プロジェクトのスキルが、同じ名前のグローバルを上書きしている：") + listJoin(loaded.overridden)) }
        if !loaded.problems.isEmpty {
            print("\n" + Style.yellow(tr("読み込めなかった \(loaded.problems.count) 件")))
            loaded.problems.forEach { print("  \(pad($0.location, to: 18))\($0.reason)") }
        }
    }

    private func show(_ name: String?, _ catalog: LoadedSkills) {
        guard let name else { usageError("skills", tr("name を渡してください（例: vc skills show open-app）")) }
        guard let s = catalog.loaded.skills.first(where: { $0.name == name }) else { fail(tr("スキルがありません: \(name)（一覧：vc skills）")) }
        let on = catalog.settings.isEnabled(s.name)
        print(Style.bold(s.name) + "  " + (on ? Style.green(tr("有効")) : Style.dim(tr("無効"))))
        kv(tr("説明"), s.description, width: colWidth(ja: 6, en: 12))
        kv(tr("許可"), listJoin(s.allowedCommands), width: colWidth(ja: 6, en: 12))
        kv(tr("確認"), s.confirm ? tr("必須") : tr("なし"), width: colWidth(ja: 6, en: 12))
        if let notice = s.externalNotice { kv(tr("外へ送る"), Style.yellow(notice), width: colWidth(ja: 6, en: 12)) }
        switch s.imageSource {
        case .screenshot: kv(tr("画像"), tr("撮ったスクリーンショットがあるときだけ、選ばれる（撮ってから \(ScreenshotStore.timeToLiveMinutes) 分）"), width: colWidth(ja: 6, en: 12))
        case .clipboard: kv(tr("画像"), tr("コピーした画像（クリップボード）があるときだけ、選ばれる"), width: colWidth(ja: 6, en: 12))
        case .any: kv(tr("画像"), tr("撮ったスクリーンショットか、コピーした画像があるときだけ、選ばれる"), width: colWidth(ja: 6, en: 12))
        case nil: break
        }
        if !s.triggers.isEmpty { kv(tr("言い方の規則"), tr("この言い方に当たる依頼は、Tiny-Jev を通さず、このスキルへ回る（\(s.triggers.count) 件。内容は、SKILL.md の triggers）"), width: colWidth(ja: 6, en: 12)) }
        if s.commandTimeout != CommandRunner.defaultTimeout { kv(tr("時間"), tr("コマンド 1 つあたり \(Int(s.commandTimeout)) 秒まで"), width: colWidth(ja: 6, en: 12)) }
        kv(tr("置き場所"), Self.scopeName(s.scope) + (s.scope == .project && catalog.loaded.overridden.contains(s.name) ? Style.dim(tr("（同名のグローバルを上書き）")) : ""), width: colWidth(ja: 6, en: 12))
        if s.scope != .builtin { kv(tr("場所"), s.file.path, width: colWidth(ja: 6, en: 12)) }
    }

    private func setEnabled(_ name: String?, _ enabled: Bool, _ catalog: LoadedSkills) {
        guard let name else { usageError("skills", tr("name を渡してください（例: vc skills \(enabled ? "enable" : "disable") open-app）")) }
        guard catalog.loaded.skills.contains(where: { $0.name == name }) else { fail(tr("スキルがありません: \(name)（一覧：vc skills）")) }
        var settings = catalog.settings
        settings.setEnabled(name, enabled)
        save(settings)
        print(enabled ? Style.green("✓") + " " + tr("\(name) を有効にしました") : Style.dim("−") + " " + tr("\(name) を無効にしました"))
    }

    private static func scopeName(_ scope: Skill.Scope) -> String {
        switch scope { case .project: return tr("プロジェクト"); case .builtin: return tr("組み込み"); case .global: return tr("グローバル") }
    }

    private func save(_ settings: Settings) {
        do { try settings.save() } catch { fail(tr("設定を保存できません: \(error)")) }
    }

    // MARK: プロジェクトの信頼

    /// このプロジェクト（起動した場所）の `.voice-control/skills` を、読み込んでよいか。外から来たリポジトリのスキルは、許可したコマンドを実行できるので、確認してから信頼する。
    private func trust(_ catalog: LoadedSkills) {
        let root = VoiceControlHome.launchDirectory
        let directory = VoiceControlHome.projectSkillsDirectory(root: root)
        let project = SkillStore.load(directory: directory, scope: .project)
        guard !project.skills.isEmpty || !project.problems.isEmpty else { fail(tr("このプロジェクトに、スキルがありません（\(directory.path)）")) }
        heading(tr("信頼するプロジェクト"))
        kv(tr("場所"), root.path, width: colWidth(ja: 6, en: 12))
        for s in project.skills {
            print("  " + Style.bold(s.name) + Style.dim("  " + tr("確認：\(s.confirm ? tr("必須") : tr("なし"))")))
            print("    " + tr("許可するコマンド: ") + listJoin(s.allowedCommands))
        }
        project.problems.forEach { print("  " + Style.yellow(tr("読めない: \($0.location)：\($0.reason)"))) }
        var settings = catalog.settings
        settings.setTrusted(project: root, true)
        save(settings)
        print("\n" + Style.green("✓") + " " + tr("信頼しました。このプロジェクトで vc を起動すると、上のスキルを読み込みます（やめる：vc skills untrust）"))
    }

    private func untrust(_ catalog: LoadedSkills) {
        let root = VoiceControlHome.launchDirectory
        var settings = catalog.settings
        settings.setTrusted(project: root, false)
        save(settings)
        print(Style.dim("−") + " " + tr("信頼をやめました: \(root.path)"))
    }

    // MARK: GitHub からのインストール

    /// GitHub の公開リポジトリのスキルを、グローバルへ置く（スクリプトごと）。置いたスキルは、信頼の手続きなしで、いつも読み込まれる：取得元・許可するコマンドを、表示する。
    /// 流れ（版の決め方・取得・検査・置く）は `RemoteInstall`。ここは、表示と、終了コードだけ。
    private func install(names: [String], all: Bool, explicitRef: String?, overwrite: Bool) async {
        let defaultRef = "v\(AppInfo.version)"
        if names.isEmpty && !all {
            do { showListing(try await RemoteInstall.list(explicitRef: explicitRef, defaultRef: defaultRef)) }
            catch { failInstall(error) }
            return
        }
        let report: RemoteInstall.Report
        var problems: [SkillProblem] = []
        do {
            if all {
                let result = try await RemoteInstall.installAll(explicitRef: explicitRef, defaultRef: defaultRef, overwrite: overwrite)
                report = result.report
                problems = result.problems
            } else {
                report = try await RemoteInstall.install(names: names, explicitRef: explicitRef, defaultRef: defaultRef, overwrite: overwrite)
            }
        } catch { failInstall(error) }
        announce(report.source)
        var failures = 0
        var external: [SkillInstaller.Installed] = []
        for outcome in report.outcomes {
            switch outcome.result {
            case .success(let installed): showInstalled(installed); if installed.external != nil { external.append(installed) }
            case .failure(let failure): failures += 1; showFailure(failure, name: outcome.name, ref: report.source.ref)
            }
        }
        problems.forEach { print("  " + Style.yellow(tr("読めない: \($0.location)：\($0.reason)"))) }
        // 発話を、この Mac の外へ送るスキルを、入れたときは、見えるように（`vc` の基本は、外へ出さない：入れた人だけの例外）
        if !external.isEmpty {
            print("")
            notice(tr("次のスキルは、**使うと、発話や画面の画像を、この Mac の外へ送ります**：") + listJoin(external.map { item in let note = item.externalNotice ?? ""; return tr("\(item.name)（\(note)）") }) + tr("。要らなければ、`vc skills disable <name>`（選ばれなくなる）か、ディレクトリを消してください"))
        }
        if failures > 0 { fail(tr("\(failures) 件、インストールできませんでした")) }
        print("\n  " + tr("グローバルのスキルは、どこで起動しても、いつも読み込まれます。一覧：vc skills"))
    }

    private func announce(_ source: RemoteInstall.Source) {
        if source.fellBackToMain { notice(tr("版 v\(AppInfo.version) のタグが、リポジトリにありません。main から取得します")) }
        kv(tr("取得元"), "github.com/\(RemoteSkills.repository) @ \(source.ref)", width: colWidth(ja: 6, en: 12))
    }

    private func showListing(_ listing: RemoteInstall.Listing) {
        guard !listing.skills.isEmpty || !listing.problems.isEmpty else { fail(tr("リポジトリに、スキルがありません（\(RemoteSkills.repository) @ \(listing.source.ref)）")) }
        if listing.source.fellBackToMain { notice(tr("版 v\(AppInfo.version) のタグが、リポジトリにありません。main から取得します")) }
        heading(tr("インストールできるスキル"))
        kv(tr("取得元"), "github.com/\(RemoteSkills.repository) @ \(listing.source.ref)", width: colWidth(ja: 6, en: 12))
        let width = max(4, listing.skills.map { displayWidth($0.name) }.max() ?? 0)
        for s in listing.skills {
            let installed = FileManager.default.fileExists(atPath: VoiceControlHome.skillsDirectory.appendingPathComponent(s.name).path)
            print("  " + pad(s.name, to: width + 2) + s.description + (installed ? Style.dim(tr("（インストール済み）")) : "") + (s.external.map { Style.yellow(tr("（外へ送る：\($0)）")) } ?? ""))
        }
        listing.problems.forEach { print("  " + Style.yellow(tr("読めない: \($0.location)：\($0.reason)"))) }
        print("\n  " + tr("インストールする：vc skills install <name>…（すでにあれば、--force で置き換える）。すべて：vc skills install --all"))
    }

    private func showInstalled(_ installed: SkillInstaller.Installed) {
        print(Style.green("✓") + " " + Style.bold(installed.name) + (installed.overwritten ? tr(" を置き換えました") : tr(" をインストールしました")) + Style.dim("  → \(installed.destination.path)"))
        kv(tr("許可"), listJoin(installed.allowedCommands), width: colWidth(ja: 6, en: 12))
        kv(tr("確認"), installed.confirm ? tr("必須") : tr("なし"), width: colWidth(ja: 6, en: 12))
        if let notice = installed.externalNotice { kv(tr("外へ送る"), Style.yellow(notice), width: colWidth(ja: 6, en: 12)) }
        if installed.usesProjectRelativePath { notice(tr("SKILL.md が、プロジェクトからの相対パス（.voice-control/skills/…）を使っています。グローバルでは、起動した場所によって見つからないので、${SKILL_DIR} に直してください（docs/skills.md）")) }
    }

    private func showFailure(_ failure: SkillInstaller.Failure, name: String, ref: String) {
        let reason: String
        switch failure {
        case .notFound: reason = tr("リポジトリ（\(ref)）に、読めるスキルがありません（一覧：vc skills install）")
        case .unreadable(_, let why): reason = tr("SKILL.md が読めません（\(why)）")
        case .alreadyInstalled: reason = tr("すでにインストールされています。置き換えるなら --force")
        case .containsSymlink(_, let path): reason = tr("シンボリックリンク（\(path)）を含むので、置きません")
        case .copyFailed(_, let why): reason = tr("置けません（\(why)）")
        }
        print(Style.red("✗") + " " + tr("\(name)：\(reason)"))
    }

    /// 取得そのものの失敗（通信・版・形式）。
    private func failInstall(_ error: Error) -> Never {
        guard let failure = error as? RemoteSkills.Failure else { fail(tr("取得できません：\(error.localizedDescription)")) }
        switch failure {
        case .network(let reason): fail(tr("GitHub から取得できません（\(reason)）。ネットワークを確かめてください"))
        case .refNotFound(let missing): fail(tr("版 \(missing) が、リポジトリにありません（--ref で、タグかブランチを指定）"))
        case .unexpected(let reason): fail(tr("取得できません：\(reason)"))
        case .containsSymlink(let name, let path): fail(tr("\(name)：シンボリックリンク（\(path)）を含むので、取得しません"))
        }
    }
}
