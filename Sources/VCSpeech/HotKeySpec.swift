import AppKit
import Carbon.HIToolbox
import Foundation

/// 「押している間だけ聞く」トリガーの設定の書き方（`~/.voice-control/settings.json` の `hotkey`・`--trigger`）。
/// - 修飾キーだけ（`shift`・`ctrl+opt`）→ **長押し**（他のキーなしで 0.35 秒以上。`ModifierHold`。アクセシビリティの許可が要る）
/// - 修飾キー ＋ キー（`ctrl+opt+space`・`cmd+shift+r`）→ **キーの組み合わせ**（`HotKey`。許可は要らない）
/// - ファンクションキー（`f5`）だけは、修飾キーなしでもよい
/// 区切りは `+`（古い書き方の `ctrl-opt-space` の `-` も読める）。大文字小文字は区別しない。
public struct HotKeySpec: Equatable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable {
        case control = "ctrl", option = "opt", shift = "shift", command = "cmd"

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .control: return .control
            case .option: return .option
            case .shift: return .shift
            case .command: return .command
            }
        }
        var carbon: UInt32 {
            switch self {
            case .control: return UInt32(controlKey)
            case .option: return UInt32(optionKey)
            case .shift: return UInt32(shiftKey)
            case .command: return UInt32(cmdKey)
            }
        }
    }

    public struct Failure: Error, Equatable { public let reason: String }

    public let modifiers: Set<Modifier>
    /// 正規化したキーの名前（`space`・`r`・`f5`…）。修飾キーだけなら `nil`（長押し）。
    public let key: String?

    public static let `default` = HotKeySpec(modifiers: [.shift], key: nil)

    /// 長押し（修飾キーだけ）か。
    public var isHold: Bool { key == nil }

    /// 正規化した表記（修飾キーは ctrl・opt・shift・cmd の順）。
    public var description: String {
        (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + (key.map { [$0] } ?? [])).joined(separator: "+")
    }

    /// 画面に出す名前。
    public var displayName: String {
        let symbols: [Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        let mods = Modifier.allCases.filter(modifiers.contains).map { symbols[$0]! }.joined()
        let keyName = key.map { $0 == "space" ? "Space" : $0.uppercased() } ?? ""
        return isHold ? "\(mods)（長押し）" : mods + keyName
    }

    var modifierFlags: NSEvent.ModifierFlags { modifiers.reduce(into: []) { $0.insert($1.flag) } }
    var carbonModifiers: UInt32 { modifiers.reduce(0) { $0 | $1.carbon } }
    var keyCode: UInt32? { key.flatMap { Self.keyCodes[$0] } }

    private static let aliases: [String: Modifier] = [
        "ctrl": .control, "control": .control, "opt": .option, "option": .option, "alt": .option,
        "shift": .shift, "cmd": .command, "command": .command,
    ]

    private static let keyCodes: [String: UInt32] = {
        var t: [String: UInt32] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
            "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
            "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ].mapValues { UInt32($0) }
        return t
    }()

    private static let keyAliases = ["enter": "return", "esc": "escape"]

    /// 文字列 → 設定。書けない形は、理由を返す。
    public static func parse(_ text: String) -> Result<HotKeySpec, Failure> {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty else { return .failure(Failure(reason: "空です")) }
        let separator: Character = lowered.contains("+") ? "+" : "-"
        let tokens = lowered.split(separator: separator, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.contains(where: \.isEmpty) { return .failure(Failure(reason: "「\(text)」は読めません（キーを「+」でつなぐ。例：ctrl+opt+space）")) }

        var modifiers = Set<Modifier>()
        var keys: [String] = []
        for token in tokens {
            if let m = aliases[token] { modifiers.insert(m) } else { keys.append(keyAliases[token] ?? token) }
        }
        if keys.count > 1 { return .failure(Failure(reason: "キーは 1 つだけです（\(keys.joined(separator: "・"))）")) }
        if let key = keys.first {
            guard keyCodes[key] != nil else { return .failure(Failure(reason: "知らないキー「\(key)」（英字・数字・space・return・tab・escape・矢印・f1〜f12）")) }
            let isFunctionKey = key.hasPrefix("f") && key.count > 1
            if modifiers.isEmpty && !isFunctionKey {
                return .failure(Failure(reason: "「\(key)」だけは使えません（普通の入力を奪うため）。修飾キー（ctrl・opt・shift・cmd）をつけるか、f1〜f12 にします"))
            }
            return .success(HotKeySpec(modifiers: modifiers, key: key))
        }
        guard !modifiers.isEmpty else { return .failure(Failure(reason: "キーがありません")) }
        return .success(HotKeySpec(modifiers: modifiers, key: nil))
    }

    /// 押している間だけ聞く入り口を作る。長押しは `ModifierHold`、キーの組み合わせは `HotKey`。
    public func makeTrigger() throws -> any PushToTalkTrigger {
        if let code = keyCode { return try HotKey(keyCode: code, modifiers: carbonModifiers) }
        return ModifierHold(modifier: modifierFlags)
    }
}
