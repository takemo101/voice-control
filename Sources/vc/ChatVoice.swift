import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 答えが**少しずつ届く**間の、表示と読み上げ：届いた文字を、考えている間に見せ（`ChatWindow.appendPartial`）、読み上げが on なら、**文の区切りごと**に、読み始める（`SpokenStream`。最初の文が届いたら、すぐ。答えが全部そろうのを、待たない）。
/// - 取りやめた・順番を奪われた・**利用者が、話し始めた**ら、このあとは、読まない（マイクが、読み上げの声を拾わない）。
/// - 少しずつ届かないとき（Apple のモデル・従来の接続）は、従来どおり、答えが決まってから、全文を読む。
@MainActor final class AnswerStream {
    private let window: ChatWindow
    private let id: UUID
    private let speak: Bool
    private let token: CancelToken
    private var stream = SpokenStream()
    private var received = false
    private var muted = false
    private var started = false

    init(window: ChatWindow, id: UUID, speak: Bool, token: CancelToken) { self.window = window; self.id = id; self.speak = speak; self.token = token }

    func push(_ delta: String) {
        received = true
        window.appendPartial(id, delta)
        guard speak, !muted else { return }
        if token.isCancelled || token.isSuperseded || window.isUserSpeaking { muted = true; return }
        say(stream.push(delta))
    }

    /// 答えが決まった：残りを読む（少しずつ届かなかったときは、全文を）。
    func finish(answer: String) {
        guard speak else { return }
        guard received else {
            let chunks = SpokenText.chunks(from: answer)
            if !chunks.isEmpty { window.speakLatest(chunks) }   // 全文を読む（止めるには、Esc・ウィンドウのボタン・メニュー・トリガー）
            return
        }
        guard !muted, !window.isUserSpeaking else { return }
        say(stream.finish())
    }

    private func say(_ chunks: [String]) {
        guard !chunks.isEmpty else { return }
        if !started {
            started = true
            SaySpeaker.shared.stop()   // 前の答えを読んでいたら、止める（続きを、重ねない）
            window.markSpeaking(id)
        }
        SaySpeaker.shared.say(chunks: chunks, channel: .conversation)
    }
}

/// 別のスレッドから届く文字を、**届いた順に**、メインアクターへ渡す（`Task` を、1 つずつ作ると、順番が、保証されない）。
/// `@unchecked Sendable` の理由：可変な状態（`pending`・`scheduled`）は、すべて `lock` で守る。
final class OrderedMainForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var scheduled = false
    private let handler: @MainActor (String) -> Void

    init(_ handler: @escaping @MainActor (String) -> Void) { self.handler = handler }

    func add(_ text: String) {
        let needsDrain = lock.withLock { () -> Bool in
            pending.append(text)
            defer { scheduled = true }
            return !scheduled
        }
        if needsDrain { Task { @MainActor in self.drain() } }
    }

    /// たまっている分を、いま、渡す（答えが決まる前に呼ぶ：あとから、遅れて届かないように）。
    @MainActor func drain() {
        let batch = lock.withLock { () -> String in
            let joined = pending.joined()
            pending = []; scheduled = false
            return joined
        }
        if !batch.isEmpty { handler(batch) }
    }
}

