import Foundation
import VCCore
import VCSkill

struct ShotCommand: Command {
    static let info = CommandInfo(
        name: "shot", group: .skills, summary: "範囲を選んでスクリーンショットを撮り、声で指示する（画像は、この Mac の中だけ）",
        usage: ["vc shot", "vc shot --clear"],
        details: [
            "画面を暗くして、ドラッグで範囲を選ぶ（Esc で取りやめ）。撮った画像は、**いまのスクリーンショット**になる（~/.voice-control/shot。自分だけが読める。\(Int(ScreenshotStore.timeToLive)) 秒たつと、使えなくなる）。",
            "そのあと、声で頼む（vc listen --hotkey の、声で頼むキーを押して話す）：「この画像の文字を書き出して」「これは何？」「右半分を切り抜いて」「横を 800 にして」「JPEG にして」。",
            "ショートカットで撮るなら、vc hotkey set-shot <キー>（vc listen --hotkey の中で動く）。",
            "画面収録の許可が要る（システム設定 > プライバシーとセキュリティ > 画面収録。vc を動かしているターミナルに）。画像は、この Mac の中のモデル（Apple のモデル・Ollama）だけに渡す。",
            "--clear：いまのスクリーンショットを消す。",
        ],
        options: [("--clear", "いまのスクリーンショットを消す")],
        examples: ["vc shot", "vc shot --clear"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        if arguments.flag("--clear") {
            ScreenshotStore.clear()
            print(Style.green("✓") + " いまのスクリーンショットを消しました")
            return
        }
        print(Style.dim("範囲をドラッグで選ぶ・ウィンドウをクリック・↩ で全画面（Esc で取りやめ）"))
        switch ScreenSelector.runStandalone({ await ScreenCapture.captureForVoice() }) {
        case let .captured(width, height):
            ScreenFlow.showPreview()
            print(Style.green("✓") + " 撮りました（\(width)×\(height)）。\(Int(ScreenshotStore.timeToLive / 60)) 分以内に、声で指示してください（vc listen --hotkey）")
        case .cancelled: print(Style.dim("取りやめました"))
        case let .failed(reason): fail(reason)
        }
    }
}
