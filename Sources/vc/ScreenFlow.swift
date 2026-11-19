import Foundation
import VCCore
import VCSkill
import VCSpeech

/// ショートカットから始まる、スクリーンショットの流れ（声の入力 の中）。範囲の選択は、別のスレッドで待つ（画面の上のパネル・キーの監視を、止めない）。
/// 結果は、画面の上のパネルに出す。画像・読み取った文字は、端末へは出さない。
@MainActor enum ScreenFlow {
    /// 撮ったあとの案内（どのキーで、頼むか）。
    static func followUpHint(listen spec: HotKeySpec, handsFree: Bool) -> String {
        holdWhile(spec, .screenshot) + (handsFree ? tr("。ダブルタップなら、話し終わるまで聞きます") : "")
    }

    /// スクリーンショットのショートカットを、登録する（`shot` がなければ、何も登録しない）。返したトリガーは、聞いている間、保持する。前の実行の画像は、消す（使わない）。
    static func install(shot: HotKeySpec?, followUp: @escaping @MainActor () -> String) throws -> [any PushToTalkTrigger] {
        ScreenshotStore.clear()
        guard let shot else { return [] }
        let key = try makeTrigger(shot)
        key.onPress = { Task { @MainActor in captureForVoice(next: followUp(), chip: shot.displayName) } }
        return [key]
    }

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
                    HUD.shared.show(HUDContent(phase: .success, title: tr("撮りました。続けて、声で頼んでください"), hint: next, chip: chip), hideAfter: 9)
                case .cancelled: break
                case let .failed(reason):
                    HUD.shared.show(HUDContent(phase: .failure, title: tr("撮れませんでした"), chip: chip, reply: reason), hideAfter: 8)
                }
            }
        }
    }

    /// 撮った画像を、パネルに出す（画像のコピー・パスのコピー）。画像は、パネルのプロセスへ渡す（ファイルには、残さない）。
    static func showPreview() {
        guard let data = try? Data(contentsOf: ScreenshotStore.currentFile) else { return }   // try?: 読めなければ、パネルを出さないだけ（声の流れは、続く）
        let expiresAt = (try? FileManager.default.attributesOfItem(atPath: ScreenshotStore.currentFile.path)[.modificationDate] as? Date).flatMap { $0 }.map { $0.addingTimeInterval(ScreenshotStore.timeToLive) }   // try?: 取れなければ、残り時間を出さないだけ
        if let why = ImagePanel.present(png: data, title: tr("スクリーンショット"), expiresAt: expiresAt) { eprint(tr("パネルを出せません: \(why)")) }
    }
}
