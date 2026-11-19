import Foundation
import VCCore

struct UpdateCommand: Command {
    static let info = CommandInfo(
        name: "update", group: .evaluation, summary: tr("新しい版の確認と、取得・検証の確認（開発用。アプリは、入れ替えない）"),
        usage: ["vc update [--check]", tr("vc update --download-only <フォルダ> --app <アプリ>")],
        details: [
            tr("--check（既定）：GitHub の最新の Release を調べて、いまの版と比べる。利用者のデータは、送らない（公開情報の取得だけ）。"),
            tr("--download-only：新しい版を取得して、SHA-256 を照合し、ディスクイメージを開いて、アプリを <フォルダ> に写し、署名・bundle ID・版・指定要件を、--app（比べる、いまのアプリ）と照らす。**いまのアプリは、触らない**（入れ替えは、メニューバーのアプリだけが行う）。"),
            tr("環境変数 VC_UPDATE_CURRENT=<版>（例：0.5.6）で、いまの版を替えて、新しい版が出ている状態を、試せる。"),
        ],
        options: [("--check", tr("最新の版を調べる（既定）")), (tr("--download-only <フォルダ>"), tr("取得・照合・検証まで行う（入れ替えない）")), (tr("--app <アプリ>"), tr("比べる、いまのアプリ（.app）"))],
        examples: ["vc update", "VC_UPDATE_CURRENT=0.5.6 vc update --download-only /tmp/update-check --app build/VoiceControl.app"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let folder = arguments.option("--download-only")
        let appPath = arguments.option("--app")
        _ = arguments.flag("--check")
        let current = ProcessInfo.processInfo.environment["VC_UPDATE_CURRENT"].flatMap(AppVersion.init) ?? AppVersion(AppInfo.version) ?? AppVersion("0")!
        let release: ReleaseInfo
        do { release = try await UpdatePipeline.latest(currentVersion: current.description) } catch { fail("\(error)") }
        print(tr("いまの版: \(current)　最新の版: \(release.version)　→ \(release.version > current ? tr("更新できます") : tr("最新です"))"))
        print(tr("変更点: \(release.pageURL.absoluteString)"))
        guard let folder else { return }
        guard let appPath else { usageError("update", tr("--download-only には、--app（比べる、いまのアプリ）が要ります")) }
        guard release.version > current else { fail(tr("新しい版がないので、取得しません（VC_UPDATE_CURRENT で、いまの版を、下げて試せます）")) }
        guard let identity = await UpdatePipeline.identity(ofAppAt: (appPath as NSString).expandingTildeInPath) else { fail(tr("--app のアプリの署名を、読めません: \(appPath)")) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let staged = (folder as NSString).appendingPathComponent(".VoiceControl-update.app")
        print(tr("取得しています…（\(release.dmgName)）"))
        let started = Date()
        do {
            try await UpdatePipeline.prepare(release, current: identity, stagedPath: staged) { fraction in
                FileHandle.standardError.write(Data("\r  \(Int(fraction * 100))%".utf8))
            }
        } catch { fail("\n\(error)") }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        print("\n" + tr("✓ SHA-256 一致・署名と指定要件が、いまのアプリと同じ・版は \(release.version)（\(elapsed) 秒）"))
        print(tr("  置いた場所: \(staged)（入れ替えは、していません）"))
    }
}
