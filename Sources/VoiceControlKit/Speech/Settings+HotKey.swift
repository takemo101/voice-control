import Foundation

extension Settings {
    /// 設定されたトリガー。なければ `shift` の長押し。設定が読めなければ、理由。
    /// （`Settings`（Core）は、書き方の文字列だけを持つ。解釈は、この層（Speech）が担う。）
    public var hotkeySpec: Result<HotKeySpec, HotKeySpec.Failure> {
        guard let hotkey else { return .success(.default) }
        return HotKeySpec.parse(hotkey)
    }
}
