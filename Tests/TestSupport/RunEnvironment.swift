import Foundation

/// テストを動かしている環境（CI かどうか）。GitHub Actions は、環境変数 `CI` を付ける。
public enum RunEnvironment {
    public static var isCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    /// CI の macOS の VM には、GPU・Neural Engine がない：**Vision の文字認識**と、**HEIC の書き出し**は、戻らない（37 分、全部のテストが、止まった）。
    /// これらを使うテストは、手元（実機）だけで動かす。
    public static let platformMediaReason = "CI の VM では、Vision・HEIC が動かない（GPU・Neural Engine がない）"
}
