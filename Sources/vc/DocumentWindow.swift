import Foundation

/// Markdown の結果を、ウィンドウで見せる（呼び出し元は、待たない）。**別のプロセス**（`vc show --wait`）を起こして、標準入力で本文を渡す：
/// `vc run`（画面のループがない）でも、`vc listen`（パネルと同じプロセス）でも、同じに使え、ウィンドウは、呼び出し元が終わっても、閉じるまで残る。
/// `Process` を直接使う 2 か所目（`SaySpeaker` と同じ理由：終わるまで待たない。`ProcessRunner` は、終わるまで待つ）。
enum DocumentWindow {
    /// 本文の大きさの上限（外から来る文章なので、異常に大きいものは、出さない）。
    static let maxBytes = 1_000_000

    /// 起こせなければ、理由を返す（見せ方は、呼び出し側）。
    static func present(markdown: String, title: String? = nil) -> String? {
        guard markdown.utf8.count <= maxBytes else { return "本文が大きすぎます（\(maxBytes / 1000) KB まで）" }
        guard let executable = Bundle.main.executableURL else { return "vc の場所が分かりません" }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["show", "--wait"] + (title.map { ["--title", $0] } ?? [])
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "ウィンドウを出せません（\(error.localizedDescription)）" }
        input.fileHandleForWriting.write(Data(markdown.utf8))
        // try?: 子が先に終わっていれば、閉じる失敗は、結果に関係しない
        try? input.fileHandleForWriting.close()
        return nil
    }
}
