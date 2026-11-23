import Foundation
import VCCore
import VCSkill

/// 設定ウィンドウで選ぶ、エンジンの種類。
enum EngineKind: String {
    case apple, ollama, openai

    /// モデル欄の、入力の見本。
    var placeholder: String { self == .ollama ? "qwen3.5:4b" : "qwen3-4b" }

    /// モデルのサーバーの種類（Apple は、なし）。
    var serverKind: ModelServerKind? {
        switch self {
        case .apple: return nil
        case .ollama: return .ollama
        case .openai: return .openAI
        }
    }
}

/// **エンジンの入力（設定ウィンドウ）の、状態と規則**。画面（`SettingsModel`・`ModelsPage`）から分けて、**設定ファイルへ書かずに**、状態の移り変わりを確かめられる。
/// - 保存する形は、`engine`（`ollama:<モデル>[@<場所>]`・`openai:<モデル>@<場所>`）と、種類ごとの最後の入力（`engineRests`）。
/// - **種類ごとに、入力は別々**：切り替えると、出ていく側を覚え、入る側の覚えていた入力を出す。
/// - **許可していない LAN のサーバーは、保存しない**（`persistedEngine`）。
struct EngineDraft: Equatable {
    private(set) var kind: EngineKind
    /// `<モデル>@<場所>`（Ollama は、場所がなければ `<モデル>`）。入力欄の中身から、組み立てる。
    private(set) var rest: String
    /// エンドポイントの入力欄（貼り付けたままの形：`http://…/v1` も、そのまま見せる）。
    private(set) var endpoint: String
    /// 書き方の問題（なければ nil）。まだ何も入れていない種類には、出さない。
    private(set) var problem: String?
    /// 種類ごとの、最後に使った入力（画面の中。有効なものだけ、設定にも保存する）。
    private var remembered: [String: String]

    init(settings: Settings) {
        let active = EngineRules.splitEngine(settings.engine)
        kind = active.kind
        rest = active.rest
        endpoint = EngineRules.splitModelEndpoint(active.rest).endpoint
        remembered = settings.engineRests ?? [:]
    }

    var model: String { EngineRules.splitModelEndpoint(rest).model }

    /// サーバーの場所（書き方が正しいとき。Ollama は、省くと既定）。
    var server: ServerAddress? { EngineRules.server(kind: kind, rest: rest) }

    /// 保存してよい入力か（Apple でなく、何か入っていて、書き方が正しい）。
    var isComplete: Bool { kind != .apple && !rest.isEmpty && problem == nil }

    // MARK: 変更

    /// 種類を切り替える：出ていく側の入力を覚え、入る側の入力を出す（覚えていなければ、設定の `engine` が、その種類のとき、それ。なければ、空）。
    mutating func switchKind(_ new: EngineKind, settings: Settings) {
        guard new != kind else { return }
        if kind != .apple { remembered[kind.rawValue] = rest }
        let restored = remembered[new.rawValue] ?? EngineRules.rest(for: new, engine: settings.engine, remembered: settings.engineRests)
        kind = new
        rest = restored
        endpoint = EngineRules.splitModelEndpoint(restored).endpoint
        problem = new == .apple || restored.isEmpty ? nil : EngineRules.problem(kind: new, rest: restored)
    }

    /// モデルの名前・エンドポイントの入力（片方だけ、渡す）。保存する形にして、問題を調べる。
    mutating func edit(model name: String? = nil, endpoint newEndpoint: String? = nil) {
        if let newEndpoint { endpoint = newEndpoint }
        rest = EngineRules.modelRest(kind: kind, model: name ?? model, endpoint: endpoint)
        problem = EngineRules.problem(kind: kind, rest: rest)
        // `https://` などは、保存する形にできない：理由を、はっきり出す
        if let scheme = EndpointText.canonical(endpoint).unsupportedScheme { problem = Engine.ParseError.invalidScheme(scheme).description }
        if kind != .apple, problem == nil { remembered[kind.rawValue] = rest }
    }

    // MARK: 保存する形

    /// 設定ファイルへ保存する `engine`。**許可していない LAN のサーバーは、保存しない**（nil＝Apple のモデル）：保存すると、アプリの再読み込みが「許可していません」の失敗になる。入力が完全でないときも、nil。
    func persistedEngine(approved: String?) -> String? {
        guard isComplete else { return nil }
        return EngineRules.persistedEngine(kind: kind, rest: rest, approved: approved)
    }

