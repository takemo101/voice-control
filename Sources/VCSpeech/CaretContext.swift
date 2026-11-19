import ApplicationServices
import Foundation

/// 前面のアプリの、**入力欄の、カーソルの直前の 1 文字**（`SmartSpacing` が、空白を足すかの判断に使う）。アクセシビリティで、その場で読むだけ：**保存しない**。
/// 読めないとき（許可がない・入力欄でない・パスワード欄・アプリが応えない）は nil：何も足さない。
public enum CaretContext {
    @MainActor public static func characterBeforeCaret() -> Character? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)   // 応えないアプリで、入力が止まらないように
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { return nil }
        let field = element as! AXUIElement   // 型は、API が保証する
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) == .success, (subrole as? String) == "AXSecureTextField" { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success, let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location > 0 else { return nil }   // 先頭：前の文字は、ない
        // 直前の 1 文字だけを、アプリに聞く（大きな文書の全文を、読まない）
        var previous = CFRange(location: selection.location - 1, length: 1)
        if let range = AXValueCreate(.cfRange, &previous) {
            var string: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, range, &string) == .success, let text = string as? String, let c = text.last { return c }
        }
        // 聞けないアプリ：全文を読む（短いものだけ）
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success, let text = value as? String, text.utf16.count <= 100_000 else { return nil }
        let ns = text as NSString
        guard selection.location <= ns.length else { return nil }
        return ns.substring(with: ns.rangeOfComposedCharacterSequence(at: selection.location - 1)).last
    }
}
