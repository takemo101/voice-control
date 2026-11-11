import Foundation
import VCCore

struct CaptionCommand: Command {
    static let info = CommandInfo(
        name: "caption", group: .settings, summary: "録音中に聞こえている文字を、画面の上のパネルに出すか（実験）",
        usage: ["vc caption [show]", "vc caption on", "vc caption off", "vc caption reset"],
        details: [
            "設定は ~/.voice-control/settings.json の liveCaption。既定は on。",
            "声で頼む（vc listen --hotkey）・音声入力（vc dictate）で、**録音している間**、聞こえている文字（途中経過）を、上のパネルに出す。間違いに早く気づけて、途中で Esc で止められる。",
            "**表示だけ**：最終の文字・実行は、いつもどおり、録音したあとの認識の結果。表示の認識は、録音の音を、リアルタイムに、もう 1 回認識する（その間、CPU を少し使う）。Apple の認識の言語モデルが、入っていなければ、何も出ない。音声は、この Mac の外へ出さない。",
            "off にすると、出さない。次の vc listen --hotkey・vc dictate から有効。",
        ],
        options: [],
        examples: ["vc caption", "vc caption off", "vc caption reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let sub = arguments.positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("録音中の文字")
            let on = settings.liveCaption ?? true
            kv("いまの設定", Style.bold(on ? "on（録音中に、聞こえている文字を出す）" : "off（出さない）") + Style.dim(settings.liveCaption == nil ? "（既定）" : ""))
            print("")
            notice("変える：vc caption on / off。既定に戻す：vc caption reset")
        case "on", "off":
            settings.liveCaption = sub == "on"
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            heading("録音中の文字")
            kv("設定した", Style.bold(sub))
            notice("次の vc listen --hotkey・vc dictate から有効")
        case "reset":
            settings.liveCaption = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（on）に戻しました")
        default:
            usageError("caption", "知らないサブコマンド: \(sub)（show・on・off・reset）")
        }
    }
}
