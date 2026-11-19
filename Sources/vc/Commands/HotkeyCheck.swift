import AppKit
import Foundation
import VCCore
import VCSpeech

struct HotkeyCheckCommand: Command {
    static let info = CommandInfo(
        name: "hotkey-check", group: .evaluation, summary: tr("トリガーが届くかを確かめる（マイクは使わない）"),
        usage: [tr("vc hotkey-check [--trigger <キー>] [--seconds <秒>]")],
        details: [tr("押した・離したを表示し、画面の上に「録音中」を出す。**ダブルタップ**（手放し。設定ウィンドウ > キー）も確かめられる：「手放し」と出て、もう一度タップすると終わる（無音の判定は、マイクを使うので、ここでは、しない）。いまの設定（vc hotkey）を使う。既定は 10 秒間。")],
        options: [(tr("--trigger <キー>"), tr("この回だけのトリガー")), (tr("--seconds <秒>"), tr("待つ時間（既定 10）"))],
        examples: ["vc hotkey-check", "vc hotkey-check --trigger ctrl+opt+space"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let seconds = arguments.option("--seconds").flatMap(Double.init) ?? 10
        let trigger = arguments.option("--trigger")
        do {
            let (spec, source): (HotKeySpec, String)
            if let trigger {
                switch HotKeySpec.parse(trigger) {
                case let .success(parsed): (spec, source) = (parsed, "--trigger")
                case let .failure(f): fail("--trigger \(trigger): \(f.reason)")
                }
            } else {
                (spec, source) = context.resolveHotKey()
            }
            let hotkey = HandsFreeTrigger(try makeTrigger(spec))
            hotkey.onHandsFree = {
                print(Style.yellow(tr("◆ 手放し（ダブルタップ）：もう一度タップで終わり"))); fflush(stdout)
                HUD.shared.show(tr("手放しの録音（テスト）　もう一度タップで終わり（\(spec.displayName)）"), mode: .recording)
            }
            hotkey.onPress = {
                print(Style.green("▼ pressed")); fflush(stdout)
                HUD.shared.show(tr("録音中（テスト）　離すと終わり（\(spec.displayName)）"), mode: .recording)
            }
            hotkey.onRelease = {
                print(Style.dim("▲ released")); fflush(stdout)
                HUD.shared.show(tr("離しました"), mode: .info, hideAfter: 1)
            }
            print(tr("\(holdInstruction(spec))て、離す") + Style.dim(tr("（\(spec.description)・\(source)・\(Int(seconds)) 秒間。マイクは使いません）")))
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { _ = hotkey; exit(0) }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } catch { fail(tr("ホットキーを登録できません: \(error)")) }
    }
}
