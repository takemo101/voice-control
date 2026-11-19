import Foundation
import VCCore
import VCSkill
import VCSpeech

/// 設定画面の、画面から分けて確かめられる規則（キーの書き方・重なり・エンジンの組み立て）。設定ファイルの値は、ここで一度だけ検査してから書く。
enum KeyKind: CaseIterable, Hashable {
    case listen, dictate, chat, shot
    /// 音声入力のあとに送るキーの候補（`dictateKey`・`dictateKey2`〜`4`）。**トリガーではない**（押している間だけ話すキーではなく、1 回押すキー：単独のキーも、よい）。
    case sendKey, sendKey2, sendKey3, sendKey4
    /// 操作のショートカット（キーの組み合わせだけ）：直前の入力の貼り直し・送るキーの切り替え。
    case pasteLast, cycleSend

    var title: String {
        switch self {
        case .listen: return tr("声で頼む")
        case .dictate: return tr("音声入力")
        case .chat: return tr("会話")
        case .shot: return tr("画面撮影")
        case .sendKey: return tr("送るキー 1")
        case .sendKey2: return tr("送るキー 2")
        case .sendKey3: return tr("送るキー 3")
        case .sendKey4: return tr("送るキー 4")
        case .pasteLast: return tr("直前の入力を貼り直す")
        case .cycleSend: return tr("送るキーを切り替える")
        }
    }

    /// 1 回押すキー（送るキーの候補）か。`false` は、キーの組み合わせ・長押しのトリガーの書き方（`HotKeySpec`）。
    var isStroke: Bool { Self.sendKeys.contains(self) }
    /// `HotKeySpec` の書き方のキー（押している間だけ話すキー・画面撮影・操作のショートカット）。
    var isTrigger: Bool { !isStroke }
    /// キーの組み合わせだけ使える、操作のショートカットか（長押しは、使えない）。
    var isAction: Bool { self == .shot || self == .pasteLast || self == .cycleSend }
    static var triggers: [KeyKind] { [.listen, .dictate, .chat, .shot] }
    static var sendKeys: [KeyKind] { [.sendKey, .sendKey2, .sendKey3, .sendKey4] }
    static var actions: [KeyKind] { [.pasteLast, .cycleSend] }

    var help: String {
        switch self {
        case .listen: return tr("押している間だけ話し、離すと、スキルを選んで実行します（既定：shift の長押し）")
        case .dictate: return tr("押している間だけ話し、離すと、文字にして、前面のアプリへ入力します（スキルは使いません）")
        case .chat: return tr("押している間だけ話し、離すと、会話として質問します（スキルは使いません。会話のウィンドウで、文字でも質問できます。実験）")
        case .shot: return tr("押して範囲を選び、そのあと声で頼みます（キーの組み合わせだけ）")
        case .sendKey: return tr("文字を入れたあとに押すキー（既定：Enter）。送信が ⌘Enter などのアプリに合わせられます")
        case .sendKey2, .sendKey3, .sendKey4: return tr("もう 1 つ、送るキーの候補（空なら、使わない）")
        case .pasteLast: return tr("直前の入力を、もう一度、前面のアプリへ入れます（キーの組み合わせだけ。メニューからも、できます）")
        case .cycleSend: return tr("送るキーの候補を、順に切り替えます（送らない → 送るキー 1 → 2 …）。キーの組み合わせだけ")
        }
    }

    /// 空にできる（使わない）か。声で頼むキーは、空にすると、既定（shift の長押し）。
    var isOptional: Bool { self != .listen }

    /// 空にしたときの、実際のキー（空のままの欄の表示と、「既定に戻す」）。
    var fallback: String? { self == .listen ? "shift" : (self == .sendKey ? "return" : nil) }

    var keyPath: WritableKeyPath<Settings, String?> {
        switch self {
        case .listen: return \.hotkey
        case .dictate: return \.dictateHotkey
        case .chat: return \.chatHotkey
        case .shot: return \.shotHotkey
        case .sendKey: return \.dictateKey
        case .sendKey2: return \.dictateKey2
        case .sendKey3: return \.dictateKey3
        case .sendKey4: return \.dictateKey4
        case .pasteLast: return \.pasteLastHotkey
        case .cycleSend: return \.dictateCycleHotkey
        }
    }

