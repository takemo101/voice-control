import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

struct DoctorCommand: Command {
    static let info = CommandInfo(
        name: "doctor", group: .skills, summary: tr("動かすのに必要なものが、そろっているかを確かめる"),
        usage: [tr("vc doctor [--engine <エンジン>]")],
        details: [
            tr("Apple Intelligence（スキルの実行に使う言語モデル）・Tiny-Jev のモデル（スキルの選択）が使えるかを確かめ、使えないものは、直す手順を示す。"),
            tr("任意の機能に要るもの（agent-desktop・アクセシビリティ・画面収録・マイクの許可・設定ファイル）も確かめる。許可の確認ダイアログは出さず、設定も変えない。"),
            tr("必須（Apple Intelligence・Tiny-Jev）が使えなければ、終了コード 1。任意のものだけなら、0。"),
        ],
        options: [], examples: ["vc doctor", "vc doctor --engine ollama:qwen3.5:4b", "vc doctor --engine openai:qwen3-4b@1234"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let report = DoctorReport(checks: await Self.collect(context))
        heading("vc doctor" + Style.dim(tr("（vc \(AppInfo.version)・macOS \(Self.osVersion)）")))
        report.lines().forEach { print($0) }
        if report.hasFailure { exit(1) }
    }

    /// 確認の本体（`vc doctor` と、アプリの診断ウィンドウが使う）。
    /// `includeClipboard`：コピーした画像の様子（形式の名前だけ）も確かめる。アプリの診断ウィンドウは、利用者のクリップボードに触れない（false）。
    static func collect(_ context: CommandContext, includeClipboard: Bool = true) async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        // --- 必須：スキルの実行（vc run・声の入力）に要る ---
        // 設定の書き間違いは、診断の結果として見せる（診断ウィンドウは、アプリの中：終わらない）
        let engine: Engine
        do { engine = try context.choices?.engine ?? context.resolveEngine(settings: context.currentSettings()) } catch {
            checks.append(.fail(tr("実行するモデル"), "\(error)", fix: tr("設定ウィンドウ > モデル > エンジン")))
            engine = .apple
        }
        checks.append(Self.appleIntelligenceCheck(AppleIntelligence.current(), required: engine == .apple))
        checks.append(Self.tinyJevCheck(context))
        // --engine か設定で、Apple 以外を選んでいるときだけ：そのサーバーが動いていて、モデルがあるか（選んだものが使えなければ、必須の失敗）
        if engine != .apple {
            do { try await engine.verify(); checks.append(.ok(tr("実行するモデル"), tr("\(context.engineText ?? "") が使えます"))) }
            catch { checks.append(.fail(tr("実行するモデル"), "\(error)", fix: tr("サーバーを起動し、モデルを読み込む（Ollama：ollama pull <モデル>）"))) }
        }

        // --- 任意：ホットキー・声の入力・既定スキルに要る ---
        checks.append(Self.agentDesktopCheck())
        checks.append(ModifierHold.isTrusted
            ? .ok(tr("アクセシビリティ"), tr("許可されています（ホットキー・agent-desktop）"))
            : .warn(tr("アクセシビリティ"), tr("許可されていません"),
                    fix: tr("システム設定 > プライバシーとセキュリティ > アクセシビリティ で、voice-control（端末から動かしているなら、その端末アプリ）を許可してください")))
        checks.append(ScreenCapture.isAllowed
            ? .ok(tr("画面収録"), tr("許可されています（スクリーンショット：スクリーンショットのショートカット）"))
            : .warn(tr("画面収録"), tr("許可されていません（スクリーンショットを使うときだけ要ります）"), fix: ScreenCapture.permissionHint))
        // コピーした画像（image-ask）：いまのクリップボードの様子（形式の名前だけ：中身は、読まない）。「コピーしたのに選ばれない」を、切り分けるため
        if includeClipboard { checks.append(ImageSource.clipboard.missing.map { .ok(tr("クリップボード"), tr("画像は、ありません（\($0)）")) } ?? .ok(tr("クリップボード"), tr("画像が、あります（image-ask が使えます）"))) }
        checks.append(Self.microphoneCheck(MicRecorder.permission))
        checks.append(Self.speechCheck(context))
        let (_, problem) = Settings.loadOrDefault()
        let settingsFile = VoiceControlHome.settingsFile
        let settingsDetail = FileManager.default.fileExists(atPath: settingsFile.path) ? tr("読めます（\(settingsFile.path)）") : tr("まだありません（既定の設定で動きます）")
        checks.append(problem.map { .warn(tr("設定ファイル"), tr("読めません"), fix: "\($0)") } ?? .ok(tr("設定ファイル"), settingsDetail))
        return checks
    }

