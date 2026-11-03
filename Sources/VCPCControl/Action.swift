import Foundation

/// キー操作の選択肢（キーの組み合わせは、agent-desktop の `press` の表記）。組み込み（`all`）と、利用者が JSON で足したもの（`KeyBindingCatalog`）。
/// アプリを終了するもの（cmd+q 系）は、入れない。
public struct Shortcut: Sendable, Equatable {
    /// 順に押すキー（1 つが普通）。
    public let combos: [String]
    public let option: String
    /// ウィンドウ・タブを閉じる、など。確信度が高くても、声の「はい」を挟む。
    public let needsConfirmation: Bool
    /// 前面のアプリの名前に、これが含まれるときだけ候補にする（大文字小文字は無視）。`nil` はどのアプリでも。
    public let app: String?
    /// 発話がこの正規表現に一致するときだけ候補にする。`nil` は常に。
    public let when: String?

    /// 代表の表記（評価・ログ用）。複数なら「,」でつなぐ。
    public var combo: String { combos.joined(separator: ",") }

    public init(combos: [String], option: String, confirm: Bool = false, app: String? = nil, when: String? = nil) {
        self.combos = combos; self.option = option; needsConfirmation = confirm; self.app = app; self.when = when
    }

    init(_ combo: String, _ option: String, confirm: Bool = false) {
        self.init(combos: [combo], option: option, confirm: confirm)
    }

    public static let all: [Shortcut] = [
        .init("return", "リターン（決定・改行）"),
        .init("escape", "エスケープキー（Esc）"),
        .init("tab", "タブキー（次の入力欄へ）"),
        .init("space", "スペースキー"),
        .init("delete", "削除キー（1 文字消す）"),
        .init("up", "上矢印キー"), .init("down", "下矢印キー"), .init("left", "左矢印キー"), .init("right", "右矢印キー"),
        .init("cmd+c", "コピー"), .init("cmd+x", "切り取り"), .init("cmd+v", "ペースト（貼り付け）"),
        .init("cmd+a", "すべて選択"),
        .init("cmd+z", "直前の操作を元に戻す（アンドゥ）"), .init("cmd+shift+z", "やり直す"),
        .init("cmd+s", "保存"), .init("cmd+f", "検索"), .init("cmd+n", "新規作成"), .init("cmd+p", "印刷"),
        .init("cmd+t", "新しいタブを開く"), .init("cmd+w", "タブ・ウィンドウを閉じる", confirm: true),
        .init("cmd+leftbracket", "前のページへ戻る"), .init("cmd+rightbracket", "次のページへ進む"),
        .init("cmd+r", "再読み込み"), .init("cmd+l", "アドレスバーを選ぶ"),
        .init("cmd+comma", "設定を開く"),
    ]
}

public enum ScrollDirection: String, CaseIterable, Sendable {
    case up, down, left, right
    public var option: String {
        switch self {
        case .up: return "上へスクロール"
        case .down: return "下へスクロール"
        case .left: return "左へスクロール"
        case .right: return "右へスクロール"
        }
    }
}

/// 実行する 1 手。引数は、すべて決まっている。
public enum Step: Sendable, Equatable {
    case openApp(String)
    case click(UIElement)
    case type(text: String, into: UIElement)
    case press(Shortcut)
    case scroll(ScrollDirection, UIElement)
    case window(WindowAction, app: String)
    /// アプリの中（ブラウザなら、アドレスバー）で、文字を検索する。
    case search(String, app: String)
    /// 要素の状態を変える操作（チェック・開閉・空にする・フォーカス）。
    case element(ElementVerb, UIElement)
    /// アプリを終了する（`close-app`）。必ず確認する。
    case closeApp(String)

    public var summary: String {
        switch self {
        case .openApp(let name): return "open \(name)"
        case .click(let e): return "click \(e.ref) [\(e.option)]"
        case .type(let text, let e): return "type \(text.count) chars into \(e.ref) [\(e.option)]"   // 入れる文字は、ログに残さない
        case .press(let s): return "press \(s.combo)"
        case .scroll(let d, let e): return "scroll \(d.rawValue) \(e.ref) [\(e.option)]"
        case .window(let a, let app): return "\(a.rawValue) window of \(app)"
        case .search(let q, let app): return "search \(q.count) chars in \(app)"
        case .element(let v, let e): return "\(v.rawValue) \(e.ref) [\(e.option)]"
        case .closeApp(let name): return "close-app \(name)"
        }
    }
}

/// 前面のアプリのウィンドウの操作。
public enum WindowAction: String, CaseIterable, Sendable {
    case maximize, minimize, restore
    public var option: String {
        switch self {
        case .maximize: return "ウィンドウを最大化する"
        case .minimize: return "ウィンドウを最小化する"
        case .restore: return "ウィンドウの大きさを元に戻す"
        }
    }
}

/// 要素に対する、状態を変える操作。agent-desktop のコマンドと、要素が公開する操作（`available_actions`）の対応で決まる：**その操作を持つ要素にだけ、候補を作る**。
public enum ElementVerb: String, CaseIterable, Sendable {
    case check, uncheck, toggle, expand, collapse, clear, focus

    /// 要素が持つべき `available_actions`。
    var requiredAction: String {
        switch self {
        case .check, .uncheck, .toggle: return "Toggle"
        case .expand: return "Expand"
        case .collapse: return "Collapse"
        case .clear: return "SetValue"
        case .focus: return "SetFocus"
        }
    }

    /// 候補にする要素（`focus`・`clear` は、候補が増えすぎないよう、文字入力欄だけ）。
    func applies(to e: UIElement) -> Bool {
        guard e.actions.contains(requiredAction), !e.name.isEmpty || self == .focus else { return false }
        switch self {
        // スイッチ（switch）は、agent-desktop の check・uncheck・toggle が「button の役割は非対応」で失敗した（実測）ので、click に任せる。
        case .check, .uncheck, .toggle: return ["checkbox", "radiobutton"].contains(e.role)
        case .expand, .collapse: return true
        case .clear, .focus: return UIElement.textRoles.contains(e.role)
        }
    }

    func label(for e: UIElement) -> String {
        let name = e.name.isEmpty ? e.role : e.name
        switch self {
        case .check: return "チェックを入れる（オンにする）: \(name)"
        case .uncheck: return "チェックを外す（オフにする）: \(name)"
        case .toggle: return "切り替える（オン・オフ）: \(name)"
        case .expand: return "開く（展開する）: \(name)"
        case .collapse: return "閉じる（折りたたむ）: \(name)"
        case .clear: return "入力欄を空にする: \(name)"
        case .focus: return "カーソルを移す: \(name)"
        }
    }

    /// 入力欄の中身を消すので、必ず確認する。
    var needsConfirmation: Bool { self == .clear }
}
