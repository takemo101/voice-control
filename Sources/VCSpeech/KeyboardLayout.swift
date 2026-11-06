import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// いまのキーボード配列（ABC・Dvorak・Colemak など）で、ある文字を出すキーの番号を引く。
/// ⌘V を送るとき、`V` の位置が、配列で違っても、同じキーを押せるようにする（固定の番号は、QWERTY の位置）。
enum KeyboardLayout {
    /// 文字入力に使える（ASCII を出せる）、いまの配列で、`character`（小文字 1 文字）を出すキーの仮想キーコード。見つからなければ nil。
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.value <= 0xFFFF,
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let wanted = UniChar(scalar.value)
        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 as Range<UInt16> {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == wanted { return CGKeyCode(code) }
            }
            return nil
        }
    }
}
