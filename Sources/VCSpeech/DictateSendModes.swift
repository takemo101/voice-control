import Foundation
import VCCore

/// 音声入力のあとに送るキーの、**切り替えられる候補**（設定 `dictateKeys`〔なければ `dictateKey`〕・`dictateMode`）。
/// 候補は、先頭が「送らない」、続いて、設定されたキー（`Settings.sendKeyList`。最大 `maxKeys`）。
/// いま使う候補（`active`）は、`dictateMode`（候補の番号）。なければ、古い設定（`dictateEnter`）に従う：オン＝最初のキー・オフ＝送らない。
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

    /// 登録できるキーの数（候補が、増えすぎて、切り替えに迷わないように）。
    public static let maxKeys = 8

    public init(settings: Settings) {
        var list = [Mode(stroke: nil, problem: nil)]
        for text in settings.sendKeyList where !text.trimmingCharacters(in: .whitespaces).isEmpty {
            switch KeyStroke.parse(text) {
            case let .success(stroke): list.append(Mode(stroke: stroke, problem: nil))
            case let .failure(failure): list.append(Mode(stroke: nil, problem: failure.reason))   // 読めないキーを、黙って Enter にしない
            }
        }
        modes = list
        let wanted = settings.dictateMode ?? ((settings.dictateEnter ?? false) ? 1 : 0)
        active = min(max(wanted, 0), list.count - 1)
    }
}

extension Settings {
    /// 音声入力のあとに送るキーの候補と、いま使うもの。
    public var dictateSend: DictateSendModes { DictateSendModes(settings: self) }
}
