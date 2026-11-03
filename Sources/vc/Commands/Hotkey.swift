import Foundation
import VCSpeech

struct HotkeyCommand: Command {
    static let info = CommandInfo(
        name: "hotkey", group: .settings, summary: "押している間だけ聞くトリガー（ホットキー）の確認・変更",
        usage: ["vc hotkey [show]", "vc hotkey set <キー>", "vc hotkey reset"],
        details: [
            "設定は ~/.voice-control/settings.json の hotkey。既定は shift の長押し。",
            "書き方：修飾キー（ctrl・opt・shift・cmd）を + でつなぐ。修飾キーだけ（shift・ctrl+opt）は長押し（他のキーなしで 0.35 秒以上。アクセシビリティの許可が要る）。修飾キー + キー（ctrl+opt+space・cmd+shift+r）は、キーの組み合わせ（許可は要らない）。f1〜f12 だけは、単独でもよい。",
            "キーは、英字・数字・space・return・tab・escape・矢印（left・right・up・down）・f1〜f12。普通の入力を奪う、修飾キーなしの文字は使えない。macOS が先に使う組み合わせ（cmd+space など）は、届かないことがある。",
            "変えたら、vc hotkey-check で確かめる。vc listen --hotkey の次の起動から有効。",
        ],
        options: [],
        examples: ["vc hotkey", "vc hotkey set ctrl+opt+space", "vc hotkey set f5", "vc hotkey reset"])

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
                settings.hotkey = spec.description
                do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
                heading("ホットキー")
                kv("設定した", Style.bold(spec.description) + Style.dim("（\(spec.displayName)）"))
                if spec.isHold && !ModifierHold.isTrusted { notice("長押しの検出には、アクセシビリティの許可が要ります（この端末アプリに。agent-desktop permissions）") }
                notice("次の vc listen --hotkey から有効（確かめる：vc hotkey-check）")
            }
        case "reset":
            settings.hotkey = nil
            do { try settings.save() } catch { fail("設定を保存できません: \(error)") }
            print(Style.green("✓") + " 既定（shift の長押し）に戻しました")
        default:
            usageError("hotkey", "知らないサブコマンド: \(sub)（show・set・reset）")
        }
    }
}
