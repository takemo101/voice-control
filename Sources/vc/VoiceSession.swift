import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 声の入力の 1 式（トリガー・録音・認識・発話の処理・画面の表示）。**声の入力（端末）と、メニューバーのアプリが、同じものを使う**。
/// 違いは、イベントループを、だれが回すか：端末の 声の入力 は `loop.run`（`NSApplication.run()` まで）、アプリは、アプリ自身のループの上で `loop.begin`。
/// 同期の関数：`await` を挟まない（`VoiceLoop.run` の不変条件 1）。
@MainActor final class VoiceSession {
    let loop: VoiceLoop
    /// 準備ができたときの表示（端末の案内・画面の上の「準備できました」）。
    let onReady: () -> Void
    /// 手放すと、キーを受けなくなるもの（トリガー・画面撮影のショートカット）。
    private let retained: [Any]
    /// 端末に出す、いまの設定の案内（アプリでは、メニューの状態に使う）。
    let hint: String

    /// 画面撮影のショートカット（`stop` で、受け付けを外す）。
    private let screenTriggers: [any PushToTalkTrigger]

    private init(loop: VoiceLoop, retained: [Any], screenTriggers: [any PushToTalkTrigger], hint: String, onReady: @escaping () -> Void) {
        self.loop = loop; self.retained = retained; self.screenTriggers = screenTriggers; self.hint = hint; self.onReady = onReady
    }

    /// 止める：トリガー・Esc・画面撮影のショートカットの受け付けを、いますぐ外す（設定を変えて、作り直すとき）。
    func stop() {
        loop.stop()
        screenTriggers.forEach { $0.invalidate() }
    }

