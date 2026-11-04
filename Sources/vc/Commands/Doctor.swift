import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

struct DoctorCommand: Command {
    static let info = CommandInfo(
        name: "doctor", group: .settings, summary: "動かすのに必要なものが、そろっているかを確かめる",
        usage: ["vc doctor"],
        details: [
            "Apple Intelligence（スキルの実行に使う言語モデル）・Tiny-Jev のモデル（スキルの選択）が使えるかを確かめ、使えないものは、直す手順を示す。",
            "任意の機能に要るもの（agent-desktop・アクセシビリティ・マイクの許可・設定ファイル）も確かめる。許可の確認ダイアログは出さず、設定も変えない。",
            "必須（Apple Intelligence・Tiny-Jev）が使えなければ、終了コード 1。任意のものだけなら、0。",
        ],
        options: [], examples: ["vc doctor"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var checks: [DoctorCheck] = []

        // --- 必須：スキルの実行（vc run・vc listen）に要る ---
        checks.append(Self.appleIntelligenceCheck(AppleIntelligence.current()))
        checks.append(Self.tinyJevCheck(context))

        // --- 任意：ホットキー・声の入力・既定スキルに要る ---
        checks.append(Self.agentDesktopCheck())
        checks.append(ModifierHold.isTrusted
            ? .ok("アクセシビリティ", "許可されています（ホットキー・agent-desktop）")
            : .warn("アクセシビリティ", "許可されていません",
                    fix: "vc を動かす端末アプリに、許可が要ります：システム設定 > プライバシーとセキュリティ > アクセシビリティ（agent-desktop permissions でも確かめられます）"))
        checks.append(Self.microphoneCheck(MicRecorder.permission))
        let (_, problem) = Settings.loadOrDefault()
        checks.append(problem.map { .warn("設定ファイル", "読めません", fix: "\($0)") } ?? .ok("設定ファイル", "読めます（\(VoiceControlHome.settingsFile.path)）"))

        let report = DoctorReport(checks: checks)
        heading("vc doctor" + Style.dim("（vc \(AppInfo.version)・macOS \(Self.osVersion)）"))
        report.lines().forEach { print($0) }
        if report.hasFailure { exit(1) }
    }

    static func appleIntelligenceCheck(_ status: AppleIntelligence.Status) -> DoctorCheck {
        switch status {
        case .available: return .ok("Apple Intelligence", "使えます（スキルの実行に使う言語モデル）")
        case .unavailable(let reason): return .fail("Apple Intelligence", reason.summary, fix: reason.remedy)
        }
    }

    static func microphoneCheck(_ permission: MicRecorder.Permission) -> DoctorCheck {
        switch permission {
        case .granted: return .ok("マイク", "許可されています")
        case .notDetermined: return .warn("マイク", "まだ許可を聞いていません", fix: "最初の vc listen で、macOS が確認を出します（声の入力を使うとき）")
        case .denied: return .warn("マイク", "許可されていません", fix: "システム設定 > プライバシーとセキュリティ > マイク で、vc を動かす端末アプリを許可してください")
        }
    }

    static func tinyJevCheck(_ context: CommandContext) -> DoctorCheck {
        let fix = "vc model download（約 1.2 GB。SHA-256 を検証して ~/.voice-control/models に置く）"
        guard let dir = context.findModelDirectory() else { return .fail("Tiny-Jev", "モデルが見つかりません", fix: fix) }
        guard ModelStore.isInstalled(in: dir) else { return .fail("Tiny-Jev", "モデルのファイルが、そろっていません（\(dir.path)）", fix: fix) }
        return .ok("Tiny-Jev", "あります（\(dir.path)）")
    }

    /// 既定スキルが使う `agent-desktop` が、PATH にあるか（任意：なければ、既定スキルが画面を読めない）。
    static func agentDesktopCheck() -> DoctorCheck {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let found = paths.map({ $0 + "/agent-desktop" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return .ok("agent-desktop", "あります（\(found)）")
        }
        return .warn("agent-desktop", "PATH にありません（既定スキルが、画面を読む・操作するのに使います）", fix: "npm install -g agent-desktop")
    }
}

extension DoctorCommand {
    /// `27.0.1` の形（`operatingSystemVersionString` は、`Version 27.0.1 (Build …)` で、長い）。
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
