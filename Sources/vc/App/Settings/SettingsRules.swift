import Foundation
import VCCore
import VCSkill
import VCSpeech

/// 設定画面の、画面から分けて確かめられる規則（キーの書き方・重なり・エンジンの組み立て）。設定ファイルの値は、ここで一度だけ検査してから書く。
enum KeyKind: CaseIterable, Hashable {
    case listen, dictate, chat, shot

    var title: String {
        switch self {
        case .listen: return "声で頼む"
        case .dictate: return "音声入力"
        case .chat: return "会話"
        case .shot: return "画面撮影"
        }
    }

    var help: String {
        switch self {
        case .listen: return "押している間だけ話し、離すと、スキルを選んで実行します（既定：shift の長押し）"
        case .dictate: return "押している間だけ話し、離すと、文字にして、前面のアプリへ入力します（スキルは使いません）"
        case .chat: return "押している間だけ話し、離すと、会話として質問します（スキルは使いません。実験）"
        case .shot: return "押して範囲を選び、そのあと声で頼みます（キーの組み合わせだけ）"
        }
    }

    /// 空にできる（使わない）か。声で頼むキーは、空にすると、既定（shift の長押し）。
    var isOptional: Bool { self != .listen }

    var keyPath: WritableKeyPath<Settings, String?> {
        switch self {
        case .listen: return \.hotkey
        case .dictate: return \.dictateHotkey
        case .chat: return \.chatHotkey
        case .shot: return \.shotHotkey
        }
    }

    /// 選びやすい候補（書き方は `HotKeySpec`）。
    var presets: [String] {
        switch self {
        case .shot: return ["ctrl+opt+s", "ctrl+opt+space", "f5"]
        default: return ["shift", "ctrl", "rshift", "rcmd", "ropt", "ctrl+opt+space", "f5"]
        }
    }
}

enum SettingsRules {
    /// キーの書き方と、ほかのキーとの重なりの問題（なければ `nil`）。`text` が空なら、そのキーを外した（または、既定に戻した）ものとして、重なりだけを見る。
    static func keyProblem(_ kind: KeyKind, text: String, in settings: Settings) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var candidate = settings
        if trimmed.isEmpty {
            candidate[keyPath: kind.keyPath] = nil
        } else {
            if case let .failure(f) = HotKeySpec.parse(trimmed) { return f.reason }
            candidate[keyPath: kind.keyPath] = trimmed
        }
        guard case let .success(listen) = candidate.hotkeySpec else { return nil }   // すでに書かれている声で頼むキーが壊れている：その直しは、そのキーの欄で
        func spec(_ text: String?) -> HotKeySpec? { text.flatMap { try? HotKeySpec.parse($0).get() } }
        return KeyConflicts.message(listen: listen, dictate: spec(candidate.dictateHotkey), shot: spec(candidate.shotHotkey), chat: spec(candidate.chatHotkey))
    }

    // MARK: エンジン

    enum EngineKind: String, CaseIterable {
        case apple, ollama, openai
        var title: String {
            switch self {
            case .apple: return "Apple（この Mac の中。既定）"
            case .ollama: return "Ollama（この Mac のサーバー）"
            case .openai: return "OpenAI 互換（この Mac のサーバー）"
            }
        }
        var placeholder: String { self == .ollama ? "qwen3.5:4b" : "モデル名@ポート" }
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
        if kind != .apple, rest.trimmingCharacters(in: .whitespaces).isEmpty { return "モデルの名前を入れてください" }
        do { _ = try Engine.parse(engineText(kind: kind, rest: rest)); return nil } catch { return "\(error)" }
    }
}
