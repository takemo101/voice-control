import AVFoundation
import Foundation
import VCCore
import VCSpeech

/// `vc capture-probe`：システム音声の取り込みと認識を、**自作の音**（`say`）で試す（開発・診断。SPEC F80。文字起こしは、画面に出すだけ：何も残さない）。
struct CaptureProbeCommand: Command {
    static let info = CommandInfo(
        name: "capture-probe", group: .evaluation, summary: "システム音声の取り込みと認識を、自作の音（say）で試す（開発用。文字は、画面に出すだけ）",
        usage: ["vc capture-probe [--say <文>] [--seconds <秒>] [--locale ja-JP]"],
        details: ["Mac から出ている音を取り込み、認識して、確定した文を出す。--say を付けると、その文を、`say` で鳴らす（自分の音で試す）。画面収録の許可が、まだなら、OS の確認が出る。"],
        options: [("--say <文>", "鳴らす文（既定：なし。ほかの音を、取り込む）"), ("--seconds <秒>", "取り込む長さ（既定 12）"), ("--locale <言語>", "認識の言語（既定 ja-JP）")],
        examples: ["vc capture-probe --say \"今日はいい天気ですね。明日の会議は4時からです\""])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let spoken = arguments.option("--say")
        let seconds = arguments.option("--seconds").flatMap(Double.init) ?? 12
        let locale = Locale(identifier: arguments.option("--locale") ?? "ja-JP")
        print("  画面収録の許可：\(SystemAudioCapture.isPermitted ? "あり" : "まだ（OS の確認が出ます）")")

        let transcriber = SegmentTranscriber(locale: locale) { update in
            print("  \(update.isFinal ? Style.green("確定") : Style.dim("途中")) \(update.text)")
        }
        do { try await transcriber.start() } catch { fail("\(error)") }
        let capture = SystemAudioCapture()
        let audio: AsyncStream<AVAudioPCMBuffer>
        do { audio = try await capture.start(target: .allApps) } catch { fail("\(error)") }
        print("  取り込み中（録音中に、ほかの音を消さない旗）：\(SystemAudioActivity.isActive ? "on" : "off")")

        var peak: Float = 0
        var buffers = 0
        let reader = Task {
            for await buffer in audio {
                buffers += 1
                if let samples = buffer.floatChannelData?[0] { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) } }
                transcriber.feed(buffer)
            }
        }
        if let spoken {
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Kyoko", spoken]
            try? say.run()   // try?: 鳴らせなくても、取り込みの確認は、続ける
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await capture.stop()
        print("  停止後の旗：\(SystemAudioActivity.isActive ? "on" : "off")")
        await reader.value
        await transcriber.finish()
        print("  取り込んだ音の塊：\(buffers)・最大の音量：\(String(format: "%.3f", peak))")
    }
}
