import Foundation

/// 画面に残る別ウィンドウを、**別のプロセス**で起こす（`vc show --wait`・`vc preview --wait`）。標準入力で本文（Markdown・PNG）を渡して、**待たない**：
/// `vc run`（画面のループがない）でも、`vc listen`（パネルと同じプロセス）でも、同じに使え、ウィンドウは、呼び出し元が終わっても、閉じるまで残る。
/// `Process` を直接使う場所（`ProcessRunner` は、終わるまで待つので使えない）。ほかは `SaySpeaker`（読み上げ）。
enum DetachedChild {
    struct Failure: Error { let reason: String }

    static func launch(arguments: [String], input: Data) -> Result<Process, Failure> {
        guard let executable = Bundle.main.executableURL else { return .failure(Failure(reason: "vc の場所が分かりません")) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(Failure(reason: "ウィンドウを出せません（\(error.localizedDescription)）")) }
        pipe.fileHandleForWriting.write(input)
        // try?: 子が先に終わっていれば、閉じる失敗は、結果に関係しない
        try? pipe.fileHandleForWriting.close()
        return .success(process)
    }
}
