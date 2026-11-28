import AppKit
import Foundation
import VCCore
import VCSkill
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
        // 整理モード（設定が on のとき。F79）：言語モデルで整える。**通らない・遅い・失敗は、元の文字**（整理のために、入力は、止まらない）
        if settings.tidy ?? false {
            HUD.shared.show(HUDContent(phase: .working, title: tr("整理しています…"), chip: chip))
            let result = await Tidier(engine: context.engine, instructionsSetting: settings.tidyInstructions).tidy(utterance)
            if token.isCancelled { return }
            if case let .kept(_, reason?) = result {
                notice("\(reason)")
                HUD.shared.show(HUDContent(phase: .info, title: "\(reason)", chip: chip), hideAfter: 1.6)
            }
            utterance = result.text
        }
        if context.options.dryRun {
            print("  " + Style.yellow(tr("入力しません（--dry-run）")) + tr("（\(utterance.count) 文字）"))
            HUD.shared.show(HUDContent(phase: .info, title: tr("認識しました（入力しません：--dry-run）"), chip: chip, reply: utterance), hideAfter: 2.5)
            return
        }
        DictationActions.record(utterance, settings: settings)   // 直近の入力（メモリ）と、履歴（設定がオンのときだけ）
        // 英語の文字を、単語のすぐあとに入れるときは、空白を 1 つ足す（日本語には、働かない。読めなければ、足さない）
        let typed = (settings.smartSpacing ?? true) ? SmartSpacing.adjusted(utterance, before: CaretContext.characterBeforeCaret()) : utterance
        do {
            switch try await paste.insert(typed) {
            case .inserted:
                print("  " + Style.green("✓") + tr(" 入力しました（\(utterance.count) 文字）"))
                // 入れたあとに送るキー：いまの候補（設定 `dictateMode`。古い設定は `dictateEnter`）。「送らない」なら、ここまで
                let mode = settings.dictateSend.current
                if let problem = mode.problem {
                    print("  " + Style.yellow(tr("送るキーを読めません: \(problem)")))
                    HUD.shared.show(HUDContent(phase: .failure, title: tr("キーを送れませんでした"), hint: tr("設定の送るキーを読めません: \(problem)"), chip: chip, reply: utterance), hideAfter: 5)   // 読めないキーを、Enter に、黙って、替えない
                    return
                }
                guard let stroke = mode.stroke else {
                    HUD.shared.show(HUDContent(phase: .success, title: tr("入力しました"), chip: chip, reply: utterance), hideAfter: 1.8)
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
