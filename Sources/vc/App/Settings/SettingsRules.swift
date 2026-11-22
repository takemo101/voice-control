import Foundation
import VCCore
import VCSkill
import VCSpeech

/// 設定画面の、画面から分けて確かめられる規則（キーの書き方・重なり・エンジンの組み立て）。設定ファイルの値は、ここで一度だけ検査してから書く。
enum KeyKind: Hashable {
    case listen, dictate, chat, shot
    /// 音声入力のあとに送るキー（一覧の `index` 番目。`Settings.sendKeyList`）。**トリガーではない**（押している間だけ話すキーではなく、1 回押すキー：単独のキーも、よい）。一覧の長さ以上の番号は、「これから足す」キー。
    case sendKey(Int)
    /// 操作のショートカット（キーの組み合わせだけ）：直前の入力の貼り直し・送るキーの切り替え。
    case pasteLast, cycleSend

    /// 設定ウィンドウの欄が 1 つずつある、固定のキー（送るキーは、一覧で、足し引きする）。
    static var fixed: [KeyKind] { [.listen, .dictate, .chat, .shot, .pasteLast, .cycleSend] }
    static var triggers: [KeyKind] { [.listen, .dictate, .chat, .shot] }

    var title: String {
        switch self {
        case .listen: return tr("声で頼む")
        case .dictate: return tr("音声入力")
        case .chat: return tr("会話")
        case .shot: return tr("画面撮影")
        case let .sendKey(index): return tr("キー \(index + 1)")
        case .pasteLast: return tr("直前の入力を貼り直す")
        case .cycleSend: return tr("送るキーを切り替える")
        }
    }

    /// 1 回押すキー（送るキー）か。`false` は、キーの組み合わせ・長押しのトリガーの書き方（`HotKeySpec`）。
    var isStroke: Bool { if case .sendKey = self { return true } else { return false } }
    /// `HotKeySpec` の書き方のキー（押している間だけ話すキー・画面撮影・操作のショートカット）。
    var isTrigger: Bool { !isStroke }
    /// キーの組み合わせだけ使える、操作のショートカットか（長押しは、使えない）。
    var isAction: Bool { self == .shot || self == .pasteLast || self == .cycleSend }

    var help: String? {
        switch self {
        case .listen: return tr("押している間だけ話し、離すと、スキルを選んで実行します（既定：shift の長押し）")
        case .dictate: return tr("押している間だけ話し、離すと、文字にして、前面のアプリへ入力します（スキルは使いません）")
        case .chat: return tr("押している間だけ話し、離すと、会話として質問します（スキルは使いません。会話のウィンドウで、文字でも質問できます。実験）")
        case .shot: return tr("押して範囲を選び、そのあと声で頼みます（キーの組み合わせだけ）")
        case .sendKey: return nil
        case .pasteLast: return tr("直前の入力を、もう一度、前面のアプリへ入れます（キーの組み合わせだけ。メニューからも、できます）")
        case .cycleSend: return tr("送るキーの候補を、順に切り替えます（送らない → キー 1 → 2 …）。キーの組み合わせだけ。メニューからも、できます")
        }
    }

    /// 空にできる（使わない）か。声で頼むキーは、空にすると、既定（shift の長押し）。送るキーは、一覧から外す。
    var isOptional: Bool { self != .listen && !isStroke }

    /// 空にしたときの、実際のキー（空のままの欄の表示と、「既定に戻す」）。
    var fallback: String? { self == .listen ? "shift" : nil }

    /// 設定に書かれている書き方（なければ nil）。
    func value(in settings: Settings) -> String? {
        switch self {
        case .listen: return settings.hotkey
        case .dictate: return settings.dictateHotkey
        case .chat: return settings.chatHotkey
        case .shot: return settings.shotHotkey
        case let .sendKey(index): let list = settings.sendKeyList; return list.indices.contains(index) ? list[index] : nil
        case .pasteLast: return settings.pasteLastHotkey
        case .cycleSend: return settings.dictateCycleHotkey
        }
    }

