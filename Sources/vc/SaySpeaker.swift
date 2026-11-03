import Foundation

/// 読み上げ（確認の問いかけ）の、いま鳴っているもの。取りやめたときに止める。
final class SaySpeaker: @unchecked Sendable {
    nonisolated(unsafe) static let shared = SaySpeaker()
    private let lock = NSLock()
    private var process: Process?

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
