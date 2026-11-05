import AppKit
import Foundation

struct HudPreviewCommand: Command {
    static let info = CommandInfo(
        name: "hud-preview", group: .evaluation, summary: "画面の上の表示の見本を出す（マイク・実行なし。見た目の確認用）",
        usage: ["vc hud-preview [--stage recording|working|confirm|success|failure|denied] [--seconds <秒>]"],
        details: ["--stage がなければ、順に、すべて出す。1 つの段階を出す秒数は、既定 3。内容は、作り物の見本。"],
        options: [("--stage <名前>", "この段階だけを出す"), ("--seconds <秒>", "1 段階あたりの秒数（既定 3）")],
        examples: ["vc hud-preview", "vc hud-preview --stage success --seconds 8"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc hud-preview [--stage recording|working|confirm|success|failure|denied] [--seconds <秒>]：画面の上の表示の見本を出す（マイク・言語モデル・コマンドは使わない。見た目の確認用）。
        // --stage がなければ、順に、すべて出す。
        var arguments = arguments
        let seconds = arguments.option("--seconds").flatMap(Double.init) ?? 3
        let only = arguments.option("--stage")
        let chip = context.resolveHotKey().spec.displayName
        func sample(_ stage: String) -> HUDContent? {
            switch stage {
            case "recording": return HUDContent(phase: .recording, title: "録音中", hint: "離すと、認識して実行します", chip: chip)
            case "working":
                var c = HUDContent(phase: .working, title: "実行中", chip: chip, heard: "音量を50にして", skill: "spotify")
                c.steps = [.init(command: "osascript …/spotify.applescript volume 50")]
                return c
            case "confirm": return {
                var c = HUDContent(phase: .confirm, title: "実行しますか？", hint: "確信度が高くないので、確認します。ボタンを押すか、もう一度トリガーを押して「はい」と言う", chip: chip, heard: "ファイルを削除して", skill: "cleanup")
                c.choices = true
                return c
            }()
            case "success":
                var c = HUDContent(phase: .success, title: "完了", chip: chip, heard: "音量を50にして", skill: "spotify")
                c.steps = [.init(command: "osascript …/spotify.applescript volume 50", status: .ok, output: "ok: volume 50")]
                c.reply = "done: 音量を50に設定しました。"
                return c
            case "failure":
                var c = HUDContent(phase: .failure, title: "失敗", chip: chip, heard: "次の曲にして", skill: "spotify")
                c.steps = [.init(command: "osascript …/spotify.applescript next", status: .failed(1), output: "error: Spotify が応答しません")]
                c.reply = "failed: Spotify が応答しません"
                return c
            case "denied":
                var c = HUDContent(phase: .info, title: "実行しませんでした", chip: chip, heard: "ターミナルで ls を実行して", skill: "open-app")
                c.steps = [.init(command: "ls", status: .denied, output: "許可されていないコマンドです（open だけ許可）")]
                return c
            default: return nil
            }
        }
        let stages = ["recording", "working", "confirm", "success", "failure", "denied"]
        if let only { guard sample(only) != nil else { usageError("hud-preview", "知らない --stage: \(only)（\(stages.joined(separator: "・"))）") } }
        for (i, stage) in (only.map { [$0] } ?? stages).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * seconds) {
                HUD.shared.show(sample(stage)!)
                // 確認のボタン：押した答えを、端末へ出す（見た目と、クリックの確認用）
                if stage == "confirm" { HUD.shared.answers.set { print("答え: " + ($0 ? "実行する" : "やめる")); fflush(stdout) } }
            }
        }
        let total = Double(only == nil ? stages.count : 1) * seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { HUD.shared.hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) } }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}
