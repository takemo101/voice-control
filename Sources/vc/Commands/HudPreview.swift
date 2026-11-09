import AppKit
import Foundation

struct HudPreviewCommand: Command {
    static let info = CommandInfo(
        name: "hud-preview", group: .evaluation, summary: "画面の上の表示の見本を出す（マイク・実行なし。見た目の確認用）",
        usage: ["vc hud-preview [--stage recording|working|confirm|image|image-confirm|success|failure|denied] [--image <ファイル>] [--seconds <秒>]"],
        details: ["--stage がなければ、順に、すべて出す。1 つの段階を出す秒数は、既定 3。内容は、作り物の見本。"],
        options: [("--stage <名前>", "この段階だけを出す（recording・thinking・working・confirm・image・image-confirm・success・failure・denied・long）"), ("--image <ファイル>", "image 段階に出す画像（なければ、作り物の絵）"), ("--seconds <秒>", "1 段階あたりの秒数（既定 3）")],
        examples: ["vc hud-preview", "vc hud-preview --stage success --seconds 8"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc hud-preview [--stage recording|working|confirm|success|failure|denied] [--seconds <秒>]：画面の上の表示の見本を出す（マイク・言語モデル・コマンドは使わない。見た目の確認用）。
        // --stage がなければ、順に、すべて出す。
        var arguments = arguments
        let seconds = arguments.option("--seconds").flatMap(Double.init) ?? 3
        let only = arguments.option("--stage")
        let chip = context.resolveHotKey().spec.displayName
        // 画像の見本：--image <ファイル>（自分で用意した画像）。なければ、作り物の絵
        let imageFile = arguments.option("--image").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        func sampleImage(sendsOut: Bool) -> HUDImage? {
            if let imageFile { return HUDImage.load(imageFile, sendsOut: sendsOut) }
            let size = NSSize(width: 480, height: 300)
            let drawn = NSImage(size: size, flipped: false) { rect in
                NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.86, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1)])?.draw(in: rect, angle: 35)
                return true
            }
            return HUDImage(thumbnail: drawn, pixelSize: CGSize(width: 1520, height: 950), sendsOut: sendsOut)
        }
        func sample(_ stage: String) -> HUDContent? {
            switch stage {
            case "recording": return HUDContent(phase: .recording, title: "録音中", hint: "離すと、認識して実行します（Esc で取りやめ）", chip: chip)
            case "thinking": return HUDContent(phase: .working, title: "認識中…", hint: "Esc で取りやめ", chip: chip)
            case "working":
                var c = HUDContent(phase: .working, title: "実行中", chip: chip, heard: "音量を50にして", skill: "spotify")
                c.steps = [.init(command: "osascript …/spotify.applescript volume 50")]
                return c
            case "confirm": return {
                var c = HUDContent(phase: .confirm, title: "実行しますか？", hint: "確信度が高くないので、確認します。" + ConfirmGuide.howToAnswer, chip: chip, heard: "ファイルを削除して", skill: "cleanup")
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
            case "long":
                // 長い実行（コマンドが多い）：本文が上限を超えると、スクロールになる
                var c = HUDContent(phase: .working, title: "実行中", chip: chip, heard: "ファイルを整理して", skill: "default")
                c.steps = (1...14).map { .init(command: "ls -la /Applications/Example\($0).app", status: .ok, output: "total \($0 * 8)") }
                c.reply = "done: 14 件のコマンドを実行して、すべて終わりました。長い返事は、5 行まで出して、それより長ければ、切ります。長い返事は、5 行まで出して、それより長ければ、切ります。"
                return c
            case "image":
                // 画像のスキル（Mac の中だけ）：どの画像が使われるかを、サムネイルで見せる
                var c = HUDContent(phase: .working, title: "実行中", chip: chip, heard: "この画像の文字を書き出して", skill: "image-ask")
                c.image = sampleImage(sendsOut: false)
                c.steps = [.init(command: "vc see")]
                return c
            case "image-confirm":
                // 画像を外へ送るスキルの確認：送る画像を、大きく見せる
                var c = HUDContent(phase: .confirm, title: "実行しますか？", hint: "撮った画面の画像と質問を、OpenAI（codex） へ送ります。実行の前に確認します。" + ConfirmGuide.howToAnswer, chip: chip, heard: "コーデックスにこの画面を見せて、何のエラーか聞いて", skill: "ask-agent-image")
                c.image = sampleImage(sendsOut: true)
                c.choices = true
                return c
            case "denied":
                var c = HUDContent(phase: .info, title: "実行しませんでした", chip: chip, heard: "ターミナルで ls を実行して", skill: "open-app")
                c.steps = [.init(command: "ls", status: .denied, output: "許可されていないコマンドです（open だけ許可）")]
                return c
            default: return nil
            }
        }
        let stages = ["recording", "thinking", "working", "confirm", "image", "image-confirm", "success", "failure", "denied", "long"]
        if let only { guard sample(only) != nil else { usageError("hud-preview", "知らない --stage: \(only)（\(stages.joined(separator: "・"))）") } }
        for (i, stage) in (only.map { [$0] } ?? stages).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * seconds) {
                HUD.shared.show(sample(stage)!)
                // 確認のボタン：押した答えを、端末へ出す（見た目と、クリックの確認用）
                if stage == "confirm" { HUD.shared.answers.set { print("答え: " + ($0 ? "実行する" : "やめる")); fflush(stdout) } }
            }
        }
        // 録音中の波形の見本：話しているような音量（うねりと、間）を流す
        let levelStart = Date()
        let levelTimer = Timer(timeInterval: 1.0 / 40, repeats: true) { _ in
            let t = Date().timeIntervalSince(levelStart)
            let burst = max(0, sin(t * 1.7)) * (0.55 + 0.45 * sin(t * 0.63))
            let syllable = 0.5 + 0.5 * sin(t * 13.0 + sin(t * 3.1) * 2)
            HUD.shared.pushLevel(Float(min(1, burst * syllable * 1.1)))
        }
        RunLoop.main.add(levelTimer, forMode: .common)
        let total = Double(only == nil ? stages.count : 1) * seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { HUD.shared.hide(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) } }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}
