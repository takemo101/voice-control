import Foundation

/// `vc show --timeout <秒>`：この秒数のあとに、窓を閉じる（タイムアウト）。ここは、秒数の読み方だけ（**純粋**）。
/// 閉じるのは、**黙って**（残り時間は出さない）・**操作中でも**（マウスが上にあっても、文字を選んでいても）。
enum AutoClose {
    /// 上限（1 時間）。それより長く出しておくなら、指定しない（閉じるまで残る）ほうがよい。
    static let maxSeconds: TimeInterval = 3600

    /// 「15」「2.5」→ 秒。0 以下・数でない・上限を超える・無限・NaN は、nil。
    static func seconds(from text: String) -> TimeInterval? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0, value <= maxSeconds else { return nil }
        return value
    }
}
