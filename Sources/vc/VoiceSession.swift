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
        let chatAgent = context.resolveChatAgent()
        // 会話の設定（エージェント・道具）：会話のキーがなくても、入力欄・メニューから、会話できる
        ChatMode.shared.configure(context.chatSetup(agent: chatAgent))
        ChatWindow.shared.setKeyHint(chatSpec?.displayName)
        if let message = KeyConflicts.message(listen: spec, dictate: dictateSpec, shot: shotSpec, chat: chatSpec) { fail(message) }
        HUD.shared.warmUp()   // トリガー（グローバルのキー監視）より先に、パネルを 1 回出す（確認のボタンが、クリックを受けられるように）
        var keys: [(tag: String, key: PushToTalkTrigger)] = [(VoiceMode.listen, try makeTrigger(spec))]
        if let dictateSpec { keys.append((VoiceMode.dictate, try makeTrigger(dictateSpec))) }
        if let chatSpec { keys.append((VoiceMode.chat, try makeTrigger(chatSpec))) }
        // 手放し：ダブルタップで、黙るまで録音する（押し続けるのは、従来どおり）。設定 `handsFree`（既定 on。`設定ウィンドウ > キー`）
        let handsFreeOn = context.currentSettings().handsFree ?? true
        let triggers = VoiceTriggers.make(keys, handsFreeEnabled: handsFreeOn)
        let handsFree = triggers.handsFree
        // スクリーンショットのショートカットは、このループの間、保持する（外れると、キーを受けなくなる）
        let screenTriggers = try ScreenFlow.install(shot: shotSpec, followUp: ScreenFlow.followUpHint(listen: spec, handsFree: handsFreeOn))
        ChatMode.shared.scorer = jev   // 会話の判断（撮ったスクリーンショットを使うか・最新の情報が要るか）
        let chatConfirmation = Confirmation(scorer: jev)   // 会話の道具の確認（上書き・安全でないコマンド）の、声の「はい」の判定
        // 会話のウィンドウの入力欄：文字で質問する（声の流れと、同じ処理。確認は、パネルのボタンで答える：声の返事は、待たない）
        ChatWindow.shared.submit = { text in
            Task { @MainActor in
                guard !ChatWindow.shared.hasPending else { return }
                let token = CancelToken()
                let box = TypedTask()
                let waitForever: NextUtterance = { try await Task.sleep(for: .seconds(86_400)); return nil }
                // 声の質問が来たら、この質問は、中断する（処理も止める）
                let cancel: () -> Void = { token.supersede(); box.task?.cancel() }
                box.task = Task { @MainActor in
                    await ChatVoice.handle(text, token: token, context: context, chip: "入力", speakResults: false, confirmation: chatConfirmation, next: waitForever, cancelHook: cancel)
                }
            }
        }
        let chips = [VoiceMode.listen: chip, VoiceMode.dictate: dictateSpec?.displayName ?? chip, VoiceMode.chat: chatSpec?.displayName ?? chip]
        let paste = ClipboardPaste()
        let session = RecordingSession()
        session.setLevelHandler { HUD.shared.pushLevel($0); handsFree.pushLevel($0) }   // 録音中の波形・手放しの録音の「黙った」
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
        loop.uncertainty = VoiceHandlers.uncertainty(context, jev: jev, chips: chips, fallbackChip: chip)
        handsFree.onHandsFree = { tag in
            HUD.shared.show(HUDContent(phase: .recording, title: "録音中", hint: HandsFreeGroup.hint, chip: chips[tag] ?? chip))
        }
        let onReady: () -> Void = {
            print(Style.bold("\(holdInstruction(spec))ている間だけ聞きます") + Style.dim("（Ctrl+C で終了。録音中・実行中に Esc で取りやめ）"))
            kv("音声認識", speech.choice.title, width: 8)
            kv("実行", context.engineText ?? "apple", width: 8)
            kv("ほかの音", muter === OutputMuter.disabled ? "録音中も流したまま" : "録音中は消す", width: 8)
            if let chatSpec { kv("会話", "\(holdInstruction(chatSpec))ている間だけ（スキルを選ばず、会話として質問。古いやり取りは、要約して続ける）" + (chatAgent.isExternal ? "。エージェント：\(chatAgent.rawValue)（発話が、この Mac の外へ送られる）" : ""), width: 8) }
            if let dictateSpec { kv("音声入力", "\(holdInstruction(dictateSpec))ている間だけ（前面のアプリへ入力）", width: 8) }
            if let shotSpec { kv("画面撮影", "\(shotSpec.description) を押して範囲を選び、そのあと声で頼む") }
            kv("スキル", context.options.dryRun ? Style.yellow("実行しない（--dry-run）") : Style.green("実行する"), width: 8)
            fflush(stdout)
            // 準備ができたことを、画面の上に出す（モデルの読み込みの間は、押しても反応しない）。許可がなければ、その旨を出す。
            if spec.isHold && !ModifierHold.isTrusted {
                HUD.shared.show(HUDContent(phase: .failure, title: "アクセシビリティの許可がありません", hint: "システム設定 > プライバシーとセキュリティ > アクセシビリティで、このアプリを許可して、開き直してください。許可なしなら、設定ウィンドウ > キー で、ctrl+opt+space のような組み合わせにします", chip: chip), hideAfter: 15)
            } else {
                HUD.shared.show(HUDContent(phase: .info, title: "準備できました", hint: "\(holdInstruction(spec))ている間だけ聞きます", chip: chip), hideAfter: 3.5)
            }
        }
        return VoiceSession(loop: loop, retained: [triggers, screenTriggers], screenTriggers: screenTriggers, hint: "\(holdInstruction(spec))ている間だけ聞きます", onReady: onReady)
    }
}

/// 文字で送った質問の `Task`（取りやめの手続きが、あとから参照する）。メインスレッドだけで触る。
@MainActor private final class TypedTask {
    var task: Task<Void, Never>?
}
