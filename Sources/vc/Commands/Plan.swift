import Foundation
import VCCore
import VCSkill

struct PlanCommand: Command {
    static let info = CommandInfo(
        name: "plan", group: .settings, summary: "1 つの依頼を、複数のステップに分けて実行するか（言語モデルが決める）の確認・変更",
        usage: ["vc plan [show]", "vc plan on", "vc plan off", "vc plan reset"],
        details: [
            "設定は ~/.voice-control/settings.json の multiStep。既定は on。",
            "on：依頼の文を、言語モデル（vc engine。既定は Apple）が、実行する順のステップ（依頼から切り出した短い文）に分ける。**別のスキルが要る所で分ける**（「Claude で調べて、そのあと Spotify で次の曲」）。**分け方を決めるのは、言語モデル**で、コードは、出力を検査する（依頼にない内容を足したもの・4 つ以上・読めない出力は、分けない）。",
            "分けたら、ステップごとに、Tiny-Jev がスキルを選び、確認と許可の照合も、ステップごとに行う（権限は広がらない）。最初の失敗で止まる（済んだステップは、元に戻さない）。前のステップの結果は、スキルが accepts-previous: true のときだけ、信頼しないデータとして、次へ渡す。",
            "off：いままでどおり、1 依頼 = 1 スキル（分ける言語モデルの呼び出しも、なくなる）。その実行だけ：vc run の --no-plan。vc run --skill でスキルを指定したときは、分けない。",
        ],
        options: [],
        examples: ["vc plan", "vc plan off", "vc plan on", "vc plan reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let sub = arguments.positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("依頼を、複数のステップに分ける")
            let on = PlanPreference.isEnabled(setting: settings.multiStep)
            kv("いまの設定", Style.bold(on ? "on（分ける）" : "off（1 依頼 = 1 スキル）") + Style.dim(settings.multiStep == nil ? "（既定）" : "（設定）"))
            print("")
            notice("変える：vc plan on / off。既定に戻す：vc plan reset。その実行だけ：vc run --no-plan")
        case "on", "off":
            settings.multiStep = sub == "on"
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 依頼を、複数のステップに分けるのを " + Style.bold(sub) + " にしました" + Style.dim("（次の依頼から有効）"))
        case "reset":
            settings.multiStep = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（\(PlanPreference.defaultEnabled ? "on" : "off")）に戻しました")
        default:
            usageError("plan", "知らないサブコマンド: \(sub)（show・on・off・reset）")
        }
    }
}
