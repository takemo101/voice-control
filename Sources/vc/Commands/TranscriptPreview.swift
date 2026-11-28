import AppKit
import Foundation
import VCCore

/// `vc transcript-preview`：文字起こしのウィンドウを、**自作の音**（`say`）で、動かして見せる（見た目・動作の確認用。開発用。履歴は、設定どおり：テストでは、一時の `VC_HOME` を使う）。
struct TranscriptPreviewCommand: Command {
    static let info = CommandInfo(
        name: "transcript-preview", group: .evaluation, summary: "文字起こしのウィンドウを、自作の音（say）で動かして見せる（見た目・動作の確認用）",
        usage: ["vc transcript-preview [--say <文>] [--seconds <秒>]"],
        details: ["本物の文字起こしのウィンドウを出し、すぐ開始して、--say の文を鳴らす（自分の音で試す）。--seconds のあと、止めて、終わる。画面収録の許可が、まだなら、OS の確認が出る。"],
        options: [("--say <文>", "鳴らす文"), ("--seconds <秒>", "動かす長さ（既定 20）")],
        examples: ["vc transcript-preview --say \"今日はいい天気ですね。明日の会議は午後4時からです。\""])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let spoken = arguments.option("--say")
        let seconds = arguments.option("--seconds").flatMap(Double.init) ?? 20
        let settings = context.currentSettings()
        let engine = TranscriptWindow.engine(for: settings)
        NSApplication.shared.setActivationPolicy(.accessory)
        TranscriptWindow.shared.show()
        // 画面のループの中で動かす（ここは、ループを回す前：ここで、`await` する仕事は、ループが回るまで、進まない）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                _ = Task { @MainActor in
                    await TranscriptWindow.shared.session.start(settings: settings, engine: engine)
                    if let spoken {
                        let say = Process()
                        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                        say.arguments = ["-v", "Kyoko", spoken]
                        try? say.run()   // try?: 鳴らせなくても、確認は、続ける
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                _ = Task { @MainActor in
                    await TranscriptWindow.shared.session.stop()
                    exit(0)
                }
            }
        }
        NSApplication.shared.run()
    }
}
