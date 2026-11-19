import AppKit
import Foundation
import VCCore

/// 更新の状態と操作（メニュー・設定ウィンドウが見る）。確認は、起動時と 1 日ごと（設定 `updateCheck`。既定で、する）。**入れるのは、利用者が選んだときだけ**。
@MainActor final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        /// 準備中（取得・照合・検証）。`fraction`：ダウンロードの進み（0〜1。分からなければ nil）。
        case preparing(fraction: Double?)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var lastChecked: Date?
    private var timer: Timer?
    private var announced: AppVersion?

    /// いまの版。開発用に、環境変数 `VC_UPDATE_CURRENT`（例：`0.5.6`）で、替えられる（更新の確認を、新しい版が出ていない状態で、試すため）。
    var currentVersion: AppVersion {
        ProcessInfo.processInfo.environment["VC_UPDATE_CURRENT"].flatMap(AppVersion.init) ?? AppVersion(AppInfo.version) ?? AppVersion("0")!
    }

    /// 更新できる版（あれば）。
    var available: ReleaseInfo? { if case let .available(info) = phase { return info }; return nil }

    var isBusy: Bool { switch phase { case .checking, .preparing: return true; default: return false } }

    // MARK: 確認

    /// 起動時に呼ぶ：確認して、以後、1 時間ごとに「間隔が空いたか」を見る（設定を切っていれば、何もしない）。
    func startAutomaticChecks() {
        guard timer == nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkIfDue() } }
    }

    private func checkIfDue() {
        guard Settings.loadOrDefault().settings.updateCheck ?? true, !isBusy, ReleaseFeed.isDue(lastChecked: lastChecked, now: Date()) else { return }
        Task { await check(manual: false) }
    }

    /// 最新の版を調べる。`manual`：利用者の操作（失敗も、画面に出す。自動のときは、静かに、次の機会を待つ）。
    func check(manual: Bool) async {
        guard !isBusy else { return }
        if manual || available == nil { phase = .checking }
        do {
            let release = try await UpdatePipeline.latest(currentVersion: currentVersion.description)
            lastChecked = Date()
            if release.version > currentVersion {
                phase = .available(release)
                if !manual, announced != release.version { announced = release.version; announce(release) }
            } else {
                phase = .upToDate
            }
        } catch {
            lastChecked = manual ? lastChecked : Date()   // 自動の失敗は、1 日、待つ（通信できない間、何度も試さない）
            phase = manual ? .failed("\(error)") : (available.map { .available($0) } ?? .idle)
        }
    }

    /// 新しい版が見つかったことを、上のパネルで、1 度だけ知らせる（押さなくても消える。更新は、メニューから）。
    private func announce(_ release: ReleaseInfo) {
        HUD.shared.show(HUDContent(phase: .info, title: "新しいバージョン \(release.version) があります", hint: "メニューバーの「更新」から、入れられます", chip: "更新"), hideAfter: 6)   // l10n-skip
    }

    // MARK: 更新

    /// 場所の問題（入れ替えられない理由）。なければ nil。
    var installBlock: InstallPlan.Block? {
        InstallPlan.block(appPath: Bundle.main.bundlePath, isWritable: { FileManager.default.isWritableFile(atPath: $0) })
    }

    /// 利用者に確かめてから、更新する（取得・検証 → 入れ替えを背景で始める → このアプリを終える）。
    func confirmAndInstall() {
        guard let release = available, !isBusy else { return }
        if let block = installBlock {
            AppAlerts.show(title: tr("ここでは、更新できません"), message: "\(block)\n\n" + tr("新しい版（\(release.version)）は、リリースのページから、取得できます。"), style: .warning)
            return
        }
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = tr("\(release.version) に更新しますか？")
        alert.informativeText = [
            tr("いまは \(currentVersion) です。更新すると、アプリは、いったん終わって、新しい版で開き直します。"),
            tr("更新のあとで、アクセシビリティなどの許可が、無効になることがあります（このアプリは、Apple の開発者の署名を、まだ使っていません）。そのときは、設定 > 一般 の「準備状況」から、付け直してください。"),
        ].joined(separator: "\n\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("更新して、開き直す"))
        alert.addButton(withTitle: tr("変更点を見る"))
        alert.addButton(withTitle: tr("あとで"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    private func install(_ release: ReleaseInfo) {
        let appPath = Bundle.main.bundlePath
        phase = .preparing(fraction: nil)
        Task {
            guard let current = await UpdatePipeline.identity(ofAppAt: appPath) else {
                phase = .failed(tr("いまのアプリの署名を、読めませんでした。入れ替えません"))
                return
            }
            let staged = InstallPlan.stagedPath(for: appPath)
            do {
                try await UpdatePipeline.prepare(release, current: current, stagedPath: staged) { fraction in
                    Task { @MainActor in UpdateModel.shared.setProgress(fraction) }
                }
            } catch {
                phase = .failed("\(error)")
                return
            }
            if let why = UpdateSwap.launch(staged: staged, target: appPath) {
                try? FileManager.default.removeItem(atPath: staged)
                phase = .failed(why)
                return
            }
            NSApplication.shared.terminate(nil)   // 入れ替えは、このアプリが終わるのを待って、背景で行われる
        }
    }

    private func setProgress(_ fraction: Double) {
        if case .preparing = phase { phase = .preparing(fraction: fraction) }
    }
}
