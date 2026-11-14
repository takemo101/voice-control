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
        let name = agent.isExternal ? "会話（\(agent.rawValue)・外へ送信）" : "会話"
        var content = HUDContent(phase: .working, title: "考えています…", chip: chip, heard: utterance, skill: name)
        HUD.shared.show(content)
        do {
            let outcome = try await ChatMode.shared.ask(utterance, engine: context.engine, token: token) { text in
                content.title = text
                HUD.shared.show(content)
            }
            if token.isCancelled || token.isSuperseded { return }
            for note in outcome.notes { print("  " + Style.dim(note)) }
            print("  " + Style.bold("回答") + "  " + (outcome.answer.count > 90 ? String(outcome.answer.prefix(90)) + "…" : outcome.answer).replacingOccurrences(of: "\n", with: " "))
            if ChatMode.isShort(outcome.answer) {
                var done = HUDContent(phase: .success, title: "会話", chip: chip, heard: utterance, skill: name)
                done.reply = outcome.answer
                if !outcome.notes.isEmpty { done.hint = outcome.notes.joined(separator: "・") }
                HUD.shared.show(done, hideAfter: HUDSession.readingTime(for: outcome.answer))
            } else {
                if let why = DocumentWindow.present(markdown: "> 会話：\(utterance)\n\n" + outcome.answer) { eprint("ウィンドウを出せません: \(why)") }
                var done = HUDContent(phase: .success, title: "会話", chip: chip, heard: utterance, skill: name)
                done.reply = "回答を、ウィンドウに出しました"
                if !outcome.notes.isEmpty { done.hint = outcome.notes.joined(separator: "・") }
                HUD.shared.show(done, hideAfter: 4)
            }
            if speakResults { say(ChatVoice.spoken(outcome.answer)) }
        } catch {
            if token.isSuperseded { return }
            if token.isCancelled || error is CancellationError { VoiceUI.showCancelled(chip: chip) } else { VoiceUI.showFailure(error, chip: chip) }
        }
    }

    /// 読み上げる文：長い答えは、先頭の数文だけ（ウィンドウに全文がある）。
    static func spoken(_ answer: String) -> String {
        let sentences = answer.split(whereSeparator: { "。\n".contains($0) }).map(String.init)
        var out = ""
        for sentence in sentences { if out.count + sentence.count > 160 { break }; out += sentence + "。" }
        return out.isEmpty ? String(answer.prefix(160)) : out
    }
}
