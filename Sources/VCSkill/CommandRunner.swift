import Foundation
import VCCore

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
}

public enum CommandRunner {
    /// 1 つのコマンドの、実行時間の上限（秒）の既定。スキルは、フロントマター `timeout` で変えられる（`Skill.commandTimeout`）。
    public static let defaultTimeout: TimeInterval = 30

    /// コマンドを、シェルなしで実行する（`/usr/bin/env` で PATH を探す）。標準出力と標準エラーを、まとめて返す。
    /// `cancel` が取りやめられたら、実行中のコマンドを止める（終了コード 130）。
    public static func run(argv: [String], timeout: TimeInterval = CommandRunner.defaultTimeout, cancel: CancelToken? = nil, environment: [String: String] = [:]) -> CommandResult {
        // 空の argv は、`CommandPolicy.check` が先に拒否する。env に空の引数を渡すと、環境変数を出力してしまうので、ここでも起動しない
        guard let executable = argv.first else { return CommandResult(exitCode: 127, output: "コマンドが空", timedOut: false) }
        let result = ProcessRunner.run(executable: executable, arguments: Array(argv.dropFirst()), mergeStderr: true, timeout: timeout, cancel: cancel, environment: environment)
        if let error = result.launchError { return CommandResult(exitCode: result.exitCode, output: "起動できない: \(error.localizedDescription)", timedOut: false) }
        return CommandResult(exitCode: result.exitCode, output: result.cancelled ? "取りやめ" : result.text, timedOut: result.timedOut)
    }
}
