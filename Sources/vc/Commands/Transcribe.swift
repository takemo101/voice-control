import Foundation
import VCSpeech

struct TranscribeCommand: Command {
    static let info = CommandInfo(
        name: "transcribe", group: .evaluation, summary: "音声ファイルを文字にする（音声認識の確認用）",
        usage: ["vc transcribe <音声ファイル> [--stt <apple|ID>]"],
        details: [
            "選んだ音声認識（--stt → vc stt set → 既定の Apple）で、音声ファイルを文字にして、画面に出す。認識の前に、声のない録音は、捨てる（空になる）。",
            "文字は、画面だけに出す（ファイル・ログに残さない）。音声は、この Mac の外へ出さない。",
        ],
        options: [],
        examples: ["vc transcribe sample.wav", "vc transcribe sample.wav --stt whisper-large-v3-turbo"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        guard let path = arguments.positionals.first else { usageError("transcribe", "音声ファイルを渡してください（例: vc transcribe sample.wav）") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { fail("ファイルがありません: \(path)") }
        let engine = context.makeSpeechEngine()
        defer { engine.close() }
        let t0 = Date()
        do {
            let text = try await engine.transcriber.transcribe(file: url)
            eprint(Style.dim(String(format: "%@・%.2f 秒", engine.choice.id, Date().timeIntervalSince(t0))))
            print(text.isEmpty ? Style.dim("（声が聞こえませんでした）") : text)
        } catch { fail("\(error)") }
    }
}
