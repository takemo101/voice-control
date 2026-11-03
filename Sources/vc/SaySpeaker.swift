import Foundation

/// 読み上げ（確認の問いかけ）の、いま鳴っているもの。取りやめたときに止める。
/// `@unchecked Sendable` の理由：可変な状態（`process`）は、すべて `lock` で守る。`Process` が Sendable でないため。
/// `shared` は、Sendable な型の定数なので、`nonisolated(unsafe)` は要らない。
final class SaySpeaker: @unchecked Sendable {
    static let shared = SaySpeaker()
    private let lock = NSLock()
    private var process: Process?

    /// `ProcessRunner` には載せない：鳴り終わるまで待たずに戻り、`Process` を持っておいて、取りやめで `terminate` する（`ProcessRunner` は、終わるまで呼び出したスレッドを止める）。
    func say(_ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Kyoko", text]
        // try?: 読み上げは補助（確認の問いかけは、画面の上の表示にも出る）。起動に失敗しても、確認の流れは続く
        try? p.run()
        lock.lock(); process = p; lock.unlock()
    }

    func stop() {
        lock.lock(); let p = process; process = nil; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

/// 読み上げる（確認の問いかけ）。終わるまで待たない。取りやめたときは、止める（`SaySpeaker`）。
func say(_ text: String) { SaySpeaker.shared.say(text) }