    /// 設定へ書く。`nil`・空は、外す（送るキーは、一覧から取る。一覧の末尾の次の番号は、足す）。送るキーは、一覧（`dictateKeys`）に書き、古い `dictateKey` は、外す。
    func set(_ text: String?, in settings: inout Settings) {
        let value = text.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .listen: settings.hotkey = value
        case .dictate: settings.dictateHotkey = value
        case .chat: settings.chatHotkey = value
        case .shot: settings.shotHotkey = value
        case let .sendKey(index):
            var list = settings.sendKeyList
            if list.indices.contains(index) {
                if let value { list[index] = value } else { list.remove(at: index) }
            } else if let value { list.append(value) }
            settings.dictateKeys = list
            settings.dictateKey = nil
        case .pasteLast: settings.pasteLastHotkey = value
        case .cycleSend: settings.dictateCycleHotkey = value
        }
    }

    /// 選びやすい候補（書き方は `HotKeySpec`・`KeyStroke`）。
    var presets: [String] {
        switch self {
        case .shot: return ["ctrl+opt+s", "ctrl+opt+space", "f5"]
        case .pasteLast: return ["opt+shift+v", "ctrl+opt+v", "f6"]
        case .cycleSend: return ["opt+shift+e", "ctrl+opt+e", "f7"]
        case .sendKey: return ["return", "cmd+return", "shift+return", "opt+return", "ctrl+return", "tab"]
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
            kind.set(nil, in: &candidate)
        } else {
            if case let .failure(f) = HotKeySpec.parse(trimmed) { return f.reason }
            kind.set(trimmed, in: &candidate)
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
            case .openai: return tr("OpenAI 互換（この Mac・LAN のサーバー）")
            }
        }
        var placeholder: String { self == .ollama ? "qwen3.5:4b" : "qwen3-4b" }
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

    // MARK: OpenAI 互換：モデルの名前と、エンドポイント（入力欄は、2 つに分ける。保存する形は `<モデル>@<場所>` のまま）

    /// `<モデル>@<場所>` を、モデルの名前と、場所に分ける（最後の `@` で。`@` がなければ、全部がモデル）。
    static func splitOpenAI(_ rest: String) -> (model: String, endpoint: String) {
        guard let at = rest.lastIndex(of: "@") else { return (rest, "") }
        return (String(rest[..<at]), String(rest[rest.index(after: at)...]))
    }

    /// 入力されたエンドポイントを、`<ポート>` か `<ホスト>:<ポート>` にする：`http://` と、終わりの `/`・`/v1` は、落とす（`http://192.168.1.5:8080/v1` を、そのまま貼れる）。
    /// `https://` は、使えない（暗号化の通信には、未対応）。
    static func normalizeEndpoint(_ text: String) -> (value: String, problem: String?) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("https://") { return (value, tr("https:// は使えません（http:// だけ。暗号化された通信には、未対応です）")) }
        if value.lowercased().hasPrefix("http://") { value = String(value.dropFirst("http://".count)) }
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix("/v1") { value = String(value.dropLast(3)) }
        while value.hasSuffix("/") { value.removeLast() }
        return (value, nil)
    }

    /// 2 つの入力欄から、保存する形（`<モデル>@<場所>`）にする。
    static func openAIRest(model: String, endpoint: String) -> String {
        model.trimmingCharacters(in: .whitespaces) + "@" + normalizeEndpoint(endpoint).value
    }

    /// OpenAI 互換のエンジンの、サーバーの場所（書き方が正しいときだけ。APIキーの鍵・LAN の許可の鍵）。
    static func engineServer(kind: EngineKind, rest: String) -> ServerAddress? {
        guard kind == .openai, case let .openAI(_, server)? = try? Engine.parse(engineText(kind: kind, rest: rest)) else { return nil }   // try?: 書き方が違えば、場所は、なし（問題は、`engineProblem` が出す）
        return server
    }

    /// エンジンの書き方の問題（なければ `nil`）。クラウドのモデルは、拒否される（`Engine.parse`）。
    static func engineProblem(kind: EngineKind, rest: String) -> String? {
        if kind != .apple, rest.trimmingCharacters(in: .whitespaces).isEmpty { return tr("モデルの名前を入れてください") }
        if kind == .openai {
            let parts = splitOpenAI(rest)
            if parts.model.trimmingCharacters(in: .whitespaces).isEmpty { return tr("モデルの名前を入れてください") }
            if parts.endpoint.isEmpty { return tr("エンドポイントを入れてください（例：8000・192.168.1.5:8080）") }
        }
        do { _ = try Engine.parse(engineText(kind: kind, rest: rest)); return nil } catch { return "\(error)" }
    }
}
