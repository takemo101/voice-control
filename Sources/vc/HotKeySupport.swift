import Foundation
import VCCore
import VCSpeech

extension CommandContext {
    /// トリガー（押している間だけ聞く）：設定（`hotkey`）→ 既定（`shift` の長押し）。書き方は `HotKeySpec`。
    func resolveHotKey() -> (spec: HotKeySpec, source: String) {
        let settings = currentSettings()
        switch settings.hotkeySpec {
        case let .success(spec): return (spec, settings.hotkey == nil ? "既定" : "設定")
        case let .failure(f): fail("設定の「声で頼む」のキー「\(settings.hotkey ?? "")」: \(f.reason)（設定ウィンドウ > キー で直す）")
        }
    }
}

extension CommandContext {
    /// 音声入力のトリガー：設定。なければ `nil`。書き方が違えば、理由を示して終わる。
    func resolveDictateHotKey() -> (spec: HotKeySpec, source: String)? {
        guard let text = currentSettings().dictateHotkey else { return nil }
        switch HotKeySpec.parse(text) {
        case let .success(spec): return (spec, "設定")
        case let .failure(f): fail("設定の「音声入力」のキー「\(text)」: \(f.reason)（設定ウィンドウ > キー で直す）")
        }
    }
}

extension CommandContext {
    /// 会話のトリガー：設定（設定ウィンドウ > キー）。なければ `nil`（会話はない）。書き方が違えば、理由を示して終わる。
    func resolveChatHotKey() -> HotKeySpec? {
        guard let text = currentSettings().chatHotkey else { return nil }
        switch HotKeySpec.parse(text) {
        case let .success(spec): return spec
        case let .failure(f): fail("設定の「会話」のキー「\(text)」: \(f.reason)（設定ウィンドウ > キー で直す）")
        }
    }
}

/// 押している間だけ聞く入り口。長押し（修飾キーだけ）には、アクセシビリティの許可が要る。
@MainActor func makeTrigger(_ spec: HotKeySpec) throws -> PushToTalkTrigger {
    if spec.isHold && !ModifierHold.isTrusted {
        notice("\(spec.displayName) の長押しの検出には、アクセシビリティの許可が要ります。許可がないと、何も届きません")
        notice("システム設定 > プライバシーとセキュリティ > アクセシビリティで、このアプリを許可してください。許可なしで使うなら、設定ウィンドウ > キー で、ctrl+opt+space のような組み合わせにします")
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
        case let .failure(f): fail("設定のキー「\(text)」: \(f.reason)（設定ウィンドウ > キー で直す）")
        }
    }
    func resolveShotHotKey() -> HotKeySpec? { resolveScreenKey(\.shotHotkey, command: "set-shot") }
}
