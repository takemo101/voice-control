import Foundation
import VCCore
import VCSpeech

struct MuteCommand: Command {
    static let info = CommandInfo(
        name: "mute", group: .settings, summary: "録音中に、ほかの音を消すか（流したまま／消す）の確認・変更",
        usage: ["vc mute [show]", "vc mute on", "vc mute off", "vc mute reset"],
        details: [
            "設定は ~/.voice-control/settings.json の mute。既定は on（録音の間だけ、出力〔スピーカー・ヘッドホン〕を消音にし、終わったら戻す。マイクが、再生中の音を拾わないように）。",
            "off にすると、音を流したまま録音する（音楽・通話の音は、マイクに入りうる）。",
            "その実行だけ替えるなら、vc listen の --mute・--no-mute（設定より優先）。次の vc listen から有効。",
        ],
        options: [],
        examples: ["vc mute", "vc mute off", "vc mute on", "vc mute reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let sub = arguments.positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("録音中の、ほかの音")
            let on = MutePreference.resolve(flag: nil, setting: settings.mute)
            kv("いまの設定", Style.bold(on ? "on（消す）" : "off（流したまま）") + Style.dim(settings.mute == nil ? "（既定）" : "（設定）"))
            print("")
            notice("変える：vc mute on / off。既定に戻す：vc mute reset。その実行だけ：vc listen --mute / --no-mute")
        case "on", "off":
            settings.mute = sub == "on"
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            heading("録音中の、ほかの音")
            kv("設定した", Style.bold(sub == "on" ? "on（録音中は消す）" : "off（録音中も流したまま）"))
            notice("次の vc listen から有効")
        case "reset":
            settings.mute = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（録音中は消す）に戻しました")
        default:
            usageError("mute", "知らないサブコマンド: \(sub)（show・on・off・reset）")
        }
    }
}