    /// `required`：スキルを実行するモデルが Apple のとき。ほかのエンジン（Ollama など）なら、要らないので、使えなくても、警告にとどめる。
    static func appleIntelligenceCheck(_ status: AppleIntelligence.Status, required: Bool = true) -> DoctorCheck {
        switch status {
        case .available: return .ok("Apple Intelligence", required ? tr("使えます（スキルの実行に使う言語モデル）") : tr("使えます（このエンジンでは、使いません）"))
        case .unavailable(let reason):
            return required ? .fail("Apple Intelligence", reason.summary, fix: reason.remedy)
                            : .warn("Apple Intelligence", tr("\(reason.summary)（このエンジンでは、使わないので、そのままで動きます）"), fix: reason.remedy)
        }
    }

    static func microphoneCheck(_ permission: MicRecorder.Permission, hosts: [HostApp] = HostApp.candidates()) -> DoctorCheck {
        switch permission {
        case .granted: return .ok(tr("マイク"), tr("許可されています"))
        case .notDetermined: return .warn(tr("マイク"), tr("まだ許可を聞いていません"), fix: tr("アプリ（VoiceControl.app）を起動すると、macOS が確認を出します"))
        case .denied:
            var fix = hosts.first.map { tr("システム設定 > プライバシーとセキュリティ > マイク で、vc を動かしている端末アプリ「\($0.name)」を許可してください（許可は、vc ではなく、動かしているアプリに付きます）") }
                ?? tr("システム設定 > プライバシーとセキュリティ > マイク で、vc を動かしている端末アプリを許可してください（許可は、vc ではなく、動かしているアプリに付きます）")
            if hosts.count > 1 { fix += " " + tr("候補：\(hosts.map(\.name).joined(separator: ", "))") }
            return .warn(tr("マイク"), tr("許可されていません"), fix: fix)
        }
    }

    static func tinyJevCheck(_ context: CommandContext) -> DoctorCheck {
        let fix = tr("設定ウィンドウ > モデル で取得（約 1.2 GB。SHA-256 を検証して \(TinyJevModel.defaultDirectory.path) に置く）")
        guard let dir = context.findModelDirectory() else { return .fail("Tiny-Jev", tr("モデルが見つかりません"), fix: fix) }
        guard TinyJevModel.isInstalled(in: dir) else {
            // 使う場所が、既定の置き場所ではない（--model・VC_MODEL_DIR・./models）と、設定ウィンドウでの取得では、直らない
            let custom = dir.standardizedFileURL.path != TinyJevModel.defaultDirectory.standardizedFileURL.path
            return .fail("Tiny-Jev", tr("モデルのファイルが、そろっていません（\(dir.path)）"),
                         fix: custom ? tr("\(dir.path) を直すか、--model・VC_MODEL_DIR を外して、\(fix)") : fix)
        }
        return .ok("Tiny-Jev", tr("あります（\(dir.path)）"))
    }

    /// 使う音声認識（`--stt`・`設定ウィンドウ > モデル > 音声認識`）。ダウンロードしたモデルを選んでいるのに、取得していなければ、失敗（声の入力 は、黙って Apple に切り替えずに、止まる）。
    static func speechCheck(_ context: CommandContext) -> DoctorCheck {
        let choice: SpeechChoice
        if let text = context.options.stt {
            switch SpeechChoice.parse(text) {
            case let .success(c): choice = c
            case let .failure(error): return .fail(tr("音声認識"), "\(error)", fix: tr("設定ウィンドウ > モデル > 音声認識"))
            }
        } else {
            switch context.currentSettings().speechChoice {
            case let .success(c): choice = c
            case let .failure(error): return .fail(tr("音声認識"), tr("settings.json の stt: \(error)"), fix: tr("設定ウィンドウ > モデル > 音声認識"))
            }
        }
        switch choice {
        case .apple: return .ok(tr("音声認識"), tr("Apple の SpeechTranscriber（オンデバイス）"))
        case let .local(model):
            return model.isInstalled
                ? .ok(tr("音声認識"), tr("\(model.name)（\(model.fileURL.path)）"))
                : .fail(tr("音声認識"), tr("\(model.name) を選んでいますが、取得していません"), fix: tr("設定ウィンドウ > モデル（Apple に戻す：設定ウィンドウ > モデル > 音声認識）"))
        }
    }

    /// 既定スキルが使う `agent-desktop` が、PATH にあるか（任意：なければ、既定スキルが画面を読めない）。
    static func agentDesktopCheck() -> DoctorCheck {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let found = paths.map({ $0 + "/agent-desktop" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return .ok("agent-desktop", tr("あります（\(found)）"))
        }
        return .warn("agent-desktop", tr("PATH にありません（既定スキルが、画面を読む・操作するのに使います）"), fix: "npm install -g agent-desktop")
    }
}

extension DoctorCommand {
    /// `27.0.1` の形（`operatingSystemVersionString` は、`Version 27.0.1 (Build …)` で、長い）。
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
