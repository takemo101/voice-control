import Foundation
import VCSpeech

struct HotkeyCommand: Command {
    static let info = CommandInfo(
        name: "hotkey", group: .settings, summary: "押している間だけ聞くトリガー（ホットキー）の確認・変更",
        usage: ["vc hotkey [show]", "vc hotkey set <キー>", "vc hotkey reset", "vc hotkey set-dictate <キー>", "vc hotkey reset-dictate", "vc hotkey set-shot <キー>", "vc hotkey reset-shot", "vc hotkey set-ocr <キー>", "vc hotkey reset-ocr"],
        details: [
            "設定は ~/.voice-control/settings.json の hotkey。既定は shift の長押し。",
            "書き方：修飾キー（ctrl・opt・shift・cmd）を + でつなぐ。修飾キーだけ（shift・ctrl+opt）は長押し（他のキーなしで 0.35 秒以上。アクセシビリティの許可が要る）。修飾キー + キー（ctrl+opt+space・cmd+shift+r）は、キーの組み合わせ（許可は要らない）。f1〜f12 だけは、単独でもよい。",
            "**右側のキーだけ**にもできる：rshift・rcmd・ropt・rctrl（長押し専用。左のキーでは反応しない。普段の入力と重ならない）。例：vc hotkey set rcmd。",
            "キーは、英字・数字・space・return・tab・escape・矢印（left・right・up・down）・f1〜f12。普通の入力を奪う、修飾キーなしの文字は使えない。macOS が先に使う組み合わせ（cmd+space など）は、届かないことがある。",
            "**音声入力のキーを別に決める**（set-dictate）と、vc listen --hotkey が、2 つのキーで切り替わる：声で頼むキー（既定 Shift の長押し）＝スキルで実行、音声入力のキー（例：ctrl の長押し）＝文字にして前面のアプリへ入力（vc dictate と同じ）。別のキーを押している間は、録音中のほうが優先。vc dictate は、音声入力のキーがあれば、それを使う。",
            "**スクリーンショットのキー**：set-shot（範囲を選んで撮る。そのあと、声で頼む：「この画像の文字を書き出して」「これは何？」「右半分を切り抜いて」）と set-ocr（範囲を選んで、文字だけを書き出して、ウィンドウに出す。声は使わない）。キーの組み合わせだけ（例：ctrl+opt+s・ctrl+opt+t。長押しは使えない）。どちらも設定なしが既定で、vc listen --hotkey の中で動く。画面収録の許可が要る。",
            "変えたら、vc hotkey-check で確かめる。vc listen --hotkey の次の起動から有効。",
        ],
        options: [],
        examples: ["vc hotkey", "vc hotkey set ctrl+opt+space", "vc hotkey set f5", "vc hotkey reset", "vc hotkey set-dictate ctrl", "vc hotkey reset-dictate", "vc hotkey set-shot ctrl+opt+s", "vc hotkey set-ocr ctrl+opt+t"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        // vc hotkey [show]／set <キー>／reset：押している間だけ聞くトリガーの設定（~/.voice-control/settings.json）。
        let positionals = arguments.positionals
        let sub = positionals.first ?? "show"
        var settings = context.currentSettings()
        switch sub {
        case "show":
            let (spec, source) = context.resolveHotKey()
            heading("ホットキー")
            kv("いまの設定", Style.bold(spec.description) + Style.dim("（\(spec.displayName)・\(source)）"))
            kv("種類", spec.isHold ? "長押し（他のキーなしで 0.35 秒以上。アクセシビリティの許可が要る）" : "キーの組み合わせ（許可は要らない）")
            if let dictate = context.resolveDictateHotKey() {
                kv("音声入力", Style.bold(dictate.spec.description) + Style.dim("（\(dictate.spec.displayName)・\(dictate.source)。vc listen --hotkey でも、このキーは、音声入力になる）"))
            } else {
                kv("音声入力", Style.dim("別のキーはなし（vc dictate は、上のキーを使う）。別のキーにする：vc hotkey set-dictate <キー>"))
            }
            for (label, key, command) in [("画面を撮る", context.resolveShotHotKey(), "set-shot"), ("文字だけ", context.resolveOcrHotKey(), "set-ocr")] {
                if let key { kv(label, Style.bold(key.description) + Style.dim("（\(key.displayName)。vc listen --hotkey の中で動く。画面収録の許可が要る）"), width: 10) }
                else { kv(label, Style.dim("なし。決める：vc hotkey \(command) <キー>"), width: 10) }
            }
            if spec.isHold { kv("許可", ModifierHold.isTrusted ? Style.green("アクセシビリティ：許可済み") : Style.red("アクセシビリティ：未許可") + Style.dim("（システム設定 > プライバシーとセキュリティ > アクセシビリティで、このターミナルを許可し、開き直す）")) }
            print("")
            notice("変える：vc hotkey set <キー>（例：shift・ctrl+opt・ctrl+opt+space・cmd+shift+r・f5）。戻す：vc hotkey reset")
            notice("確かめる：vc hotkey-check（押して、離す。画面に「録音中」が出る）")
        case "set":
            guard positionals.count >= 2 else { usageError("hotkey", "キーを渡してください（例: vc hotkey set ctrl+opt+space）") }
            let text = positionals.dropFirst().joined(separator: "+")
            switch HotKeySpec.parse(text) {
            case let .failure(f): fail("\(text): \(f.reason)")
            case let .success(spec):
                if let dictateText = settings.dictateHotkey, case let .success(dictate) = HotKeySpec.parse(dictateText), dictate.overlaps(spec) {
                    fail("音声入力のキー（\(dictate.description)）と、重なります（\(spec.description)）。先に vc hotkey reset-dictate するか、別のキーにしてください")
                }
                settings.hotkey = spec.description
                do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
                heading("ホットキー")
                kv("設定した", Style.bold(spec.description) + Style.dim("（\(spec.displayName)）"))
                if spec.isHold && !ModifierHold.isTrusted { notice("長押しの検出には、アクセシビリティの許可が要ります（この端末アプリに。agent-desktop permissions）") }
                notice("次の vc listen --hotkey から有効（確かめる：vc hotkey-check）")
            }
        case "set-dictate":
            guard positionals.count >= 2 else { usageError("hotkey", "キーを渡してください（例: vc hotkey set-dictate ctrl）") }
            let text = positionals.dropFirst().joined(separator: "+")
            switch HotKeySpec.parse(text) {
            case let .failure(f): fail("\(text): \(f.reason)")
            case let .success(spec):
                if case let .success(listen) = settings.hotkeySpec, listen.overlaps(spec) {
                    fail("声で頼むキー（\(listen.description)）と、重なります（\(spec.description)）。別のキーにしてください（rshift と shift のように、左右の指定が重なる場合も、重なる）")
                }
                settings.dictateHotkey = spec.description
                do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
                heading("音声入力のキー")
                kv("設定した", Style.bold(spec.description) + Style.dim("（\(spec.displayName)）"))
                notice("次の vc listen --hotkey から、声で頼む／音声入力が、キーで切り替わる。vc dictate も、このキーを使う")
            }
        case "reset-dictate":
            settings.dictateHotkey = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 音声入力のキーを外しました（vc dictate は、声で頼むキーを使う）")
        case "set-shot", "set-ocr":
            let isShot = sub == "set-shot"
            guard positionals.count >= 2 else { usageError("hotkey", "キーを渡してください（例: vc hotkey \(sub) \(isShot ? "ctrl+opt+s" : "ctrl+opt+t")）") }
            let text = positionals.dropFirst().joined(separator: "+")
            switch HotKeySpec.parse(text) {
            case let .failure(f): fail("\(text): \(f.reason)")
            case let .success(spec):
                var taken: [(name: String, spec: HotKeySpec)] = []
                if case let .success(listen) = settings.hotkeySpec { taken.append(("声で頼む", listen)) }
                if let t = settings.dictateHotkey, case let .success(k) = HotKeySpec.parse(t) { taken.append(("音声入力", k)) }
                let other = isShot ? ("文字の書き出し", settings.ocrHotkey) : ("スクリーンショット", settings.shotHotkey)
                if let t = other.1, case let .success(k) = HotKeySpec.parse(t) { taken.append((other.0, k)) }
                if let why = ScreenKeys.problem(spec, taken: taken) { fail("\(text): \(why)") }
                if isShot { settings.shotHotkey = spec.description } else { settings.ocrHotkey = spec.description }
                do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
                heading(isShot ? "スクリーンショットのキー" : "文字を書き出すキー")
                kv("設定した", Style.bold(spec.description) + Style.dim("（\(spec.displayName)）"))
                notice("次の vc listen --hotkey から有効。画面収録の許可が要ります（\(ScreenCapture.isAllowed ? "いまは、許可されています" : "いまは、未許可：" + ScreenCapture.permissionHint)）")
            }
        case "reset-shot", "reset-ocr":
            if sub == "reset-shot" { settings.shotHotkey = nil } else { settings.ocrHotkey = nil }
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " \(sub == "reset-shot" ? "スクリーンショット" : "文字を書き出す")のキーを外しました")
        case "reset":
            settings.hotkey = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（shift の長押し）に戻しました")
        default:
            usageError("hotkey", "知らないサブコマンド: \(sub)（show・set・reset・set-dictate・reset-dictate・set-shot・reset-shot・set-ocr・reset-ocr）")
        }
    }
}
