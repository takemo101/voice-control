import Foundation

/// 端末への出力の整形。色は、標準出力が端末のときだけ（`NO_COLOR` があれば、使わない。`TERM=dumb` も使わない）。
enum Style {
    private static func enabled(fd: Int32) -> Bool {
        let env = ProcessInfo.processInfo.environment
        return isatty(fd) != 0 && env["NO_COLOR"] == nil && env["TERM"] != "dumb"
    }
    static let stdoutColor = enabled(fd: 1)
    static let stderrColor = enabled(fd: 2)

    private static func wrap(_ s: String, _ code: String, _ on: Bool) -> String { on ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { wrap(s, "1", stdoutColor) }
    static func dim(_ s: String) -> String { wrap(s, "2", stdoutColor) }
    static func red(_ s: String) -> String { wrap(s, "31", stdoutColor) }
    static func green(_ s: String) -> String { wrap(s, "32", stdoutColor) }
    static func yellow(_ s: String) -> String { wrap(s, "33", stdoutColor) }
    static func cyan(_ s: String) -> String { wrap(s, "1;36", stdoutColor) }
    static func errRed(_ s: String) -> String { wrap(s, "1;31", stderrColor) }
}

/// 端末での表示の幅（全角・かなは 2）。表の列をそろえるために使う。
func displayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { sum, u in
        let v = u.value
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
        return sum + (wide ? 2 : 1)
    }
}

/// 表示の幅が `width` になるまで、右に空白を足す。
func pad(_ s: String, to width: Int) -> String { s + String(repeating: " ", count: max(0, width - displayWidth(s))) }

/// 見出し：`▶ 実行`。
func heading(_ title: String) { print("\n" + Style.cyan("▶ " + title)) }

/// 項目：`  ラベル   値`（ラベルは薄く、幅をそろえる）。
func kv(_ label: String, _ value: String, width: Int = 8) { print("  " + Style.dim(pad(label, to: width)) + "  " + value) }

/// 注意の 1 行。
func notice(_ text: String) { print("  " + Style.yellow("! " + text)) }

func pct(_ p: Double) -> String { String(format: "%5.1f%%", p * 100) }

func seconds(_ since: Date) -> String { String(format: "%.1f 秒", Date().timeIntervalSince(since)) }

/// 標準エラーへ（エラー・進行の通知）。
func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// エラーを出して終了（終了コード 1）。
func fail(_ message: String) -> Never {
    eprint(Style.errRed("エラー:") + " " + message)
    exit(1)
}

/// 使い方の誤り（終了コード 2）。そのコマンドの `--help` を案内する。
func usageError(_ command: String, _ message: String) -> Never {
    eprint(Style.errRed("使い方が違います:") + " " + message)
    eprint("詳しくは: vc \(command) --help")
    exit(2)
}
