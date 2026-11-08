import Foundation
import VCCore

struct HandsFreeCommand: Command {
    static let info = CommandInfo(
        name: "handsfree", group: .settings, summary: "ちょっと押すと、黙るまで録音する（手放し）か、押している間だけか",
        usage: ["vc handsfree [show]", "vc handsfree on", "vc handsfree off", "vc handsfree reset"],
        details: [
            "設定は ~/.voice-control/settings.json の handsFree。既定は on。",
            "**押し続ける**：従来どおり、離すまで録音して、離すと認識（声で頼む・音声入力、どちらも）。",
            "**ちょっと押して離す**（0.5 秒以内。Shift など修飾キーの長押しは、長押しと判定されたあと 0.5 秒以内に離す）：離しても録音を続け、**黙ったら**認識する（声のあと 1.5 秒の無音・声がなければ 8 秒・最長 30 秒）。もう一度押して離すと、すぐ認識。Esc で取りやめ。",
            "off にすると、押している間だけ録音する（ちょっと押しは、何も起こさない）。次の vc listen --hotkey・vc dictate から有効。",
        ],
        options: [],
        examples: ["vc handsfree", "vc handsfree off", "vc handsfree reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let sub = arguments.positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("手放しの録音")
            let on = settings.handsFree ?? true
            kv("いまの設定", Style.bold(on ? "on（ちょっと押すと、黙るまで録音）" : "off（押している間だけ）") + Style.dim(settings.handsFree == nil ? "（既定）" : "（設定）"))
            print("")
            notice("変える：vc handsfree on / off。既定に戻す：vc handsfree reset")
        case "on", "off":
            settings.handsFree = sub == "on"
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            heading("手放しの録音")
            kv("設定した", Style.bold(sub == "on" ? "on（ちょっと押すと、黙るまで録音）" : "off（押している間だけ）"))
            notice("次の vc listen --hotkey・vc dictate から有効")
        case "reset":
            settings.handsFree = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（on）に戻しました")
        default:
            usageError("handsfree", "知らないサブコマンド: \(sub)（show・on・off・reset）")
        }
    }
}