    static func make(context: CommandContext, jev: TinyJev, muter: OutputMuter, speech: SpeechEngine) throws -> VoiceSession {
        let (spec, _) = context.resolveHotKey()
        let chip = spec.displayName
        // 音声入力のトリガーがあれば、トリガーで、声で頼む／音声入力を切り替える（Shift の長押し＝声で頼む、Ctrl の長押し＝音声入力、など）
        let dictateSpec = context.resolveDictateHotKey()?.spec
        let shotSpec = context.resolveShotHotKey()
        let chatSpec = context.resolveChatHotKey()
        let pasteLastSpec = context.resolvePasteLastHotKey(), cycleSpec = context.resolveCycleSendHotKey()
        // キーの重なり：何も変える前に、起動の問題として返す（アプリは、終わらない）
        let actionSpecs: [(name: String, spec: HotKeySpec)] = [pasteLastSpec.map { (KeyKind.pasteLast.title, $0) }, cycleSpec.map { (KeyKind.cycleSend.title, $0) }].compactMap { $0 }
        if let message = KeyConflicts.message(listen: spec, dictate: dictateSpec, shot: shotSpec, chat: chatSpec, actions: actionSpecs) { throw StartupProblem(message, page: .keys) }
        // 会話の設定（エージェント・道具）：会話のキーがなくても、入力欄・メニューから、会話できる
        let chatAgent = context.resolveChatAgent()
        ChatMode.shared.configure(context.chatSetup(agent: chatAgent))
        ChatWindow.shared.setKeyHint(chatSpec?.displayName)
        HUD.shared.warmUp()   // トリガー（グローバルのキー監視）より先に、パネルを 1 回出す（確認のボタンが、クリックを受けられるように）
        var keys: [(tag: String, key: PushToTalkTrigger)] = [(VoiceMode.listen, try makeTrigger(spec))]
        if let dictateSpec { keys.append((VoiceMode.dictate, try makeTrigger(dictateSpec))) }
        if let chatSpec { keys.append((VoiceMode.chat, try makeTrigger(chatSpec))) }
        // 手放し：ダブルタップで、黙るまで録音する（押し続けるのは、従来どおり）。設定 `handsFree`（既定 on。`設定ウィンドウ > キー`）
        let handsFreeOn = context.currentSettings().handsFree ?? true
        let triggers = VoiceTriggers.make(keys, handsFreeEnabled: handsFreeOn)
        let handsFree = triggers.handsFree
        // スクリーンショットのショートカットは、このループの間、保持する（外れると、キーを受けなくなる）
        let screenTriggers = try ScreenFlow.install(shot: shotSpec, followUp: { ScreenFlow.followUpHint(listen: spec, handsFree: handsFreeOn) })
        ChatMode.shared.scorer = jev   // 会話の判断（撮ったスクリーンショットを使うか・最新の情報が要るか）
        let chatConfirmation = Confirmation(scorer: jev)   // 会話の道具の確認（上書き・安全でないコマンド）の、声の「はい」の判定
        // 会話のウィンドウの入力欄：文字で質問する（声の流れと、同じ処理。確認は、パネルのボタンで答える：声の返事は、待たない）
        ChatWindow.shared.startTyped = { text in
            Task { @MainActor in
                let token = CancelToken()
                let box = TypedTask()
                let waitForever: NextUtterance = { try await Task.sleep(for: .seconds(86_400)); return nil }
                // 声の質問が来たら、この質問は、中断する（処理も止める）
                let cancel: () -> Void = { token.supersede(); box.task?.cancel() }
                box.task = Task { @MainActor in
                    await ChatVoice.handle(text, token: token, context: context, chip: tr("入力"), speakResults: false, confirmation: chatConfirmation, next: waitForever, cancelHook: cancel, fromQueue: true)
                }
            }
        }
        let chips = [VoiceMode.listen: chip, VoiceMode.dictate: dictateSpec?.displayName ?? chip, VoiceMode.chat: chatSpec?.displayName ?? chip]
        let paste = ClipboardPaste()
        // 操作のショートカット：直前の入力の貼り直し・送るキーの切り替え（このループの間、保持する）
        let actionTriggers = try DictationActions.install(pasteLast: pasteLastSpec, cycleSend: cycleSpec, paste: paste, settings: { context.currentSettings() })
        let session = RecordingSession()
        session.setLevelHandler { HUD.shared.pushLevel($0); handsFree.pushLevel($0) }   // 録音中の波形・手放しの録音の「黙った」
        LiveCaption.shared.use(language: context.sttLanguage)
        SaySpeaker.shared.use(language: context.sttLanguage)   // 読み上げの声は、認識する言語の声
        LiveCaption.shared.enable(context.currentSettings().liveCaption ?? true)   // 録音中の文字（録音中の文字の表示）
        session.setBufferHandler { LiveCaption.shared.feed($0) }
        let loop = VoiceLoop(
            trigger: triggers.trigger, escape: EscapeKey(), recorder: PopRecorder(session, muter: muter), transcriber: speech.transcriber,
            handler: { [listen = VoiceHandlers.utterance(context, jev: jev, chip: chip)] utterance, token, next, tag in
                if tag == VoiceMode.dictate {
                    await DictationFlow.handle(utterance, token, context: context, chip: chips[tag] ?? chip, paste: paste)
                } else if tag == VoiceMode.chat {
                    await ChatVoice.handle(utterance, token: token, context: context, chip: chips[tag] ?? chip, speakResults: context.currentSettings().speakResults ?? false, confirmation: chatConfirmation, next: next)
                } else {
                    await listen(utterance, token, next, tag)
                }
            },
            onEvent: { event, tag in
                if case .recordingDiscarded = event { MainActor.assumeIsolated { handsFree.observe(event) } }   // Esc：手放しの状態を解く
                VoiceUI.show(event, chip: chips[tag] ?? chip, muter: muter, dictation: tag == VoiceMode.dictate, chat: tag == VoiceMode.chat)
            })
        // 会話の質問が、考えている間に、続けて話したとき：取りやめずに、順番を待たせる（Zed・Codync と同じ。ほかの流れの発話は、従来どおり、取って代わる）
        loop.keepsRunning = { newTag, runningTag in newTag == VoiceMode.chat && runningTag == VoiceMode.chat }
        ChatWindow.shared.interruptVoiceTurn = { loop.interruptRunning() }
        // 続けて話した発話は、その場で先に認識して、順番待ちに入れる。順番が来たら、声の流れへ戻す（確認の返事・読み上げは、いつもどおり）
        loop.onDeferred = { text, _ in
            Task { @MainActor in
                HUD.shared.hide()   // 「認識中…」を、外す（会話は、ウィンドウに出ている）
                guard !text.isEmpty else { return }
                if ChatStopCommand.matches(text) { ChatVoice.stopByVoice(chip: chips[VoiceMode.chat] ?? chip); return }   // 「止めて」は、順番待ちに入れず、止める
                ChatWindow.shared.enqueueSpoken(text)
            }
        }
        ChatWindow.shared.injectSpoken = { text in loop.inject(text, tag: VoiceMode.chat) }   // 止まっていれば、false（ウィンドウが、記録に残す）
        loop.uncertainty = VoiceHandlers.uncertainty(context, jev: jev, chips: chips, fallbackChip: chip)
        handsFree.onHandsFree = { tag in
            HUD.shared.show(HUDContent(phase: .recording, title: tr("録音中"), hint: HandsFreeGroup.hint, chip: chips[tag] ?? chip))
        }
        let onReady: () -> Void = {
            let w = colWidth(ja: 8, en: 12)
            print(Style.bold(holdWhile(spec, .listen)) + Style.dim(tr("（Ctrl+C で終了。録音中・実行中に Esc で取りやめ）")))
            kv(tr("音声認識"), speech.choice.title, width: w)
            kv(tr("実行"), context.engineText ?? "apple", width: w)
            kv(tr("ほかの音"), muter === OutputMuter.disabled ? tr("録音中も流したまま") : tr("録音中は消す"), width: w)
            if let chatSpec { kv(tr("会話"), holdWhile(chatSpec, .chat) + (chatAgent.isExternal ? tr("。エージェント：\(chatAgent.rawValue)（発話が、この Mac の外へ送られる）") : ""), width: w) }
            if let dictateSpec { kv(tr("音声入力"), holdWhile(dictateSpec, .dictate), width: w) }
            if let shotSpec { kv(tr("画面撮影"), tr("\(shotSpec.description) を押して範囲を選び、そのあと声で頼む"), width: w) }
            kv(tr("スキル"), context.options.dryRun ? Style.yellow(tr("実行しない（--dry-run）")) : Style.green(tr("実行する")), width: w)
            fflush(stdout)
            // 準備ができたことを、画面の上に出す（モデルの読み込みの間は、押しても反応しない）。許可がなければ、その旨を出す。
            if spec.isHold && !ModifierHold.isTrusted {
                HUD.shared.show(HUDContent(phase: .failure, title: tr("アクセシビリティの許可がありません"), hint: tr("システム設定 > プライバシーとセキュリティ > アクセシビリティで、このアプリを許可して、開き直してください。許可なしなら、設定ウィンドウ > キー で、ctrl+opt+space のような組み合わせにします"), chip: chip), hideAfter: 15)
            } else {
                HUD.shared.show(HUDContent(phase: .info, title: tr("準備できました"), hint: holdWhile(spec, .listen), chip: chip), hideAfter: 3.5)
            }
        }
        return VoiceSession(loop: loop, retained: [triggers, screenTriggers, actionTriggers], screenTriggers: screenTriggers + actionTriggers, hint: holdWhile(spec, .listen), onReady: onReady)
    }
}

/// 文字で送った質問の `Task`（取りやめの手続きが、あとから参照する）。メインスレッドだけで触る。
@MainActor private final class TypedTask {
    var task: Task<Void, Never>?
}
