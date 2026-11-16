import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 1 回押すキー（修飾キーつきでも）：**音声入力のあとに送るキー**（設定 `dictateKey`。既定は Enter）。
/// 書き方と、キーの名前の語彙は、`HotKeySpec` と同じ（`return`・`cmd+return`・`shift+return`・`tab`…）。違い：**単独のキーも、よい**（トリガーは、普通の入力を奪うので、単独を断る。こちらは、「送る」側）。修飾キーだけは、使えない（押す対象がない）。
public struct KeyStroke: Equatable, Sendable {
    public let modifiers: Set<HotKeySpec.Modifier>
    public let key: String

    public init(modifiers: Set<HotKeySpec.Modifier>, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// 既定：Enter（Return）。
    public static let enter = KeyStroke(modifiers: [], key: "return")

    /// 正規化した表記（修飾キーは ctrl・opt・shift・cmd の順）：設定ファイルに書く形。
    public var description: String {
        (HotKeySpec.Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+")
    }

    /// 画面に出す名前（例：「Enter」「⌘Enter」「⇧Tab」）。
    public var displayName: String {
        let symbols: [HotKeySpec.Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        let mods = HotKeySpec.Modifier.allCases.filter(modifiers.contains).map { symbols[$0]! }.joined()
        let names = ["return": "Enter", "space": "Space", "tab": "Tab", "escape": "Esc", "left": "←", "right": "→", "up": "↑", "down": "↓"]
        return mods + (names[key] ?? key.uppercased())
    }

    var keyCode: CGKeyCode { HotKeySpec.keyCodes[key].map { CGKeyCode($0) } ?? CGKeyCode(kVK_Return) }

    /// 文字列 → キー。書けない形は、理由を返す。
    public static func parse(_ text: String) -> Result<KeyStroke, HotKeySpec.Failure> {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty else { return .failure(.init(reason: "空です")) }
        let separator: Character = lowered.contains("+") ? "+" : "-"
        let tokens = lowered.split(separator: separator, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.contains(where: \.isEmpty) { return .failure(.init(reason: "「\(text)」は読めません（キーを「+」でつなぐ。例：cmd+return）")) }
        var modifiers = Set<HotKeySpec.Modifier>()
        var keys: [String] = []
        for token in tokens {
            if let modifier = HotKeySpec.aliases[token] { modifiers.insert(modifier) } else { keys.append(HotKeySpec.keyAliases[token] ?? token) }
        }
        guard keys.count == 1, let key = keys.first else {
            return .failure(.init(reason: keys.isEmpty ? "キーがありません（修飾キーだけは、使えません）" : "キーは 1 つだけです（\(keys.joined(separator: "・"))）"))
        }
        guard HotKeySpec.keyCodes[key] != nil else { return .failure(.init(reason: "知らないキー「\(key)」（英字・数字・space・return・tab・escape・矢印・f1〜f12）")) }
        return .success(KeyStroke(modifiers: modifiers, key: key))
    }
}

extension KeyStroke {
    private static let modifierCodes: [(HotKeySpec.Modifier, CGKeyCode, CGEventFlags)] = [
        (.control, 59, .maskControl), (.option, 58, .maskAlternate), (.shift, 56, .maskShift), (.command, 55, .maskCommand),
    ]

    /// 前面のアプリへ、このキーを送る：修飾キーの押下 → キーの押下と離し → 修飾キーの解放を、15 ミリ秒ずつあけて、順に送る（修飾キーの状態を、自分のイベントで、はっきりさせる：直前まで押していたトリガーの Shift が、残らない）。
    public static func send(_ stroke: KeyStroke) {
        let source = CGEventSource(stateID: .hidSystemState)
        let pressed = modifierCodes.filter { stroke.modifiers.contains($0.0) }
        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, modifierChange: Bool = false) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            if modifierChange { event?.type = .flagsChanged }
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(15_000)
        }
        var flags: CGEventFlags = []
        for (_, code, flag) in pressed { flags.insert(flag); post(code, down: true, flags: flags, modifierChange: true) }
        post(stroke.keyCode, down: true, flags: flags)
        post(stroke.keyCode, down: false, flags: flags)
        for (_, code, flag) in pressed.reversed() { flags.remove(flag); post(code, down: false, flags: flags, modifierChange: true) }
    }
}
