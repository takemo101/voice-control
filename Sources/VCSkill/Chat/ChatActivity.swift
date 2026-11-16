import Foundation

/// 会話のエージェントが、いましていること（道具の呼び出し）：実行したコマンド・検索・開いたページ・読んだ／書いたファイルなど。画面に出す（何が実行されたかを、利用者が見られるように）。
/// 種類（`Kind`）と中身（`detail`）を、別々に持つ：表示（アイコン）と、「何かを変えたか」の判定は、種類で行い、文字の先頭を読まない。
public struct ChatActivity: Equatable, Sendable {
    public enum Kind: Sendable {
        case run, search, fetch, read, write, list, find, other

        /// 画面に出す、短い名前。
        public var label: String {
            switch self {
            case .run: return "実行"
            case .search: return "検索"
            case .fetch: return "取得"
            case .read: return "読む"
            case .write: return "書く"
            case .list: return "一覧"
            case .find: return "探す"
            case .other: return ""
            }
        }
    }

    /// 操作の結果（コマンドの出力・ファイルの差分）。**画面に出すだけ**（会話の記録・ログ・ファイルには、残さない）。
    public struct Output: Equatable, Sendable {
        /// 画面に出す、行数と文字数の上限（多すぎる出力で、画面が重くならないように）。
        public static let maxLines = 60
        public static let maxCharacters = 6000
        public let text: String
        /// 差分（`+`・`-` の行）か。色づけに使う。
        public let isDiff: Bool

        public init(text: String, isDiff: Bool = false) {
            var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            while lines.last?.isEmpty == true { lines.removeLast() }
            var clipped = false
            if lines.count > Self.maxLines { clipped = true; lines = Array(lines.prefix(Self.maxLines)) }
            var joined = lines.joined(separator: "\n")
            if joined.count > Self.maxCharacters { clipped = true; joined = String(joined.prefix(Self.maxCharacters)) }
            self.text = joined + (clipped ? "\n…（長いので、ここまで）" : "")
            self.isDiff = isDiff
        }
    }

    public let kind: Kind
    public let detail: String
    /// 同じ操作の、あとからの更新（結果が届いた）を、見分ける番号（エージェントのツール呼び出しの番号）。同じ番号の操作は、置き換える。
    public let id: String?
    public let output: Output?

    public init(_ kind: Kind, _ detail: String, id: String? = nil, output: Output? = nil) { self.kind = kind; self.detail = detail; self.id = id; self.output = output }

    /// 同じ操作に、番号と結果を付けたもの。
    public func with(id: String?, output: Output?) -> ChatActivity { ChatActivity(kind, detail, id: id, output: output) }

    public static func run(_ detail: String) -> ChatActivity { ChatActivity(.run, detail) }
    public static func search(_ detail: String) -> ChatActivity { ChatActivity(.search, detail) }
    public static func fetch(_ detail: String) -> ChatActivity { ChatActivity(.fetch, detail) }
    public static func read(_ detail: String) -> ChatActivity { ChatActivity(.read, detail) }
    public static func write(_ detail: String) -> ChatActivity { ChatActivity(.write, detail) }
    public static func list(_ detail: String) -> ChatActivity { ChatActivity(.list, detail) }
    public static func find(_ detail: String) -> ChatActivity { ChatActivity(.find, detail) }
    public static func other(_ detail: String) -> ChatActivity { ChatActivity(.other, detail) }

    /// 画面に出す 1 行（例：「実行: ls -la」）。
    public var text: String { kind == .other ? detail : "\(kind.label): \(detail)" }

    /// ファイルを書く・コマンドを実行する（Mac の中を、変えうる）操作か。
    public var changesSomething: Bool { kind == .run || kind == .write }
}

/// いまの操作を、知らせる（道具を呼ぶスレッドから呼ばれる）。
public typealias ActivityHandler = @Sendable (ChatActivity) -> Void
