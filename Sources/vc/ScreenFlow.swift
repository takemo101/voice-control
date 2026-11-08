import Foundation
import VCCore
import VCSkill

/// ショートカットから始まる、スクリーンショットの流れ（`vc listen --hotkey` の中）。範囲の選択は、別のスレッドで待つ（画面の上のパネル・キーの監視を、止めない）。
/// 結果は、画面の上のパネルに出す。画像・読み取った文字は、端末へは出さない。
@MainActor enum ScreenFlow {
    /// 範囲を選んでいる間は、次のショートカットを受けない。
    private static var busy = false

    /// 撮る（声で指示する相手）。`next`：撮ったあとの案内（どのキーで話すか）。
    static func captureForVoice(next: String, chip: String) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let outcome = await ScreenCapture.captureForVoice()
            do {
                busy = false
                switch outcome {
                case .captured:
                    // 撮ったあと：パネルに画像を出し、**声のトリガーを押して頼む**ことを促す（録音は、自動では始めない）
                    showPreview()
                    HUD.shared.show(HUDContent(phase: .success, title: "撮りました。続けて、声で頼んでください", hint: next, chip: chip), hideAfter: 9)
                case .cancelled: break
                case let .failed(reason):
                    HUD.shared.show(HUDContent(phase: .failure, title: "撮れませんでした", chip: chip, reply: reason), hideAfter: 8)
                }
            }
        }
    }

    /// 撮った画像を、パネルに出す（画像のコピー・パスのコピー）。画像は、パネルのプロセスへ渡す（ファイルには、残さない）。
    static func showPreview() {
        guard let data = try? Data(contentsOf: ScreenshotStore.currentFile) else { return }   // try?: 読めなければ、パネルを出さないだけ（声の流れは、続く）
        if let why = ImagePanel.present(png: data, title: "スクリーンショット") { eprint("パネルを出せません: \(why)") }
    }
}
