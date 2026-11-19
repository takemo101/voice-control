import AppKit
import Foundation
import VCCore
import VCSpeech

/// 音声入力の、発話ごとの処理（認識した文字を、前面のアプリへ入力する）。`VoiceSession` が使う。
enum DictationFlow {
    /// 文字を入れてから、設定のキー（既定は Enter）を送るまでの間（秒）。この間に、Esc で取りやめられる。
    static let enterDelay: TimeInterval = 0.8

    /// `seconds` 秒、待つ。取りやめられたら、すぐやめて false（細かく、取りやめを見る）。
    static func waitUnlessCancelled(_ seconds: TimeInterval, _ token: CancelToken) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if token.isCancelled || token.isSuperseded { return false }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return !(token.isCancelled || token.isSuperseded)
    }

    /// 認識した文字を、前面のアプリへ入力する（音声入力 と、声の入力 の音声入力のトリガー）。`--dry-run` なら、入力せずに、パネルに出すだけ。
    @MainActor static func handle(_ utterance: String, _ token: CancelToken, context: CommandContext, chip: String, paste: ClipboardPaste) async {
        guard !utterance.isEmpty else {
            notice(tr("聞き取れなかった"))
            HUD.shared.show(HUDContent(phase: .failure, title: tr("聞き取れませんでした"), hint: tr("もう一度、はっきり話してください"), chip: chip), hideAfter: 2.5)
            return
        }
        if token.isCancelled { return }
        // つなぎ言葉を消す（設定が on のとき。設定は、入力のたびに読む：つなぎ言葉の辞書 が、すぐ効く）
        let settings = context.currentSettings()
        var utterance = utterance
        if FillerWords.isEnabled(setting: settings.removeFillers) {
            utterance = FillerWords.remove(from: utterance, fillers: FillerWords.list(setting: settings.fillers))
            if utterance.isEmpty {
                notice(tr("つなぎ言葉だけでした（入力しません）"))
                HUD.shared.show(HUDContent(phase: .info, title: tr("つなぎ言葉だけでした"), hint: tr("入力しません"), chip: chip), hideAfter: 2)
                return
            }
        }
        if context.options.dryRun {
            print("  " + Style.yellow(tr("入力しません（--dry-run）")) + tr("（\(utterance.count) 文字）"))
            HUD.shared.show(HUDContent(phase: .info, title: tr("認識しました（入力しません：--dry-run）"), chip: chip, reply: utterance), hideAfter: 2.5)
            return
        }
        do {
            switch try await paste.insert(utterance) {
            case .inserted:
                print("  " + Style.green("✓") + tr(" 入力しました（\(utterance.count) 文字）"))
                guard settings.dictateEnter ?? false else {
                    HUD.shared.show(HUDContent(phase: .success, title: tr("入力しました"), chip: chip, reply: utterance), hideAfter: 1.8)
                    return
                }
                // 設定：入れたあとに、キー（`dictateKey`。既定は Enter）を送る。書き方が読めなければ、送らない（Enter に、黙って、替えない）
                let stroke: KeyStroke
                switch settings.dictateKeyStroke {
                case let .success(value): stroke = value
                case let .failure(failure):
                    print("  " + Style.yellow(tr("送るキーを読めません: \(failure.reason)")))
                    HUD.shared.show(HUDContent(phase: .failure, title: tr("キーを送れませんでした"), hint: tr("設定のキー「\(settings.dictateKey ?? "")」: \(failure.reason)"), chip: chip, reply: utterance), hideAfter: 5)
                    return
                }
                let name = stroke.displayName
                // **送る前に、短い間**（Esc で、取りやめられる：送信・実行は、取り消しにくい）
                HUD.shared.show(HUDContent(phase: .success, title: tr("入力しました"), hint: tr("\(name) を送ります（Esc で取りやめ）"), chip: chip, reply: utterance), hideAfter: enterDelay + 0.3)
                guard await waitUnlessCancelled(enterDelay, token) else {
                    print("  " + Style.yellow(tr("\(name) は、送りませんでした（取りやめ）")))
                    HUD.shared.show(HUDContent(phase: .info, title: tr("\(name) は、送りませんでした"), hint: tr("文字は、入力済みです"), chip: chip), hideAfter: 2)
                    return
                }
                if paste.press(stroke) {
                    print("  " + Style.green("✓") + tr(" \(name) を送りました"))
                    HUD.shared.show(HUDContent(phase: .success, title: tr("入力して、\(name) を送りました"), chip: chip, reply: utterance), hideAfter: 1.5)
                } else {
                    HUD.shared.show(HUDContent(phase: .failure, title: tr("\(name) を送れませんでした"), hint: tr("アクセシビリティの許可が要ります"), chip: chip, reply: utterance), hideAfter: 4)
                }
            case .notReceived(let kept):
                // 成功に見せない：前面のアプリが、⌘V を受け取らなかった（入力欄でない・セキュア入力・アプリの不調）
                print("  " + Style.yellow(tr("入力できませんでした")) + (kept ? tr("（文字は、クリップボードにあります）") : ""))
                HUD.shared.show(HUDContent(phase: .failure, title: tr("入力できませんでした"),
                                           hint: kept ? tr("文字は、クリップボードに入れました（⌘V で貼り付け）") : tr("前面のアプリが、貼り付けを受け取りませんでした"),
                                           chip: chip, reply: utterance), hideAfter: 6)
            }
        } catch { VoiceUI.showFailure(error, chip: chip) }
    }
}
