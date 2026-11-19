import Foundation
import VCCore

/// 音声入力のあとに送るキーの、**切り替えられる候補**（設定 `dictateKey`・`dictateKey2`〜`4`・`dictateMode`）。
/// 候補は、先頭が「送らない」、続いて、設定されたキー（`dictateKey` は、なければ Enter。`dictateKey2`〜`4` は、空なら使わない）。
/// いま使う候補（`active`）は、`dictateMode`（候補の番号）。なければ、古い設定（`dictateEnter`）に従う：オン＝`dictateKey`・オフ＝送らない。
/// 切り替え（ショートカット・メニュー）は、**順に回る**（最後の次は、先頭の「送らない」）。**純粋**（画面・キーの送信を持たない）。
public struct DictateSendModes: Equatable, Sendable {
    public struct Mode: Equatable, Sendable {
        /// 送るキー。nil は、送らない。
        public let stroke: KeyStroke?
        /// 設定の書き方が読めなかった理由（読めないキーを、黙って Enter にしない）。
        public let problem: String?
        /// 画面に出す名前（「送らない」「Enter」「⌘Enter」…）。
        public var title: String { problem != nil ? tr("読めないキー") : (stroke?.displayName ?? tr("送らない")) }
    }

    public let modes: [Mode]
    public let active: Int

    public var current: Mode { modes[active] }

    /// 次の候補の番号（順に回る）。
    public var nextIndex: Int { (active + 1) % modes.count }

    public static let maxKeys = 4

    public init(settings: Settings) {
        func parsed(_ text: String?) -> Mode? {
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            switch KeyStroke.parse(text) {
            case let .success(stroke): return Mode(stroke: stroke, problem: nil)
            case let .failure(failure): return Mode(stroke: nil, problem: failure.reason)
            }
        }
        var list = [Mode(stroke: nil, problem: nil)]
        list.append(parsed(settings.dictateKey) ?? Mode(stroke: .enter, problem: nil))
        for text in [settings.dictateKey2, settings.dictateKey3, settings.dictateKey4] { if let mode = parsed(text) { list.append(mode) } }
        modes = list
        let wanted = settings.dictateMode ?? ((settings.dictateEnter ?? false) ? 1 : 0)
        active = min(max(wanted, 0), list.count - 1)
    }
}

extension Settings {
    /// 音声入力のあとに送るキーの候補と、いま使うもの。
    public var dictateSend: DictateSendModes { DictateSendModes(settings: self) }
}
