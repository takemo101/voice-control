import Foundation
import VCCore
import VCDecision

struct ModelCommand: Command {
    static let info = CommandInfo(
        name: "model", group: .settings, summary: "Tiny-Jev のモデルの確認・取得（~/.voice-control/models）",
        usage: ["vc model [status [--verify]]", "vc model download [--force]", "vc model path"],
        details: [
            "Tiny-Jev 0.6B（約 1.2 GB）を、~/.voice-control/models/tiny-jev-0.6b に置く（VC_HOME で ~/.voice-control を変えられる）。",
            "download：版を固定した Hugging Face から取得し、SHA-256 を検証する。取得済みで一致するファイルは飛ばす。途中で切れたら、もう一度実行すると続きから。モデルの取得だけが、外部との通信（音声・画面は送らない）。",
            "status：置き場所・ファイルの有無と大きさ・実際に使われる場所。--verify で SHA-256 まで確かめる。path：置き場所だけを出す。",
        ],
        options: [("--verify", "status：SHA-256 まで確かめる"), ("--force", "download：取得済みでも、取り直す")],
        examples: ["vc model download", "vc model status --verify"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc model [status [--verify]]／download [--force]／path：Tiny-Jev のモデル（~/.voice-control/models/tiny-jev-0.6b）の確認・取得。
        var arguments = arguments
        let sub = arguments.positionals.first ?? "status"
        let spec = ModelSpec.tinyJev06
        let dir = ModelStore.defaultDirectory(for: spec)
        func size(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        switch sub {
        case "path":
            print(dir.path)
        case "status":
            let verify = arguments.flag("--verify")
            heading("モデル（Tiny-Jev 0.6B）")
            kv("置き場所", dir.path)
            var allGood = true
            for file in spec.files {
                let label: String
                switch ModelStore.state(of: file, in: dir) {
                case .missing: label = Style.red("なし"); allGood = false
                case let .wrongSize(actual): label = Style.red("大きさが違う（\(size(actual))。期待 \(size(file.bytes))）"); allGood = false
                case .present:
                    if verify {
                        let ok = ModelStore.verify(file, in: dir)
                        label = ok ? Style.green("あり・SHA-256 一致") : Style.red("SHA-256 が一致しない")
                        allGood = allGood && ok
                    } else {
                        label = Style.green("あり") + Style.dim("（\(size(file.bytes))。SHA-256 は --verify で確かめる）")
                    }
                }
                kv(file.name, label, width: 18)
            }
            let candidates = [context.options.model, ProcessInfo.processInfo.environment["VC_MODEL_DIR"], dir.path, "models/tiny-jev-0.6b"].compactMap { $0 }.filter { !$0.isEmpty }
            if let used = candidates.first(where: { FileManager.default.fileExists(atPath: $0 + "/tokenizer.json") }) {
                kv("使う場所", used, width: 18)
            } else {
                kv("使う場所", Style.red("見つからない"), width: 18)
            }
            if !allGood { notice("取得する：vc model download（約 \(size(spec.files.reduce(0) { $0 + $1.bytes }))。SHA-256 を検証して置く）") }
        case "download":
            let force = arguments.flag("--force")
            let total = spec.files.reduce(Int64(0)) { $0 + $1.bytes }
            heading("モデルの取得（Tiny-Jev 0.6B）")
            kv("取得元", spec.baseURL.absoluteString)
            kv("置き場所", dir.path)
            kv("大きさ", "約 \(size(total))" + Style.dim("（途中で切れたら、もう一度実行すると続きから。取得したファイルは SHA-256 で検証する）"))
            notice("モデルの取得だけが、外部との通信です。音声・画面は、送りません")
            let tty = isatty(1) != 0
            let printer = ProgressPrinter(tty: tty)
            do {
                try await ModelStore.download(spec, to: dir, force: force) { printer.report($0) }
                printer.finish()
                print(Style.green("✓") + " 取得して、SHA-256 を検証しました: \(dir.path)")
                notice("使う：vc skills・vc run \"…\"")
            } catch {
                printer.finish()
                fail("\(error)")
            }
        default:
            usageError("model", "知らないサブコマンド: \(sub)（status・download・path）")
        }
    }
}
