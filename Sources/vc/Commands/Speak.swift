import AVFoundation
import Foundation
import VCCore
import VCSpeech

struct SpeakCommand: Command {
    static let info = CommandInfo(
        name: "speak", group: .settings, summary: "読み上げ（確認の問いかけ・結果）の声と、結果を読み上げるかの確認・変更",
        usage: ["vc speak [show]", "vc speak on|off", "vc speak voice <名前|識別子|auto>", "vc speak voices", "vc speak test [文]", "vc speak reset"],
        details: [
            "設定は ~/.voice-control/settings.json の speakResults（結果を読み上げるか。既定 off）と voice（声。既定は auto）。",
            "**声は、入っている日本語の声のうち、品質がいちばん高いものを、自動で使う**（高品質＞拡張＞標準。面白い声は、選ばない）。より自然な声にするには、システム設定 > アクセシビリティ > 読み上げコンテンツ > システムの声 の「声を管理…」で、日本語の「拡張」の声（Kyoko・Otoya。この Mac の Apple のカタログにある、日本語の声は、この 2 つ）を、ダウンロードする。そのあと、vc speak voices で、入ったことを確かめる。",
            "on にすると、**短い結果**（「完了：〇〇」「失敗：〇〇」）を、声で読み上げる。長い文章（ウィンドウに出す結果）は、読まない。確認の問いかけは、on・off に関わらず、読み上げる。",
            "voices：入っている日本語の声と品質。test：いまの声で、短い文を、実際に鳴らす（音が出る）。",
        ],
        options: [],
        examples: ["vc speak", "vc speak on", "vc speak voices", "vc speak voice Otoya", "vc speak test"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let sub = arguments.positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            heading("読み上げ")
            kv("結果の読み上げ", Style.bold(settings.speakResults == true ? "on" : "off") + Style.dim(settings.speakResults == nil ? "（既定）" : ""), width: 14)
            let voices = SpeechVoice.installed()
            let using = SpeechVoice.resolve(preferred: settings.voice, voices: voices)
            kv("声", Style.bold(using?.title ?? "（日本語の声がありません）") + Style.dim(settings.voice.map { "（指定：\($0)）" } ?? "（自動）"), width: 14)
            if let using, using.quality < 3 {
                print("")
                notice("より自然な声：システム設定 > アクセシビリティ > 読み上げコンテンツ > システムの声 > 声を管理… で、日本語の「拡張」の声（Kyoko・Otoya）をダウンロード（vc speak voices で確認）")
            }
        case "on", "off":
            settings.speakResults = sub == "on"
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            heading("読み上げ")
            kv("結果の読み上げ", Style.bold(sub), width: 14)
            notice("次の vc listen --hotkey から有効")
        case "voices":
            heading("入っている日本語の声")
            let voices = SpeechVoice.installed().sorted { ($0.quality, $1.identifier) > ($1.quality, $0.identifier) }
            let using = SpeechVoice.resolve(preferred: settings.voice, voices: voices)
            if voices.isEmpty { notice("日本語の声が、1 つもありません") }
            for voice in voices {
                kv(voice.name, voice.qualityTitle + Style.dim("  \(voice.identifier)") + (voice.identifier == using?.identifier ? Style.green("  ← 使っている") : ""), width: 10)
            }
            print("")
            notice("拡張・高品質の声が、1 つもなければ、システム設定 > アクセシビリティ > 読み上げコンテンツ > システムの声 > 声を管理… で、日本語の声をダウンロード")
        case "voice":
            guard let value = arguments.positionals.dropFirst().first else { usageError("speak", "声の名前か識別子を渡してください（例: vc speak voice Otoya。自動に戻す：vc speak voice auto）") }
            if value.lowercased() == "auto" { settings.voice = nil } else {
                guard SpeechVoice.resolve(preferred: value, voices: SpeechVoice.installed())?.matches(value) == true else { fail("その声は入っていません: \(value)（入っている声：vc speak voices）") }
                settings.voice = value
            }
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 声を " + Style.bold(settings.voice ?? "auto（自動）") + " にしました")
        case "test":
            let text = arguments.positionals.dropFirst().joined(separator: " ")
            let sentence = text.isEmpty ? "音量を五十にしました。次の曲をかけます。" : text
            let voice = SpeechVoice.resolve(preferred: settings.voice, voices: SpeechVoice.installed())
            print(Style.dim("声：\(voice?.title ?? "標準")"))
            await Self.speakAndWait(sentence, voice: voice)
        case "reset":
            settings.speakResults = nil; settings.voice = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（読み上げ off・声は自動）に戻しました")
        default:
            usageError("speak", "知らないサブコマンド: \(sub)（show・on・off・voices・voice・test・reset）")
        }
    }

    /// 鳴らして、終わるまで待つ（`vc speak test`）。
    @MainActor private static func speakAndWait(_ text: String, voice: SpeechVoice.Info?) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: "ja-JP")
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.speak(utterance)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)   // try?: 取りやめられたら、待ちを終える
            if !synthesizer.isSpeaking { break }
        }
    }
}

extension SpeechVoice.Info {
    var qualityTitle: String { quality >= 3 ? "高品質" : (quality == 2 ? "拡張" : "標準") }
    /// 名前か識別子が、これ（大文字小文字は見ない）。
    func matches(_ text: String) -> Bool { identifier.lowercased() == text.lowercased() || name.lowercased() == text.lowercased() }
}
