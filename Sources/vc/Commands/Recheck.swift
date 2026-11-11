import Foundation
import VCCore
import VCSpeech

struct RecheckCommand: Command {
    static let info = CommandInfo(
        name: "recheck", group: .settings, summary: "聞き取りに自信がないとき、実行の前に、聞こえた文を確かめるか（実験）",
        usage: ["vc recheck [show]", "vc recheck on", "vc recheck off", "vc recheck reset"],
        details: [
            "設定は ~/.voice-control/settings.json の recheck。既定は on。",
            "声で頼む（vc listen --hotkey）で、**認識の確信度が \(Int(Recheck.threshold * 100))% 未満**のとき、実行の前に、「聞こえた文」を出して、確認する（ボタン・キー・声の「はい」）。「やめる」なら、実行しない。聞き間違いによる、誤った実行を減らすため。",
            "確信度は、Apple の SpeechTranscriber が付ける（文字ごとの確信度の、文字数で重みづけた平均）。Whisper（vc stt）は、確信度を付けないので、確認しない。音声入力（vc dictate）には、使わない（入力した文字が、見える）。",
            "**限界**：自信のある聞き間違い（「グロック」→「ブロック」など、似た音）は、確信度が高いので、確かめられない。しきい値は、自作の合成音声で決めた（実際の声では、未確認）。",
            "off にすると、確認しない。次の vc listen --hotkey から有効。",
        ],
        options: [],
        examples: ["vc recheck", "vc recheck off", "vc recheck reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let sub = arguments.positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("聞き取りの確認")
            let on = settings.recheck ?? true
            kv("いまの設定", Style.bold(on ? "on（確信度が \(Int(Recheck.threshold * 100))% 未満なら、聞こえた文を確認）" : "off（確認しない）") + Style.dim(settings.recheck == nil ? "（既定）" : ""))
            print("")
            notice("変える：vc recheck on / off。既定に戻す：vc recheck reset")
        case "on", "off":
            settings.recheck = sub == "on"
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            heading("聞き取りの確認")
            kv("設定した", Style.bold(sub == "on" ? "on" : "off"))
            notice("次の vc listen --hotkey から有効")
        case "reset":
            settings.recheck = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（on）に戻しました")
        default:
            usageError("recheck", "知らないサブコマンド: \(sub)（show・on・off・reset）")
        }
    }
}

/// 聞き取りの確認の、決まり。
enum Recheck {
    /// 確信度が、これ未満なら、確認する。自作の合成音声で決めた（聞き違い 11 件のうち 5 件を捕まえ、正しい 9 件は、1 件も止めなかった）。実際の声での、調整は、これから。
    static let threshold = 0.90
}
