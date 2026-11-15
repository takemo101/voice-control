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

    public let kind: Kind
    public let detail: String

    public init(_ kind: Kind, _ detail: String) { self.kind = kind; self.detail = detail }

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