    /// 設定へ保存する、種類ごとの入力（書き方が正しいものだけ）。`base`：すでに保存してあるもの。
    func persistedRests(base: [String: String]?) -> [String: String]? {
        var out = base ?? [:]
        for (key, value) in remembered {
            guard let kind = EngineKind(rawValue: key), EngineRules.problem(kind: kind, rest: value) == nil else { continue }
            out[key] = value
        }
        return out.isEmpty ? nil : out
    }
}

/// エンジンの入力の、**文字の規則**（純粋）。
enum EngineRules {
    /// 設定の文字列を、種類と、そのあとの部分に分ける（`ollama:qwen3.5:4b` → ollama・`qwen3.5:4b`）。
    static func splitEngine(_ text: String?) -> (kind: EngineKind, rest: String) {
        guard let text, !text.isEmpty, text != "apple" else { return (.apple, "") }
        for kind in [EngineKind.ollama, .openai] where text.hasPrefix(kind.rawValue + ":") { return (kind, String(text.dropFirst(kind.rawValue.count + 1))) }
        return (.apple, "")
    }

    static func engineText(kind: EngineKind, rest: String) -> String {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return kind == .apple ? "apple" : "\(kind.rawValue):\(trimmed)"
    }

    /// `<モデル>@<場所>` を、モデルの名前と、場所に分ける（最後の `@` で。`@` がなければ、全部がモデル）。
    static func splitModelEndpoint(_ rest: String) -> (model: String, endpoint: String) {
        guard let at = rest.lastIndex(of: "@") else { return (rest, "") }
        return (String(rest[..<at]), String(rest[rest.index(after: at)...]))
    }

    /// 2 つの入力欄から、保存する形（`<モデル>@<場所>`）にする。入力のエンドポイントは、保存する形にそろえる（`EndpointText.canonical`）。**Ollama は、場所が空なら、`<モデル>` だけ**（既定の場所）。
    static func modelRest(kind: EngineKind, model: String, endpoint: String) -> String {
        let name = model.trimmingCharacters(in: .whitespaces)
        let place = EndpointText.canonical(endpoint).value
        return kind == .ollama && place.isEmpty ? name : name + "@" + place
    }

    /// サーバーの場所（書き方が正しいときだけ）。Ollama は、場所を省くと、既定。
    static func server(kind: EngineKind, rest: String) -> ServerAddress? {
        guard kind != .apple, let engine = try? Engine.parse(engineText(kind: kind, rest: rest)) else { return nil }   // try?: 書き方が違えば、場所は、なし（問題は、`problem` が出す）
        return engine.server
    }

    /// 種類を切り替えたとき、その種類の入力欄に出す内容：**使っているエンジンが、その種類なら、それ**。そうでなければ、その種類で**最後に使った入力**（`remembered`）。なければ、空。
    static func rest(for kind: EngineKind, engine: String?, remembered: [String: String]?) -> String {
        guard kind != .apple else { return "" }
        let active = splitEngine(engine)
        if active.kind == kind { return active.rest }
        return remembered?[kind.rawValue] ?? ""
    }

    /// 保存する `engine` の文字。LAN のサーバーは、その場所を許可している（`approved`）ときだけ。それ以外は nil（Apple）。
    static func persistedEngine(kind: EngineKind, rest: String, approved: String?) -> String? {
        let text = engineText(kind: kind, rest: rest)
        if text == "apple" { return nil }
        if let server = server(kind: kind, rest: rest), !server.isApproved(by: approved) { return nil }
        return text
    }

    /// エンジンの書き方の問題（なければ `nil`）。クラウドのモデルは、拒否される（`Engine.parse`）。
    static func problem(kind: EngineKind, rest: String) -> String? {
        if kind != .apple, rest.trimmingCharacters(in: .whitespaces).isEmpty { return tr("モデルの名前を入れてください") }
        if kind != .apple, splitModelEndpoint(rest).model.trimmingCharacters(in: .whitespaces).isEmpty { return tr("モデルの名前を入れてください") }
        if kind == .openai, splitModelEndpoint(rest).endpoint.isEmpty { return tr("エンドポイントを入れてください（例：8000・192.168.1.5:8080）") }   // OpenAI 互換は、既定の場所がない
        do { _ = try Engine.parse(engineText(kind: kind, rest: rest)); return nil } catch { return "\(error)" }
    }
}
