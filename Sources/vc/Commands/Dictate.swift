import AppKit
import Foundation
import VCCore
import VCSpeech

struct DictateCommand: Command {
    static let info = CommandInfo(
        name: "dictate", group: .skills, summary: "音声入力だけ：押している間だけ録音し、文字にして、前面のアプリへ入力する",
        usage: ["vc dictate [--trigger <キー>] [--stt <apple|ID>] [--mute|--no-mute] [--dry-run]"],
        details: [
            "押している間だけ録音（既定：Shift の長押し。vc hotkey で変更）→ 離すと文字にして、**いま前面のアプリへ入力**する（クリップボードに書いて ⌘V を送り、貼り付け先が読んだら、元のクリップボードへ戻す。読まれなければ、「入力できませんでした」と出して、文字をクリップボードに残す。そのあとに、ほかのアプリがコピーしていたら、戻さない）。",
            "スキル・言語モデル・Tiny-Jev は、使わない（音声入力だけ。起動が速い）。認識は、vc stt（Apple か、ダウンロードした Whisper）。声のない録音は、入力しない。",
            "つなぎ言葉（えーと・um など）を消すには、vc fillers on（辞書は vc fillers で足し引き）。",
            "入力した文字は、画面の上のパネルにだけ出す（ファイル・ログ・端末には残さない）。アクセシビリティの許可が要る（トリガーの検出と、⌘V の送信）。マイクの許可も要る。",
            "トリガーは、--trigger → 音声入力のトリガー（vc hotkey set-dictate）→ 声で頼むトリガー（vc hotkey）。**声で頼むのと、音声入力を、キーで切り替えたいなら、vc hotkey set-dictate <キー> で別のキーを決めて、vc listen --hotkey を使う**（Shift の長押し＝声で頼む、Ctrl の長押し＝音声入力、など）。",
            "Esc で取りやめ（録音中・認識中）。Ctrl+C で終了。",
        ],
        options: [
            ("--trigger <キー>", "この回だけのトリガー（例：shift・ctrl+opt+space・f5）"),
            ("--stt <音声認識>", "この回だけの音声認識（apple・whisper-large-v3-turbo）"),
            ("--dry-run", "入力せずに、認識した文字を、画面の上のパネルに出すだけ（マイク・認識の確認用。前面のアプリには、何も送らない）"),
            ("--mute / --no-mute", "録音中に、ほかの音を消す／消さない（その実行だけ。常にそうするなら vc mute）"),
        ],
        examples: ["vc dictate", "vc dictate --stt whisper-large-v3-turbo", "vc dictate --trigger ctrl+opt+space"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // **ここから `VoiceLoop.run` まで、`await` を挟まない**（`vc listen --hotkey` と同じ。`NSApplication.run()` の前の `await` は、画面の表示・長押しの判定を止める）。
        var arguments = arguments
        let muter = VoiceUI.muter(&arguments, context, command: "dictate")
        guard MicRecorder.authorize() else { fail("マイクが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）") }
        let speech = context.makeSpeechEngine()
        defer { speech.close() }
        let signals = VoiceUI.restoreOnSignals(muter, speech)
        defer { withExtendedLifetime(signals) {} }
        runLoop(context, muter: muter, speech: speech)
    }

    /// 認識した文字を、前面のアプリへ入力する（`vc dictate` と、`vc listen --hotkey` の音声入力のトリガー）。`--dry-run` なら、入力せずに、パネルに出すだけ。
    @MainActor static func handle(_ utterance: String, _ token: CancelToken, context: CommandContext, chip: String, paste: ClipboardPaste) async {
        guard !utterance.isEmpty else {
            notice("聞き取れなかった")
            HUD.shared.show(HUDContent(phase: .failure, title: "聞き取れませんでした", hint: "もう一度、はっきり話してください", chip: chip), hideAfter: 2.5)
            return
        }
        if token.isCancelled { return }
        // つなぎ言葉を消す（設定が on のとき。設定は、入力のたびに読む：`vc fillers add` が、すぐ効く）
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

    @MainActor private func runLoop(_ context: CommandContext, muter: OutputMuter, speech: SpeechEngine) {
        do {
            // トリガー：--trigger → 音声入力のトリガー（--dictate-trigger・vc hotkey set-dictate）→ 声で頼むトリガー（vc hotkey）→ 既定
            let spec = context.options.trigger == nil ? (context.resolveDictateHotKey()?.spec ?? context.resolveHotKey().spec) : context.resolveHotKey().spec
            let chip = spec.displayName
            HUD.shared.warmUp()   // トリガー（グローバルのキー監視）より先に、パネルを 1 回出す
            // 手放し：ダブルタップで、黙るまで録音して、入力する（押し続けるのは、従来どおり）。設定 `handsFree`（既定 on。`vc handsfree`）
            let triggers = VoiceTriggers.make([(VoiceMode.dictate, try makeTrigger(spec))], handsFreeEnabled: context.currentSettings().handsFree ?? true)
            let handsFree = triggers.handsFree
            let session = RecordingSession()
            session.setLevelHandler { HUD.shared.pushLevel($0); handsFree.pushLevel($0) }   // 録音中の波形・手放しの録音の「黙った」
            let paste = ClipboardPaste()
            let loop = VoiceLoop(
                trigger: triggers.trigger, escape: EscapeKey(), recorder: PopRecorder(session, muter: muter), transcriber: speech.transcriber,
                handler: { utterance, token, _, _ in await Self.handle(utterance, token, context: context, chip: chip, paste: paste) },
                onEvent: { event, _ in
                    if case .recordingDiscarded = event { MainActor.assumeIsolated { handsFree.observe(event) } }   // Esc：手放しの状態を解く
                    VoiceUI.show(event, chip: chip, muter: muter, dictation: true)
                })
            handsFree.onHandsFree = { _ in HUD.shared.show(HUDContent(phase: .recording, title: "録音中", hint: HandsFreeGroup.hint, chip: chip)) }
            loop.run {
                print(Style.bold("\(holdInstruction(spec))ている間だけ聞きます") + Style.dim("（Ctrl+C で終了。録音中・認識中に Esc で取りやめ）"))
                kv("音声認識", speech.choice.title, width: 8)
                kv("ほかの音", muter === OutputMuter.disabled ? "録音中も流したまま" : "録音中は消す", width: 8)
                kv("入力先", "いま前面のアプリ（⌘V で貼り付け。クリップボードは、あとで戻す）", width: 8)
                fflush(stdout)
                if !ModifierHold.isTrusted {
                    HUD.shared.show(HUDContent(phase: .failure, title: "アクセシビリティの許可がありません", hint: "システム設定 > プライバシーとセキュリティ > アクセシビリティで、このターミナルを許可し、開き直す（検出と入力に要ります）", chip: chip), hideAfter: 8)
                } else {
                    HUD.shared.show(HUDContent(phase: .info, title: "音声入力の準備ができました", hint: "\(holdInstruction(spec))ている間だけ聞きます", chip: chip), hideAfter: 3.5)
                }
            }
        } catch { fail("ホットキーを登録できません: \(error)") }
    }
}
