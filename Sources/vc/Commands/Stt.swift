import Foundation
import VCCore
import VCSpeech

struct SttCommand: Command {
    static let info = CommandInfo(
        name: "stt", group: .settings, summary: "使う音声認識（Apple か、ダウンロードしたモデル）の確認・変更",
        usage: ["vc stt [show]", "vc stt set <apple|ID>", "vc stt reset"],
        details: [
            "設定は ~/.voice-control/settings.json の stt。既定は apple（Apple の SpeechTranscriber。オンデバイス）。",
            "ダウンロードしたモデル（例：whisper-large-v3-turbo）は、先に vc model download <ID>。取得していないモデルは、選べない（黙って Apple に切り替えない）。",
            "どちらも、音声は、この Mac の外へ出さない。認識の前に、声のない録音（無音・一定の雑音）は、捨てる。",
            "その実行だけ替えるなら、--stt <apple|ID>（vc listen・vc transcribe）。",
        ],
        options: [],
        examples: ["vc stt", "vc stt set whisper-large-v3-turbo", "vc stt reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let positionals = arguments.positionals
        let sub = positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("音声認識")
            switch settings.speechChoice {
            case let .success(choice):
                kv("いまの設定", Style.bold(choice.id) + Style.dim("（\(choice.title)）"))
                if case let .local(model) = choice {
                    kv("モデル", model.isInstalled ? Style.green("取得済み") : Style.red("未取得") + Style.dim("（vc model download \(model.id)）"))
                }
            case let .failure(error):
                kv("いまの設定", Style.red("\(error)"))
            }
            print("")
            for model in SpeechModelCatalog.all { kv(model.id, model.name + Style.dim("・\(model.summary)"), width: 24) }
            print("")
            notice("変える：vc stt set <apple|ID>。戻す：vc stt reset。一覧と取得：vc model list")
        case "set":
            guard positionals.count >= 2 else { usageError("stt", "apple かモデルの ID を渡してください（例: vc stt set whisper-large-v3-turbo）") }
            switch SpeechChoice.parse(positionals[1]) {
            case let .failure(error): fail("\(error)")
            case let .success(choice):
                if case let .local(model) = choice, !model.isInstalled { fail("モデル \(model.name) を取得していません（vc model download \(model.id)）") }
                settings.stt = choice.id == "apple" ? nil : choice.id
                do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
                heading("音声認識")
                kv("設定した", Style.bold(choice.id) + Style.dim("（\(choice.title)）"))
                notice("次の vc listen から有効")
            }
        case "reset":
            settings.stt = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（Apple の SpeechTranscriber）に戻しました")
        default:
            usageError("stt", "知らないサブコマンド: \(sub)（show・set・reset）")
        }
    }
}
