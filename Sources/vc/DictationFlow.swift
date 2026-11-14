import AppKit
import Foundation
import VCCore
import VCSpeech

/// 音声入力の、発話ごとの処理（認識した文字を、前面のアプリへ入力する）。`VoiceSession` が使う。
enum DictationFlow {
    /// 認識した文字を、前面のアプリへ入力する（音声入力 と、声の入力 の音声入力のトリガー）。`--dry-run` なら、入力せずに、パネルに出すだけ。
    @MainActor static func handle(_ utterance: String, _ token: CancelToken, context: CommandContext, chip: String, paste: ClipboardPaste) async {
        guard !utterance.isEmpty else {
            notice("聞き取れなかった")
            HUD.shared.show(HUDContent(phase: .failure, title: "聞き取れませんでした", hint: "もう一度、はっきり話してください", chip: chip), hideAfter: 2.5)
            return
        }
        if token.isCancelled { return }
        // つなぎ言葉を消す（設定が on のとき。設定は、入力のたびに読む：つなぎ言葉の辞書 が、すぐ効く）
        let settings = context.currentSettings()
        var utterance = utterance
        if FillerWords.isEnabled(setting: settings.removeFillers) {
            utterance = FillerWords.remove(from: utterance, fillers: FillerWords.list(setting: settings.fillers))
            if utterance.isEmpty {
                notice("つなぎ言葉だけでした（入力しません）")
                HUD.shared.show(HUDContent(phase: .info, title: "つなぎ言葉だけでした", hint: "入力しません", chip: chip), hideAfter: 2)
                return
            }
        }
        if context.options.dryRun {
            print("  " + Style.yellow("入力しません（--dry-run）") + "（\(utterance.count) 文字）")
            HUD.shared.show(HUDContent(phase: .info, title: "認識しました（入力しません：--dry-run）", chip: chip, reply: utterance), hideAfter: 2.5)
            return
        }
        do {
            switch try await paste.insert(utterance) {
            case .inserted:
                print("  " + Style.green("✓") + " 入力しました（\(utterance.count) 文字）")
                HUD.shared.show(HUDContent(phase: .success, title: "入力しました", chip: chip, reply: utterance), hideAfter: 1.8)
            case .notReceived(let kept):
                // 成功に見せない：前面のアプリが、⌘V を受け取らなかった（入力欄でない・セキュア入力・アプリの不調）
                print("  " + Style.yellow("入力できませんでした") + (kept ? "（文字は、クリップボードにあります）" : ""))
                HUD.shared.show(HUDContent(phase: .failure, title: "入力できませんでした",
                                           hint: kept ? "文字は、クリップボードに入れました（⌘V で貼り付け）" : "前面のアプリが、貼り付けを受け取りませんでした",
                                           chip: chip, reply: utterance), hideAfter: 6)
            }
        } catch { VoiceUI.showFailure(error, chip: chip) }
    }
}
