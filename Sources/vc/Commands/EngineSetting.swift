import Foundation
import VCCore
import VCSkill

struct EngineCommand: Command {
    static let info = CommandInfo(
        name: "engine", group: .settings, summary: "スキルを実行するモデル（分析・実行の言語モデル）の確認・変更",
        usage: ["vc engine [show]", "vc engine set <apple|ollama:<モデル>|openai:<モデル>@<ポート>>", "vc engine reset"],
        details: [
            "設定は ~/.voice-control/settings.json の engine。既定は apple（Apple のオンデバイスのモデル）。",
            "ollama:<モデル>（例：ollama:qwen3.5:4b）は、この Mac の Ollama。openai:<モデル>@<ポート>（例：openai:qwen3-4b@1234）は、この Mac の OpenAI 互換サーバー（LM Studio・llama.cpp など）。通信先は 127.0.0.1 だけ。クラウドのモデルは使えない。",
            "スキルを選ぶ Tiny-Jev は、どれでも同じ。許可の照合・上限・確認も、モデルに関わらず同じ。",
            "set は、書き方だけを確かめる（サーバーが動いているかは、vc doctor で）。その実行だけ替えるなら、--engine（設定より優先）。",
        ],
        options: [],
        examples: ["vc engine", "vc engine set ollama:qwen3.5:4b", "vc engine set apple", "vc engine reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let positionals = arguments.positionals
        let sub = positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("実行するモデル")
            switch Result(catching: { try Engine.parse(settings.engine ?? "apple") }) {
            case .success: kv("いまの設定", Style.bold(settings.engine ?? "apple") + Style.dim(settings.engine == nil ? "（既定）" : "（設定）"))
            case let .failure(error): kv("いまの設定", Style.red("\(settings.engine ?? "")：\(error)"))
            }
            print("")
            notice("変える：vc engine set <apple|ollama:<モデル>|openai:<モデル>@<ポート>>。戻す：vc engine reset。確かめる：vc doctor")
        case "set":
            guard positionals.count >= 2 else { usageError("engine", "エンジンを渡してください（例: vc engine set ollama:qwen3.5:4b）") }
            let text = positionals[1]
            do { _ = try Engine.parse(text) } catch { fail("\(error)") }
            settings.engine = text == "apple" ? nil : text
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            heading("実行するモデル")
            kv("設定した", Style.bold(text))
            notice("サーバーが動いているか、モデルがあるかは、vc doctor で確かめる。次の vc run・vc listen から有効")
        case "reset":
            settings.engine = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（apple）に戻しました")
        default:
            usageError("engine", "知らないサブコマンド: \(sub)（show・set・reset）")
        }
    }
}
