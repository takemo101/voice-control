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
        Task.detached {
            let outcome = ScreenCapture.captureForVoice()
            await MainActor.run {
                busy = false
                switch outcome {
                case .captured:
                    // 撮った直後に、そのまま録音を始める（黙ったら認識。始められなければ〔別の処理中〕、案内だけ出す：声のトリガーで、3 分以内に頼める）
                    AutoListen.shared.begin(hint: next)
                    if AutoListen.shared.hint == nil {
                        HUD.shared.show(HUDContent(phase: .success, title: "スクリーンショットを撮りました", hint: "\(Int(ScreenshotStore.timeToLive / 60)) 分以内に、声のトリガーで頼んでください", chip: chip), hideAfter: 6)
                    }
                case .cancelled: break
                case let .failed(reason):
                    HUD.shared.show(HUDContent(phase: .failure, title: "撮れませんでした", chip: chip, reply: reason), hideAfter: 8)
                }
            }
        }
    }

    /// 撮って、文字だけを書き出し、ウィンドウに出す。
    static func transcribe(chip: String) {
        guard !busy else { return }
        busy = true
        Task.detached {
            let result = ScreenCapture.recognizeRegion()
            await MainActor.run {
                busy = false
                switch result {
                case .success(nil): break   // 取りやめ
                case let .success(text?) where text.isEmpty:
                    HUD.shared.show(HUDContent(phase: .info, title: "文字が見つかりませんでした", chip: chip), hideAfter: 3)
                case let .success(text?):
                    if let why = DocumentWindow.present(markdown: TranscriptDocument.markdown(text), title: "文字起こし") {
                        HUD.shared.show(HUDContent(phase: .failure, title: "ウィンドウを出せませんでした", chip: chip, reply: why), hideAfter: 6)
                    } else {
                        HUD.shared.show(HUDContent(phase: .success, title: "文字を書き出しました（\(text.count) 文字）", hint: "ウィンドウに出しました（閉じるまで残ります）", chip: chip), hideAfter: 3.5)
                    }
                case let .failure(failure):
                    HUD.shared.show(HUDContent(phase: .failure, title: "読み取れませんでした", chip: chip, reply: failure.message), hideAfter: 8)
                }
            }
        }
    }
}
