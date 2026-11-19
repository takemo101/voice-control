import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 声の流れ（声の入力 の会話のトリガー）で、1 回の発話を、会話として処理する：上のパネルに、考えている様子と、答えを出す。
@MainActor enum ChatVoice {
    /// 会話の道具が、**確認が要る操作**（既存ファイルの上書き・安全でないコマンド）の前に、利用者に聞く：パネルのボタンか、声の「はい」。答えがなければ（取りやめ・エラー）、しない。
    private static func askToConfirm(_ detail: String, chip: String, confirmation: Confirmation, next: @escaping NextUtterance) async -> Bool {
        // 確認の文は、1 行目＝何をするか（読み上げ・見出し）・2 行目以降＝抜粋（長いコマンド：`ACPCommandSummary`）。**文字を、パネルいっぱいに、並べない**
        let parts = detail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let headline = parts.first ?? detail
        let excerpt = parts.count > 1 ? parts[1] : nil
        say(tr("確認です。\(headline)"))
        var content = HUDContent(phase: .confirm, title: tr("実行しますか？"), hint: tr("\(headline)。\(ConfirmGuide.howToAnswer)"), chip: chip)
        content.reply = excerpt
        content.choices = true
        HUD.shared.show(content)
        notice("会話の道具の確認：\(headline)" + (excerpt.map { "（\($0)）" } ?? "") + "。パネルの\(ConfirmGuide.howToAnswer)")   // l10n-skip: log
        let yes = (try? await VoiceHandlers.askByPanelOrVoice(confirmation: confirmation, next: next)) ?? false
        if yes { HUD.shared.hide() } else { HUD.shared.show(HUDContent(phase: .info, title: tr("やめました"), chip: chip), hideAfter: 2) }   // 会話は、ウィンドウに出ている
        return yes
    }

    /// 外のエージェントへ**画像を送る前の確認**：画像（サムネイル）と送り先を、パネルに出して、ボタンか声の「はい」で答える。送るたびに、聞く。
    private static func askToSendImage(_ file: URL, agent: ChatAgent, chip: String, confirmation: Confirmation, next: @escaping NextUtterance) async -> Bool {
        say(tr("画像を、\(agent.rawValue) へ送ります。よいですか"))
        var content = HUDContent(phase: .confirm, title: tr("この画像を、\(agent.rawValue) へ送りますか？"), hint: tr("画面の内容が、この Mac の外（\(agent.label)）へ出ます。\(ConfirmGuide.howToAnswer)"), chip: chip)
        content.image = HUDImage.load(file, sendsOut: true)
        content.choices = true
        HUD.shared.show(content)
        notice("画像を \(agent.rawValue) へ送る確認：パネルの\(ConfirmGuide.howToAnswer)")   // l10n-skip: log
        let yes = (try? await VoiceHandlers.askByPanelOrVoice(confirmation: confirmation, next: next)) ?? false
        if yes { HUD.shared.hide() } else { HUD.shared.show(HUDContent(phase: .info, title: tr("画像は、送りません"), chip: chip), hideAfter: 2) }
        return yes
    }

    static func handle(_ utterance: String, token: CancelToken, context: CommandContext, chip: String, speakResults: Bool, confirmation: Confirmation, next: @escaping NextUtterance, cancelHook: (() -> Void)? = nil) async {
        guard !utterance.isEmpty else {
            notice("聞き取れなかった")   // l10n-skip: log
            HUD.shared.show(HUDContent(phase: .failure, title: tr("聞き取れませんでした"), hint: tr("もう一度、はっきり話してください"), chip: chip), hideAfter: 2.5)
            return
        }
        if ChatEndCommand.matches(utterance) {
            await ChatMode.shared.end()
            print("  " + Style.dim(tr("会話を終わりました（記録は、消しました）")))
            HUD.shared.show(HUDContent(phase: .info, title: tr("会話を終わりました"), hint: tr("記録は、消しました"), chip: chip, heard: utterance), hideAfter: 2.5)
            if speakResults { say(tr("会話を終わりました")) }
            return
        }
        let fallbackNote = await ChatMode.shared.settleAgent()   // 選んだエージェントが、なくなっていたら、Apple で答える
        let agent = ChatMode.shared.agent
        let window = ChatWindow.shared
        let level = ChatMode.shared.tools
        let toolLabel: String? = level == .none ? nil : (level == .all ? (ChatMode.shared.auto ? tr("すべて・自動") : tr("すべて")) : (level == .read ? tr("＋読む") : "Web"))   // l10n-skip: "Web" is the same in both languages
        let id = window.begin(question: utterance, agent: agent.isExternal ? agent.label : tr("Apple のモデル（この Mac の中）"),
                              warning: agent.isExternal ? tr("この Mac の外へ送信") : (level == .none ? nil : tr("検索語を外へ送信")), tools: toolLabel, cancel: cancelHook)
        // **会話は、会話のウィンドウで見せる**（エージェントや答えの長さで、出たり出なかったりしない）。出ていなければ、前へ出す（キーは奪わない）。上のパネル（HUD）は、聞いている・確認・失敗のときだけ
        window.show(activate: false)
        HUD.shared.hide()
        do {
            let confirm: ToolConfirm = { detail in
                await askToConfirm(detail, chip: chip, confirmation: confirmation, next: next)
            }
            let confirmImage: ChatMode.ImageSendConfirm = { file, sendTo in
                await askToSendImage(file, agent: sendTo, chip: chip, confirmation: confirmation, next: next)
            }
            let outcome = try await ChatMode.shared.ask(utterance, engine: context.engine, token: token, attachedImage: window.attachedImageFile, onImage: { window.attachImage(id, file: $0) }, onRoute: { window.setImageRoute(id, $0) }, progress: { text in
                window.setStatus(id, text)
            }, confirm: confirm, confirmImage: confirmImage)
            if token.isCancelled || token.isSuperseded { window.stop(id, reason: token.isSuperseded ? tr("新しい質問を優先しました") : tr("取りやめました（Esc）")); return }
            for note in outcome.notes { print("  " + Style.dim(note)) }
            for activity in outcome.activities { print("  " + Style.dim("▸ " + activity.text)) }
            print("  " + Style.bold(tr("回答")) + "  " + (outcome.answer.count > 90 ? String(outcome.answer.prefix(90)) + "…" : outcome.answer).replacingOccurrences(of: "\n", with: " "))
            window.finish(id, answer: outcome.answer, activities: outcome.activities, notes: outcome.notes + (fallbackNote.map { [$0] } ?? []), startedNew: outcome.startedNew, imageRoute: outcome.imageRoute)
            let spoken = speakResults ? SpokenText.chunks(from: outcome.answer) : []
            if !spoken.isEmpty { window.speakLatest(spoken) }   // 全文を読む（止めるには、Esc・ウィンドウのボタン・メニュー・トリガー）
        } catch {
            // 中断・失敗した質問も、ウィンドウに残す（理由つき。会話の記録には、入らない）
            if token.isSuperseded { window.stop(id, reason: tr("新しい質問を優先しました")); return }
            if token.isCancelled || error is CancellationError {
                window.stop(id, reason: tr("取りやめました（Esc）"))
                VoiceUI.showCancelled(chip: chip)
            } else {
                window.fail(id, message: "\(error)")
                VoiceUI.showFailure(error, chip: chip)
            }
        }
    }
}
