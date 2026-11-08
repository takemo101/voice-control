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

extension CommandContext {
    /// 音声入力のトリガー：`--dictate-trigger` → 設定（`vc hotkey set-dictate`）。なければ `nil`。書き方が違えば、理由を示して終わる。
    func resolveDictateHotKey() -> (spec: HotKeySpec, source: String)? {
        if let text = options.dictateTrigger {
            switch HotKeySpec.parse(text) {
            case let .success(spec): return (spec, "--dictate-trigger")
            case let .failure(f): fail("--dictate-trigger \(text): \(f.reason)")
            }
        }
        guard let text = currentSettings().dictateHotkey else { return nil }
        switch HotKeySpec.parse(text) {
        case let .success(spec): return (spec, "設定")
        case let .failure(f): fail("settings.json の dictateHotkey「\(text)」: \(f.reason)（vc hotkey set-dictate で直す）")
        }
    }
}

/// 押している間だけ聞く入り口。長押し（修飾キーだけ）には、アクセシビリティの許可が要る。
@MainActor func makeTrigger(_ spec: HotKeySpec) throws -> PushToTalkTrigger {
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

/// スクリーンショットのショートカット（`shotHotkey`）。範囲を選ぶ操作の起点なので、**キーの組み合わせ**だけ（長押しは使えない）。
enum ScreenKeys {
    /// 設定できない理由（なければ `nil`）。`taken`：すでに使っているキー（名前と、キー）。
    static func problem(_ spec: HotKeySpec, taken: [(name: String, spec: HotKeySpec)]) -> String? {
        if spec.isHold { return "長押し（修飾キーだけ）は使えません。キーの組み合わせにしてください（例：ctrl+opt+s）" }
        if let clash = taken.first(where: { $0.spec.overlaps(spec) }) { return "\(clash.name)のキー（\(clash.spec.description)）と、重なります" }
        return nil
    }
}

extension CommandContext {
    /// `shotHotkey` を、読む。なければ `nil`。書き方が違えば、理由を示して終わる。
    func resolveScreenKey(_ keyPath: KeyPath<Settings, String?>, command: String) -> HotKeySpec? {
        guard let text = currentSettings()[keyPath: keyPath] else { return nil }
        switch HotKeySpec.parse(text) {
        case let .success(spec): return spec
        case let .failure(f): fail("settings.json の「\(text)」: \(f.reason)（vc hotkey \(command) で直す）")
        }
    }
    func resolveShotHotKey() -> HotKeySpec? { resolveScreenKey(\.shotHotkey, command: "set-shot") }
}