/// 声の流れ（声の入力 の会話のトリガー）で、1 回の発話を、会話として処理する：上のパネルに、考えている様子と、答えを出す。
@MainActor enum ChatVoice {
    /// 会話の道具が、**確認が要る操作**（既存ファイルの上書き・安全でないコマンド）の前に、利用者に聞く：パネルのボタンか、声の「はい」。答えがなければ（取りやめ・エラー）、しない。
    private static func askToConfirm(_ detail: String, chip: String, confirmation: Confirmation, next: @escaping NextUtterance) async -> Bool {
        // 確認の文は、1 行目＝何をするか（読み上げ・見出し）・2 行目以降＝抜粋（長いコマンド：`ACPCommandSummary`）。**文字を、パネルいっぱいに、並べない**
        let parts = detail.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let headline = parts.first ?? detail
        let excerpt = parts.count > 1 ? parts[1] : nil
        SaySpeaker.shared.stop()   // 少しずつ読んでいる途中の説明を止めて、確認を、すぐ、読む
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

    /// **声の「止めて」**（ストップワード）：読み上げと、考えている質問を止め、順番待ちを捨てる。質問としては、送らない。止めるものがなければ、そう知らせる。
    static func stopByVoice(chip: String) {
        SaySpeaker.shared.stop()
        let stopped = ChatWindow.shared.stopAll()
        HUD.shared.show(HUDContent(phase: .info, title: stopped ? tr("止めました") : tr("止めるものが、ありません"), chip: chip), hideAfter: 1.8)
    }

    static func handle(_ utterance: String, token: CancelToken, context: CommandContext, chip: String, speakResults: Bool, confirmation: Confirmation, next: @escaping NextUtterance, cancelHook: (() -> Void)? = nil, fromQueue: Bool = false) async {
        guard !utterance.isEmpty else {
            notice("聞き取れなかった")   // l10n-skip: log
            HUD.shared.show(HUDContent(phase: .failure, title: tr("聞き取れませんでした"), hint: tr("もう一度、はっきり話してください"), chip: chip), hideAfter: 2.5)
            return
        }
        let window = ChatWindow.shared
        // ストップワード：質問にせず、止める（順番待ちにも、入れない）。順番待ちから戻った発話は、すでに、質問として決まっている
        if !fromQueue, ChatStopCommand.matches(utterance) { stopByVoice(chip: chip); return }
        if ChatEndCommand.matches(utterance) {
            window.dropInjection(utterance)   // 順番待ちから戻った発話なら、始める予約を外す（質問にならずに終わる）
            await ChatMode.shared.end()
            print("  " + Style.dim(tr("会話を終わりました（記録は、消しました）")))
            HUD.shared.show(HUDContent(phase: .info, title: tr("会話を終わりました"), hint: tr("記録は、消しました"), chip: chip, heard: utterance), hideAfter: 2.5)
            if speakResults { say(tr("会話を終わりました")) }
            return
        }
        // 考えている最中なら、順番待ちに入れて、すぐ戻る（Zed・Codync と同じ：考えている間の質問は、キューに入る。**待たない**：声の流れを、塞がない）。文字の質問は、ウィンドウが、順番に始める（`fromQueue`）
        if !fromQueue, !window.claimTurn(utterance) {
            HUD.shared.hide()   // 「認識中…」を、外す（待っている質問は、会話のウィンドウに出ている）
            return
        }
        let fallbackNote = await ChatMode.shared.settleAgent()   // 選んだエージェントが、なくなっていたら、Apple で答える
        if token.isCancelled || token.isSuperseded { window.releaseStart(); return }   // 始める前に、取りやめられた
        let agent = ChatMode.shared.agent
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
            let answerStream = AnswerStream(window: window, id: id, speak: speakResults, token: token)
            let forwarder = OrderedMainForwarder { answerStream.push($0) }
            let outcome = try await ChatMode.shared.ask(utterance, engine: context.engine, token: token, attachedImage: window.attachedImageFile, onImage: { window.attachImage(id, file: $0) }, onRoute: { window.setImageRoute(id, $0) }, progress: { text in
                window.setStatus(id, text)
            }, onText: { forwarder.add($0) }, confirm: confirm, confirmImage: confirmImage)
            forwarder.drain()   // 届いた分は、答えを決める前に、すべて渡す
            if token.isCancelled || token.isSuperseded { window.stop(id, reason: token.isSuperseded ? tr("新しい質問を優先しました") : tr("取りやめました（Esc）"), dropsQueue: !token.isSuperseded); return }
            for note in outcome.notes { print("  " + Style.dim(note)) }
            for activity in outcome.activities { print("  " + Style.dim("▸ " + activity.text)) }
            print("  " + Style.bold(tr("回答")) + "  " + (outcome.answer.count > 90 ? String(outcome.answer.prefix(90)) + "…" : outcome.answer).replacingOccurrences(of: "\n", with: " "))
            window.finish(id, answer: outcome.answer, activities: outcome.activities, notes: outcome.notes + (fallbackNote.map { [$0] } ?? []), startedNew: outcome.startedNew, imageRoute: outcome.imageRoute)
            answerStream.finish(answer: outcome.answer)   // 残りを読む（少しずつ届かなかったときは、全文）
        } catch {
            // 中断・失敗した質問も、ウィンドウに残す（理由つき。会話の記録には、入らない）
            if token.isSuperseded { window.stop(id, reason: tr("新しい質問を優先しました")); return }
            if token.isCancelled || error is CancellationError {
                window.stop(id, reason: tr("取りやめました（Esc）"), dropsQueue: true)
                VoiceUI.showCancelled(chip: chip)
            } else {
                window.fail(id, message: "\(error)")
                VoiceUI.showFailure(error, chip: chip)
            }
        }
    }
}
