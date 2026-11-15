import Foundation
import VCCore
import VCSkill

/// 声の流れ（声の入力 の会話のトリガー）で、1 回の発話を、会話として処理する：上のパネルに、考えている様子と、答えを出す。
@MainActor enum ChatVoice {
    static func handle(_ utterance: String, token: CancelToken, context: CommandContext, chip: String, speakResults: Bool) async {
        guard !utterance.isEmpty else {
            notice("聞き取れなかった")
            HUD.shared.show(HUDContent(phase: .failure, title: "聞き取れませんでした", hint: "もう一度、はっきり話してください", chip: chip), hideAfter: 2.5)
            return
        }
        if ChatMode.isEndCommand(utterance) {
            await ChatMode.shared.end()
            print("  " + Style.dim("会話を終わりました（記録は、消しました）"))
            HUD.shared.show(HUDContent(phase: .info, title: "会話を終わりました", hint: "記録は、消しました", chip: chip, heard: utterance), hideAfter: 2.5)
            if speakResults { say("会話を終わりました") }
            return
        }
        let agent = ChatMode.shared.agent
        let toolNote = ChatMode.shared.tools == .none ? "" : "・" + (ChatMode.shared.tools == .all ? "全ツール" : ChatMode.shared.tools.rawValue)
        let name = agent.isExternal ? "会話（\(agent.rawValue)・外へ送信\(toolNote)）" : (ChatMode.shared.tools == .none ? "会話" : "会話（検索語を外へ送信）")
        let window = ChatWindow.shared
        window.begin(question: utterance, agent: agent.isExternal ? "\(agent.label) — この Mac の外へ送信" + (ChatMode.shared.tools == .none ? "" : "・" + ChatMode.shared.tools.title) : (ChatMode.shared.tools == .none ? agent.label : agent.label + " — 道具：" + ChatMode.shared.tools.title + "（検索語を外へ送信）"))
        var content = HUDContent(phase: .working, title: "考えています…", chip: chip, heard: utterance, skill: name)
        HUD.shared.show(content)
        do {
            let outcome = try await ChatMode.shared.ask(utterance, engine: context.engine, token: token) { text in
                content.title = text
                HUD.shared.show(content)
                window.setStatus(text)
            }
            if token.isCancelled || token.isSuperseded { window.discardPending(); return }
            for note in outcome.notes { print("  " + Style.dim(note)) }
            for activity in outcome.activities { print("  " + Style.dim("▸ " + activity)) }
            print("  " + Style.bold("回答") + "  " + (outcome.answer.count > 90 ? String(outcome.answer.prefix(90)) + "…" : outcome.answer).replacingOccurrences(of: "\n", with: " "))
            // 会話のウィンドウ（1 つだけ）に、答えを足す。短い答えで、操作もなければ、上のパネルだけ（ウィンドウが出ていれば、そこに足す）
            let wasVisible = window.isVisible
            window.finish(answer: outcome.answer, activities: outcome.activities, notes: outcome.notes, startedNew: outcome.startedNew)
            let spoken = speakResults ? SpokenText.chunks(from: outcome.answer) : []
            var done = HUDContent(phase: .success, title: "会話", chip: chip, heard: utterance, skill: name)
            if !outcome.notes.isEmpty { done.hint = outcome.notes.joined(separator: "・") }
            if ChatMode.isShort(outcome.answer) && outcome.activities.isEmpty && !wasVisible {
                done.reply = outcome.answer
                if !spoken.isEmpty { done.hint = (done.hint.map { $0 + "・" } ?? "") + "読み上げ中（Esc で止める）" }
                HUD.shared.show(done, hideAfter: HUDSession.readingTime(for: outcome.answer))
            } else if wasVisible {
                window.show(activate: false)
                HUD.shared.hide()
            } else {
                window.show(activate: true)
                done.reply = "回答を、会話のウィンドウに出しました"
                if !spoken.isEmpty { done.hint = (done.hint.map { $0 + "・" } ?? "") + "読み上げ中（Esc で止める）" }
                HUD.shared.show(done, hideAfter: 4)
            }
            if !spoken.isEmpty { SaySpeaker.shared.say(chunks: spoken) }   // 全文を読む（止めるには、Esc・ウィンドウのボタン・メニュー・トリガー）
        } catch {
            window.discardPending()
            if token.isSuperseded { return }
            if token.isCancelled || error is CancellationError { VoiceUI.showCancelled(chip: chip) } else { VoiceUI.showFailure(error, chip: chip) }
        }
    }
}