    /// 選びやすい候補（書き方は `HotKeySpec`・`KeyStroke`）。
    var presets: [String] {
        switch self {
        case .shot: return ["ctrl+opt+s", "ctrl+opt+space", "f5"]
        case .pasteLast: return ["opt+shift+v", "ctrl+opt+v", "f6"]
        case .cycleSend: return ["opt+shift+e", "ctrl+opt+e", "f7"]
        case .sendKey, .sendKey2, .sendKey3, .sendKey4: return ["return", "cmd+return", "shift+return", "opt+return", "ctrl+return", "tab"]
        default: return ["shift", "ctrl", "rshift", "rcmd", "ropt", "ctrl+opt+space", "f5"]
        }
    }
}

enum SettingsRules {
    /// キーの書き方と、ほかのキーとの重なりの問題（なければ `nil`）。`text` が空なら、そのキーを外した（または、既定に戻した）ものとして、重なりだけを見る。
    static func keyProblem(_ kind: KeyKind, text: String, in settings: Settings) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if kind.isStroke {   // 1 回押すキー：書き方だけ（トリガーとの重なりは、関係ない）
            if !trimmed.isEmpty, case let .failure(f) = KeyStroke.parse(trimmed) { return f.reason }
            return nil
        }
        var candidate = settings
        if trimmed.isEmpty {
            candidate[keyPath: kind.keyPath] = nil
        } else {
            if case let .failure(f) = HotKeySpec.parse(trimmed) { return f.reason }
            candidate[keyPath: kind.keyPath] = trimmed
        }
        guard case let .success(listen) = candidate.hotkeySpec else { return nil }   // すでに書かれている声で頼むキーが壊れている：その直しは、そのキーの欄で
        func spec(_ text: String?) -> HotKeySpec? { text.flatMap { try? HotKeySpec.parse($0).get() } }
        return KeyConflicts.message(listen: listen, dictate: spec(candidate.dictateHotkey), shot: spec(candidate.shotHotkey), chat: spec(candidate.chatHotkey),
                                    actions: [(KeyKind.pasteLast.title, spec(candidate.pasteLastHotkey)), (KeyKind.cycleSend.title, spec(candidate.dictateCycleHotkey))].compactMap { name, spec in spec.map { (name, $0) } })
    }

    // MARK: エンジン

    enum EngineKind: String, CaseIterable {
        case apple, ollama, openai
        var title: String {
            switch self {
            case .apple: return tr("Apple（この Mac の中。既定）")
            case .ollama: return tr("Ollama（この Mac のサーバー）")
            case .openai: return tr("OpenAI 互換（この Mac のサーバー）")
            }
        }
        var placeholder: String { self == .ollama ? "qwen3.5:4b" : tr("モデル名@ポート") }
    }

    /// 設定の文字列を、種類と、そのあとの部分に分ける（`ollama:qwen3.5:4b` → ollama・`qwen3.5:4b`）。
    static func splitEngine(_ text: String?) -> (kind: EngineKind, rest: String) {
        guard let text, !text.isEmpty, text != "apple" else { return (.apple, "") }
        if text.hasPrefix("ollama:") { return (.ollama, String(text.dropFirst("ollama:".count))) }
        if text.hasPrefix("openai:") { return (.openai, String(text.dropFirst("openai:".count))) }
        return (.apple, "")
    }

    static func engineText(kind: EngineKind, rest: String) -> String {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return kind == .apple ? "apple" : "\(kind.rawValue):\(trimmed)"
    }

    /// エンジンの書き方の問題（なければ `nil`）。クラウドのモデルは、拒否される（`Engine.parse`）。
    static func engineProblem(kind: EngineKind, rest: String) -> String? {
        if kind != .apple, rest.trimmingCharacters(in: .whitespaces).isEmpty { return tr("モデルの名前を入れてください") }
        do { _ = try Engine.parse(engineText(kind: kind, rest: rest)); return nil } catch { return "\(error)" }
    }
}
