import Foundation
import VCCore

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
}

public enum CommandRunner {
    /// コマンドを、シェルなしで実行する（`/usr/bin/env` で PATH を探す）。標準出力と標準エラーを、まとめて返す。
    /// `cancel` が取りやめられたら、実行中のコマンドを止める（終了コード 130）。
    public static func run(argv: [String], timeout: TimeInterval = 30, cancel: CancelToken? = nil) -> CommandResult {
        if cancel?.isCancelled == true { return CommandResult(exitCode: 130, output: "取りやめ", timedOut: false) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return CommandResult(exitCode: 127, output: "起動できない: \(error.localizedDescription)", timedOut: false) }
        cancel?.onCancel { if p.isRunning { p.terminate() } }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = group.wait(timeout: .now() + 2)
        }
        p.waitUntilExit()
        let wasCancelled = cancel?.isCancelled == true
        return CommandResult(exitCode: wasCancelled ? 130 : p.terminationStatus, output: wasCancelled ? "取りやめ" : String(decoding: data, as: UTF8.self), timedOut: timedOut)
    }
}
