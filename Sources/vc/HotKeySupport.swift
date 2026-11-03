import Foundation
import VCCore
import VCSpeech

extension CommandContext {
    /// トリガー（押している間だけ聞く）：`--trigger` → `~/.voice-control/settings.json` の `hotkey` → 既定（`shift` の長押し）。書き方は `HotKeySpec`。
    func resolveHotKey() -> (spec: HotKeySpec, source: String) {
        if let trigger = options.trigger {
            switch HotKeySpec.parse(trigger) {
            case let .success(spec): return (spec, "--trigger")
            case let .failure(f): fail("--trigger \(trigger): \(f.reason)")
            }
        }
        let settings = currentSettings()
        switch settings.hotkeySpec {
        case let .success(spec): return (spec, settings.hotkey == nil ? "既定" : "設定")
        case let .failure(f): fail("settings.json の hotkey「\(settings.hotkey ?? "")」: \(f.reason)（vc hotkey set で直す）")
        }
    }
}

/// 押している間だけ聞く入り口。長押し（修飾キーだけ）には、アクセシビリティの許可が要る。
func makeTrigger(_ spec: HotKeySpec) throws -> PushToTalkTrigger {
    if spec.isHold && !ModifierHold.isTrusted {
        notice("\(spec.displayName) の長押しの検出には、アクセシビリティの許可が要ります。許可がないと、何も届きません")
        notice("システム設定 > プライバシーとセキュリティ > アクセシビリティで、vc を動かしているターミナルを許可し、そのターミナルを開き直す。許可なしで使うなら、vc hotkey set ctrl+opt+space")
    }
    return try spec.makeTrigger()
}

/// 使い方の文の頭（「…て、離す」「…ている間だけ聞きます」につなぐ）。
func holdInstruction(_ spec: HotKeySpec) -> String {
    spec.isHold ? "\(spec.description) を単独で 0.35 秒以上押し続け" : "\(spec.description) を押し"
}
