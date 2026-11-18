import Foundation
import VCCore
import VCSpeech

/// キーの設定（`hotkey`・`dictateHotkey`・`chatHotkey`・`shotHotkey`）の読み取り。**検査は 1 回**（`resolveKeys`）で、書き間違いは `StartupProblem`（直せるページ：キー）。
/// 端末の `vc` は、使うときに `fail` で終わる。メニューバーのアプリは、`resolvingChoices` で検査済みの値を使う（書き間違いで、終わらない）。
extension CommandContext {
    /// トリガー（押している間だけ聞く）：設定（`hotkey`）→ 既定（`shift` の長押し）。書き方は `HotKeySpec`。
    func resolveHotKey() -> (spec: HotKeySpec, source: String) {
        if let choices { return choices.keys.listen }
        do { return try resolveKeys(settings: currentSettings()).listen } catch { fail("\(error)") }
    }

    /// 音声入力のトリガー：設定。なければ `nil`。
    func resolveDictateHotKey() -> (spec: HotKeySpec, source: String)? {
        if let choices { return choices.keys.dictate }
        do { return try resolveKeys(settings: currentSettings()).dictate } catch { fail("\(error)") }
    }

    /// 会話のトリガー：設定（設定ウィンドウ > キー）。なければ `nil`（会話はない）。
    func resolveChatHotKey() -> HotKeySpec? {
        if let choices { return choices.keys.chat }
        do { return try resolveKeys(settings: currentSettings()).chat } catch { fail("\(error)") }
    }

    /// スクリーンショットのショートカット（`shotHotkey`）。なければ `nil`。
    func resolveShotHotKey() -> HotKeySpec? {
        if let choices { return choices.keys.shot }
        do { return try resolveKeys(settings: currentSettings()).shot } catch { fail("\(error)") }
    }

    /// 4 つのキーを、検査して、型にする。
    func resolveKeys(settings: Settings) throws -> ResolvedKeys {
        func parse(_ text: String, _ name: String) throws -> HotKeySpec {
            switch HotKeySpec.parse(text) {
            case let .success(spec): return spec
            case let .failure(f): throw StartupProblem("設定の「\(name)」のキー「\(text)」: \(f.reason)（設定ウィンドウ > キー で直す）", page: .keys)
            }
        }
        let listen: (spec: HotKeySpec, source: String)
        switch settings.hotkeySpec {
        case let .success(spec): listen = (spec, settings.hotkey == nil ? "既定" : "設定")
        case let .failure(f): throw StartupProblem("設定の「声で頼む」のキー「\(settings.hotkey ?? "")」: \(f.reason)（設定ウィンドウ > キー で直す）", page: .keys)
        }
        return ResolvedKeys(listen: listen,
                            dictate: try settings.dictateHotkey.map { (try parse($0, "音声入力"), "設定") },
                            chat: try settings.chatHotkey.map { try parse($0, "会話") },
                            shot: try settings.shotHotkey.map { try parse($0, "スクリーンショット") })
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
