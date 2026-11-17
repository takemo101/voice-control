import Foundation
import VCSpeech

/// 設定画面の、キーの記録（「クリックして、キーを押す」）の判断。**画面・イベントから分けて確かめられる**（`NSEvent` は、`SettingsModel` が、`Input` に直す）。
/// - 修飾キーだけを押して、離す → 長押しのキー（右側のキーだけなら `rshift` など。左右を問わないなら `shift`。複数なら `ctrl+opt`）
/// - 修飾キーを押しながら、ほかのキー → 組み合わせ（`ctrl+opt+space`）。F キーだけは、単独でもよい
/// - Esc だけ → 取りやめ
struct KeyRecorder {
    enum Input: Equatable {
        case modifier(code: UInt16, down: Bool)
        case key(code: UInt16, modifiers: Set<HotKeySpec.Modifier>)
    }

    enum Outcome: Equatable {
        case waiting
        case recorded(String)
        case cancelled
        /// 使えないキー。理由を見せて、もう一度、待つ。
        case rejected(String)
    }

    /// 1 回押すキー（音声入力のあとに送る）を記録するか：単独のキー（Enter・Tab など）も、よい。修飾キーだけの長押しは、記録しない。
    let recordsStroke: Bool

    init(recordsStroke: Bool = false) { self.recordsStroke = recordsStroke }

    private var held: [UInt16] = []
    private var seen: [UInt16] = []
    private var usedKey = false

    private static let escape: UInt16 = 53
    private static let order: [HotKeySpec.Modifier] = [.control, .option, .shift, .command]

    mutating func handle(_ input: Input) -> Outcome {
        switch input {
        case let .modifier(code, down):
            guard HotKeySpec.modifier(forCode: code) != nil, !recordsStroke else { return .waiting }
            if down {
                if !held.contains(code) { held.append(code) }
                if !seen.contains(code) { seen.append(code) }
                return .waiting
            }
            held.removeAll { $0 == code }
            guard held.isEmpty else { return .waiting }
            defer { seen = []; usedKey = false }
            guard !usedKey, !seen.isEmpty else { return .waiting }
            return .recorded(Self.holdText(seen))
        case let .key(code, modifiers):
            usedKey = true
            if code == Self.escape, modifiers.isEmpty { reset(); return .cancelled }
            guard let name = HotKeySpec.keyName(forCode: code) else { return .rejected("このキーは、使えません") }
            if !recordsStroke, modifiers.isEmpty, !(name.hasPrefix("f") && name.count <= 3 && Int(name.dropFirst()) != nil) {
                return .rejected("修飾キー（⌃ ⌥ ⇧ ⌘）と一緒に押してください（F キーだけは、単独で使えます）")
            }
            let mods = Self.order.filter(modifiers.contains).map(\.rawValue)
            return .recorded((mods + [name]).joined(separator: "+"))
        }
    }

    mutating func reset() { held = []; seen = []; usedKey = false }

    private static func holdText(_ codes: [UInt16]) -> String {
        let infos = codes.compactMap { HotKeySpec.modifier(forCode: $0) }
        let modifiers = Set(infos.map(\.modifier))
        // 右側の 1 つのキーだけ：右側だけに反応する（`rshift`）
        if infos.count == 1, infos[0].right { return "r" + infos[0].modifier.rawValue }
        return order.filter(modifiers.contains).map(\.rawValue).joined(separator: "+")
    }
}
