import Foundation

public extension Step {
    /// 読み上げる、操作の説明（確認の問いかけに使う）。入れる文字は、読み上げない。
    var spoken: String {
        switch self {
        case .openApp(let name): return "\(name)を開きます"
        case .click(let e): return "「\(e.name)」を押します"
        case .type(_, let e): return "\(e.name.isEmpty ? "入力欄" : "「\(e.name)」")に文字を入力します"
        case .press(let s): return "\(s.option)をします"
        case .scroll(let d, _): return d.option + "します"
        case .window(let a, _): return a.option + "します"
        case .search(_, let app): return "\(app)で検索します"
        case .element(let v, let e): return "\(v.label(for: e))を実行します"
        case .closeApp(let name): return "\(name)を終了します"
        }
    }
}
