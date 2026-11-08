import Foundation
import VCCore
import VCSkill

/// **画像を外へ送るスキルの確認のとき、送る画像を、パネルで見せる**（F47）。文の「撮った画面の画像を、… へ送ります」だけでは、何を送るのかが、分からない（古い画面・取り違えた依頼）。
/// 確認に答えたら（承認・断り）、閉じる。画像は、スクリプトが、実行のとき読む、いまのスクリーンショット（`ScreenshotStore`）。
enum ConfirmImagePanel {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shown = false

    /// 見せる（対象のスキルだけ。画像がなければ、何もしない：スクリプトが、撮り直しを案内する）。
    static func show(for skill: Skill) {
        guard skill.sendsScreenshot, case let .success(url) = ScreenshotStore.current(), let data = try? Data(contentsOf: url) else { return }   // try?: 読めなければ、パネルを出さないだけ（確認の文は、出る）
        if let why = ImagePanel.present(png: data, title: "送る画像（確認してください）") { eprint("パネルを出せません: \(why)"); return }
        lock.lock(); shown = true; lock.unlock()
    }

    /// 見せていたら、閉じる。
    static func dismiss() {
        lock.lock(); let wasShown = shown; shown = false; lock.unlock()
        if wasShown { ImagePanel.dismiss() }
    }
}
