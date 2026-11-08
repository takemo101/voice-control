import Foundation

/// 撮ったスクリーンショットの、使える時間の表示（画像のパネル）。画像を使うスキルは、撮ってから `ScreenshotStore.timeToLive` の間だけ、選ばれる（F46）。
enum ImageExpiry {
    /// 残りの秒から、パネルに出す文。**切り上げる**（0.4 秒残っていれば「残り 0:01」：0 になるまで、「残り」と出す）。
    static func text(remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "使える時間が過ぎました · 撮り直してください" }
        let seconds = Int(remaining.rounded(.up))
        return "声で頼むと、この画像を使えます · 残り \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// 残りが、これ（秒）以下になったら、色で知らせる。
    static let warningSeconds: TimeInterval = 30
}
