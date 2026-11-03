import Foundation

/// 外部コマンドの実行結果（`ProcessRunner.run`）。
public struct ProcessResult: Sendable {
    /// 終了コード。シグナルで終わったときは、その番号（`Process.terminationStatus` のまま。タイムアウトの `terminate` なら 15）。
    /// 起動できなかったときは 127、取りやめられたときは 130（どちらもシェルの慣例の番号）。
    public let exitCode: Int32
    /// 標準出力（`mergeStderr` なら、標準エラーも混ぜる）。タイムアウトの `terminate` のあとも出力が終わらなかったときは、空。
    public let output: Data
    /// `timeout` の間に、出力が終わらなかった（コマンドを `terminate` した）。
    public let timedOut: Bool
    /// 実行中または実行の前に、`CancelToken` が取りやめられた。
    public let cancelled: Bool
    /// `/usr/bin/env` を起動できなかった原因（このとき `exitCode` は 127・`output` は空）。
    /// コマンドが見つからないときは、env が起動して 127 で終わるので、ここには入らない。
    public let launchError: (any Error)?

    /// `output` を UTF-8 で読む（不正なバイトは置き換える）。
    public var text: String { String(decoding: output, as: UTF8.self) }
}

/// 外部コマンドを、シェルなしで、同期的に実行する。パイプの読み方・時間の上限・取りやめでの停止・起動失敗の扱い（coding-guidelines「外部コマンドの実行」）は、ここだけが持つ。
/// 呼び出したスレッドは、コマンドが終わるまで止まる。
public enum ProcessRunner {
    private static let launcher = URL(fileURLWithPath: "/usr/bin/env")
    private static let launchFailureExitCode: Int32 = 127
    private static let cancelledExitCode: Int32 = 130
    /// タイムアウトで止めたあと、出力が終わるのを待つ秒数。孫プロセスがパイプを握り続けても、ここで切り上げる。
    private static let drainGrace: TimeInterval = 2

    /// `executable` を、`/usr/bin/env` 経由で（PATH から探して）実行する。
    /// - `mergeStderr`: `true` なら標準エラーを標準出力へまとめる。`false` なら捨てる。
    /// - `timeout`: 出力が終わるまでの秒数の上限。超えたら `terminate`（SIGTERM）する。`nil` なら、上限なし。
    ///   上限が測るのは、出力が終わるまで。出力を閉じたあとの、終了待ちには、上限がない。
    /// - `cancel`: 取りやめられたら、実行中のコマンドを `terminate` する。すでに取りやめられていれば、起動しない。
    /// - `inheritStandardInput`: `true` なら、標準入力を、この呼び出しのプロセスから引き継ぐ。既定は、空（/dev/null）。
    public static func run(
        executable: String,
        arguments: [String] = [],
        mergeStderr: Bool,
        timeout: TimeInterval?,
        cancel: CancelToken? = nil,
        inheritStandardInput: Bool = false
    ) -> ProcessResult {
        if cancel?.isCancelled == true {
            return ProcessResult(exitCode: cancelledExitCode, output: Data(), timedOut: false, cancelled: true, launchError: nil)
        }
        let p = Process()
        p.executableURL = launcher
        p.arguments = [executable] + arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        if !inheritStandardInput { p.standardInput = FileHandle.nullDevice }
        do { try p.run() } catch {
            return ProcessResult(exitCode: launchFailureExitCode, output: Data(), timedOut: false, cancelled: false, launchError: error)
        }
        cancel?.onCancel { if p.isRunning { p.terminate() } }

        // 出力は、終了を待つ前に、別のスレッドで読み切る（パイプが詰まって、コマンドが止まるのを防ぐ）。
        let collected = CollectedOutput()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.set(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        var timedOut = false
        if let timeout {
            if group.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                p.terminate()
                _ = group.wait(timeout: .now() + drainGrace)
            }
        } else {
            group.wait()
        }
        p.waitUntilExit()
        let wasCancelled = cancel?.isCancelled == true
        return ProcessResult(exitCode: wasCancelled ? cancelledExitCode : p.terminationStatus, output: collected.value, timedOut: timedOut, cancelled: wasCancelled, launchError: nil)
    }
}

/// 読み取りのスレッドが書き、呼び出し側が読む。読み切れないまま（タイムアウト）読んでも、競合しないよう、ロックで守る。
private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newValue: Data) { lock.lock(); data = newValue; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
