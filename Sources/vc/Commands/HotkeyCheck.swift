import AppKit
import Foundation
import VCSpeech

struct HotkeyCheckCommand: Command {
    static let info = CommandInfo(
        name: "hotkey-check", group: .evaluation, summary: "トリガーが届くかを確かめる（マイクは使わない）",
        usage: ["vc hotkey-check [--trigger <キー>] [--seconds <秒>]"],
        details: ["押した・離したを表示し、画面の上に「録音中」を出す。**ダブルタップ**（手放し。vc handsfree）も確かめられる：「手放し」と出て、もう一度タップすると終わる（無音の判定は、マイクを使うので、ここでは、しない）。いまの設定（vc hotkey）を使う。既定は 10 秒間。"],
        options: [("--trigger <キー>", "この回だけのトリガー"), ("--seconds <秒>", "待つ時間（既定 10）")],
        examples: ["vc hotkey-check", "vc hotkey-check --trigger ctrl+opt+space"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let seconds = arguments.option("--seconds").flatMap(Double.init) ?? 10
        do {
            let (spec, source) = context.resolveHotKey()
            let hotkey = HandsFreeTrigger(try makeTrigger(spec))
            hotkey.onHandsFree = {
                print(Style.yellow("◆ 手放し（ダブルタップ）：もう一度タップで終わり")); fflush(stdout)
                HUD.shared.show("手放しの録音（テスト）　もう一度タップで終わり（\(spec.displayName)）", mode: .recording)
            }
            hotkey.onPress = {
                print(Style.green("▼ pressed")); fflush(stdout)
                HUD.shared.show("録音中（テスト）　離すと終わり（\(spec.displayName)）", mode: .recording)
            }
            hotkey.onRelease = {
                print(Style.dim("▲ released")); fflush(stdout)
                HUD.shared.show("離しました", mode: .info, hideAfter: 1)
            }
            print("\(holdInstruction(spec))て、離す" + Style.dim("（\(spec.description)・\(source)・\(Int(seconds)) 秒間。マイクは使いません）"))
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { _ = hotkey; exit(0) }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } catch { fail("ホットキーを登録できません: \(error)") }
    }
}
