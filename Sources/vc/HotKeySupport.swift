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
            case let .failure(f): throw StartupProblem(tr("設定の「\(name)」のキー「\(text)」: \(f.reason)（設定ウィンドウ > キー で直す）"), page: .keys)
            }
        }
        let listen: (spec: HotKeySpec, source: String)
        switch settings.hotkeySpec {
        case let .success(spec): listen = (spec, settings.hotkey == nil ? tr("既定") : tr("設定"))
        case let .failure(f): let text = settings.hotkey ?? ""; throw StartupProblem(tr("設定の「声で頼む」のキー「\(text)」: \(f.reason)（設定ウィンドウ > キー で直す）"), page: .keys)
        }
        return ResolvedKeys(listen: listen,
                            dictate: try settings.dictateHotkey.map { (try parse($0, tr("音声入力")), tr("設定")) },
                            chat: try settings.chatHotkey.map { try parse($0, tr("会話")) },
                            shot: try settings.shotHotkey.map { try parse($0, tr("スクリーンショット")) })
    }
}

/// 押している間だけ聞く入り口。長押し（修飾キーだけ）には、アクセシビリティの許可が要る。
@MainActor func makeTrigger(_ spec: HotKeySpec) throws -> PushToTalkTrigger {
    if spec.isHold && !ModifierHold.isTrusted {
        notice(tr("\(spec.displayName) の長押しの検出には、アクセシビリティの許可が要ります。許可がないと、何も届きません"))
        notice(tr("システム設定 > プライバシーとセキュリティ > アクセシビリティで、このアプリを許可してください。許可なしで使うなら、設定ウィンドウ > キー で、ctrl+opt+space のような組み合わせにします"))
    }
    return try spec.makeTrigger()
}

/// 使い方の文の頭（「…て、離す」につなぐ。端末の `hotkey-check`（開発用）だけが使う：日本語の文の組み立てなので、翻訳しない）。
func holdInstruction(_ spec: HotKeySpec) -> String {
    spec.isHold ? "\(spec.description) を単独で 0.35 秒以上押し続け" : "\(spec.description) を押し"   // l10n-skip
}

/// 「押している間だけ」の文。日本語の語尾のつなぎを、英語へ持ち込まないために、文ごと翻訳する。
func holdWhile(_ spec: HotKeySpec, _ phrase: HoldPhrase) -> String {
    switch (spec.isHold, phrase) {
    case (true, .listen): tr("\(spec.description) を単独で 0.35 秒以上押し続けている間だけ聞きます")
    case (false, .listen): tr("\(spec.description) を押している間だけ聞きます")
    case (true, .chat): tr("\(spec.description) を単独で 0.35 秒以上押し続けている間だけ（スキルを選ばず、会話として質問。古いやり取りは、要約して続ける）")
    case (false, .chat): tr("\(spec.description) を押している間だけ（スキルを選ばず、会話として質問。古いやり取りは、要約して続ける）")
    case (true, .dictate): tr("\(spec.description) を単独で 0.35 秒以上押し続けている間だけ（前面のアプリへ入力）")
    case (false, .dictate): tr("\(spec.description) を押している間だけ（前面のアプリへ入力）")
    case (true, .screenshot): tr("\(spec.description) を単独で 0.35 秒以上押し続けて、「この画像の文字を書き出して」などと話す。文字だけなら、パネルの「文字起こし」（\(ScreenshotStore.timeToLiveMinutes) 分以内）")
    case (false, .screenshot): tr("\(spec.description) を押して、「この画像の文字を書き出して」などと話す。文字だけなら、パネルの「文字起こし」（\(ScreenshotStore.timeToLiveMinutes) 分以内）")
    }
}

enum HoldPhrase { case listen, chat, dictate, screenshot }

/// スクリーンショットのショートカット（`shotHotkey`）。範囲を選ぶ操作の起点なので、**キーの組み合わせ**だけ（長押しは使えない）。
enum ScreenKeys {
    /// 設定できない理由（なければ `nil`）。`taken`：すでに使っているキー（名前と、キー）。
    static func problem(_ spec: HotKeySpec, taken: [(name: String, spec: HotKeySpec)]) -> String? {
        if spec.isHold { return tr("長押し（修飾キーだけ）は使えません。キーの組み合わせにしてください（例：ctrl+opt+s）") }
        if let clash = taken.first(where: { $0.spec.overlaps(spec) }) { return tr("\(clash.name)のキー（\(clash.spec.description)）と、重なります") }
        return nil
    }
}
