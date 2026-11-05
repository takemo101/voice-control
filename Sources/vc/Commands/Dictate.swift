import AppKit
import Foundation
import VCCore
import VCSpeech

struct DictateCommand: Command {
    static let info = CommandInfo(
        name: "dictate", group: .skills, summary: "音声入力だけ：押している間だけ録音し、文字にして、前面のアプリへ入力する",
        usage: ["vc dictate [--trigger <キー>] [--stt <apple|ID>] [--mute|--no-mute] [--dry-run]"],
        details: [
            "押している間だけ録音（既定：Shift の長押し。vc hotkey で変更）→ 離すと文字にして、**いま前面のアプリへ入力**する（クリップボードに書いて ⌘V を送り、少しあとに、元のクリップボードへ戻す。そのあとに、ほかのアプリがコピーしていたら、戻さない）。",
            "スキル・言語モデル・Tiny-Jev は、使わない（音声入力だけ。起動が速い）。認識は、vc stt（Apple か、ダウンロードした Whisper）。声のない録音は、入力しない。",
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
        if context.options.dryRun {
            print("  " + Style.yellow("入力しません（--dry-run）") + "（\(utterance.count) 文字）")
            HUD.shared.show(HUDContent(phase: .info, title: "認識しました（入力しません：--dry-run）", chip: chip, reply: utterance), hideAfter: 2.5)
            return
        }
        do {
            try await paste.insert(utterance)
            print("  " + Style.green("✓") + " 入力しました（\(utterance.count) 文字）")
            HUD.shared.show(HUDContent(phase: .success, title: "入力しました", chip: chip, reply: utterance), hideAfter: 1.8)
        } catch { VoiceUI.showFailure(error, chip: chip) }
    }

    @MainActor private func runLoop(_ context: CommandContext, muter: OutputMuter, speech: SpeechEngine) {
        do {
            // トリガー：--trigger → 音声入力のトリガー（--dictate-trigger・vc hotkey set-dictate）→ 声で頼むトリガー（vc hotkey）→ 既定
            let spec = context.options.trigger == nil ? (context.resolveDictateHotKey()?.spec ?? context.resolveHotKey().spec) : context.resolveHotKey().spec
            let chip = spec.displayName
            HUD.shared.warmUp()   // トリガー（グローバルのキー監視）より先に、パネルを 1 回出す
            let trigger = try makeTrigger(spec)
            let session = RecordingSession()
            session.setLevelHandler { HUD.shared.pushLevel($0) }   // 録音中の波形
            let paste = ClipboardPaste()
            let loop = VoiceLoop(
                trigger: trigger, escape: EscapeKey(), recorder: PopRecorder(session, muter: muter), transcriber: speech.transcriber,
                handler: { utterance, token, _, _ in await Self.handle(utterance, token, context: context, chip: chip, paste: paste) },
                onEvent: { event, _ in VoiceUI.show(event, chip: chip, muter: muter, dictation: true) })
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
