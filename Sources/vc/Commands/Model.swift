import Foundation
import VCCore
import VCDecision
import VCSpeech

struct ModelCommand: Command {
    static let info = CommandInfo(
        name: "model", group: .settings, summary: "モデルの一覧・確認・取得（~/.voice-control/models）",
        usage: ["vc model list", "vc model [status [<ID>] [--verify]]", "vc model download [<ID>] [--force]", "vc model path [<ID>]", "vc model delete <ID>"],
        details: [
            "モデルは 2 種類。Tiny-Jev 0.6B（スキルを選ぶ。約 1.2 GB。ID を省くと、これ）と、音声認識のモデル（任意。Whisper large-v3-turbo。約 0.9 GB）。~/.voice-control/models/<ID> に置く（VC_HOME で ~/.voice-control を変えられる）。",
            "download：版を固定した Hugging Face から取得し、SHA-256 を検証する。取得済みで一致するファイルは飛ばす。途中で切れたら、もう一度実行すると、続きから取る。通信は、モデルの取得だけ。",
            "status：置き場所・ファイルの有無と大きさ。--verify で SHA-256 まで確かめる。path：置き場所だけを出す。delete：音声認識のモデルを消す（使っている設定は、vc stt reset で戻す）。",
            "音声認識のモデルを使うには、取得して、vc stt set <ID>（または --stt <ID>）。",
        ],
        options: [("--verify", "status：SHA-256 まで確かめる"), ("--force", "download：取得済みでも、取り直す")],
        examples: ["vc model list", "vc model download", "vc model download whisper-large-v3-turbo", "vc model status whisper-large-v3-turbo --verify"])

    /// 扱うモデル 1 つ。
    private struct Target {
        let id: String
        let title: String
        let spec: ModelSpec
        /// 音声認識のモデルか（Tiny-Jev は、`delete` の対象外）。
        let speech: Bool
    }

    private static var targets: [Target] {
        [Target(id: TinyJevModel.spec.name, title: "Tiny-Jev 0.6B（スキルの選択）", spec: TinyJevModel.spec, speech: false)]
            + SpeechModelCatalog.all.map { Target(id: $0.id, title: "\($0.name)（音声認識）", spec: $0.spec, speech: true) }
    }

    private func target(_ id: String?) -> Target {
        guard let id else { return Self.targets[0] }
        if id == "tiny-jev" { return Self.targets[0] }
        guard let found = Self.targets.first(where: { $0.id == id }) else {
            usageError("model", "知らないモデル: \(id)（\(Self.targets.map(\.id).joined(separator: "・"))）")
        }
        return found
    }

    private func size(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc model [list]／status [<ID>] [--verify]／download [<ID>] [--force]／path [<ID>]／delete <ID>
        var arguments = arguments
        let positionals = arguments.positionals
        let sub = positionals.first ?? "status"
        let id = positionals.dropFirst().first
        switch sub {
        case "list":
            heading("モデル")
            for t in Self.targets {
                let dir = ModelStore.defaultDirectory(for: t.spec)
                let installed = ModelStore.isInstalled(t.spec, in: dir)
                let total = t.spec.files.reduce(Int64(0)) { $0 + $1.bytes }
                kv(t.id, "\(t.title)・約 \(size(total))・" + (installed ? Style.green("取得済み") : Style.dim("未取得")), width: 24)
            }
            print("")
            notice("取得：vc model download <ID>。音声認識を替える：vc stt set <ID>")
        case "path":
            print(ModelStore.defaultDirectory(for: target(id).spec).path)
        case "status":
            let t = target(id)
            let dir = ModelStore.defaultDirectory(for: t.spec)
            let verify = arguments.flag("--verify")
            heading("モデル（\(t.title)）")
            kv("置き場所", dir.path)
            var allGood = true
            for file in t.spec.files {
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
            if !t.speech {
                if let used = context.modelCandidates.first(where: { FileManager.default.fileExists(atPath: $0 + "/tokenizer.json") }) {
                    kv("使う場所", used, width: 18)
                } else {
                    kv("使う場所", Style.red("見つからない"), width: 18)
                }
            }
            if !allGood { notice("取得する：vc model download \(t.speech ? t.id : "")（約 \(size(t.spec.files.reduce(0) { $0 + $1.bytes }))。SHA-256 を検証して置く）") }
        case "download":
            let t = target(id)
            let dir = ModelStore.defaultDirectory(for: t.spec)
            let force = arguments.flag("--force")
            let total = t.spec.files.reduce(Int64(0)) { $0 + $1.bytes }
            heading("モデルの取得（\(t.title)）")
            kv("取得元", t.spec.baseURL.absoluteString)
            kv("置き場所", dir.path)
            kv("大きさ", "約 \(size(total))" + Style.dim("（途中で切れたら、もう一度実行すると続きから。取得したファイルは SHA-256 で検証する）"))
            notice("モデルの取得だけが、外部との通信です。音声・画面は、送りません")
            let printer = ProgressPrinter(tty: isatty(1) != 0)
            do {
                try await ModelStore.download(t.spec, to: dir, force: force) { printer.report($0) }
                printer.finish()
                print(Style.green("✓") + " 取得して、SHA-256 を検証しました: \(dir.path)")
                notice(t.speech ? "使う：vc stt set \(t.id)（または vc listen --hotkey --stt \(t.id)）" : "使う：vc skills・vc run \"…\"")
            } catch {
                printer.finish()
                fail("\(error)")
            }
        case "delete":
            guard let id else { usageError("model", "消すモデルの ID を渡してください（例: vc model delete whisper-large-v3-turbo）") }
            let t = target(id)
            guard t.speech else { fail("\(t.title) は、消せません（スキルの選択に使う。ファイルを消すなら、\(ModelStore.defaultDirectory(for: t.spec).path) を、手で）") }
            let dir = ModelStore.defaultDirectory(for: t.spec)
            guard FileManager.default.fileExists(atPath: dir.path) else { fail("\(t.id) は、取得していません") }
            do { try FileManager.default.removeItem(at: dir) } catch { fail("消せませんでした: \(error)") }
            print(Style.green("✓") + " 消しました: \(dir.path)")
            if case let .success(.local(model)) = context.currentSettings().speechChoice, model.id == t.id {
                notice("設定は、このモデルのままです。Apple に戻す：vc stt reset")
            }
        default:
            usageError("model", "知らないサブコマンド: \(sub)（list・status・download・path・delete）")
        }
    }
}
