import AppKit
import Testing
import VCCore
@testable import vc

/// 画面の文字の大きさ：倍率の計算と、Markdown の本文への反映。
@MainActor @Suite(.serialized) struct UIScaleTests {
    @Test func theFactorIsRelativeToTheStandardAndClampedToTheRange() {
        #expect(UIScale.factor(for: 13) == 1)
        #expect(UIScale.factor(for: 26) == UIScale.factor(for: 24))        // 範囲の上端（24）まで
        #expect(UIScale.factor(for: 0) == CGFloat(10) / 13)                // 下端（10）まで
        #expect(UIScale.factor(for: -5) == CGFloat(10) / 13)
        #expect(abs(UIScale.factor(for: 19) - 19.0 / 13) < 0.0001)
        #expect(UIScale.clamp(13) == 13 && UIScale.clamp(99) == 24 && UIScale.clamp(1) == 10)
    }

    @Test func aSettingOutsideTheRangeOrAbsentFallsBackSafely() {
        var settings = Settings()
        #expect(settings.fontSize == nil)                                  // なければ、標準
        settings.fontSize = 18
        #expect(UIScale.clamp(settings.fontSize ?? UIScale.standard) == 18)
        settings.fontSize = 400
        #expect(UIScale.clamp(settings.fontSize ?? UIScale.standard) == 24)   // 壊れた値は、端に寄せる
    }

    @Test func theMarkdownBodyFollowsTheScaleAndTheCurrentSizeIsReadableFromAnyThread() {
        let original = UIScale.shared.size
        defer { UIScale.shared.apply(original) }
        func bodySize() -> CGFloat {
            let text = MarkdownRenderer.render("こんにちは")
            return (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }
        UIScale.shared.apply(13)
        let standard = bodySize()
        #expect(standard == 15)                                            // 標準の本文は 15（変えていない）
        UIScale.shared.apply(26)                                           // 範囲の上端（24）に寄る
        #expect(abs(bodySize() - 15 * UIScale.factor(for: 24)) < 0.01)
        #expect(UIScale.currentSize == 24 && abs(UIScale.currentFactor - 24.0 / 13) < 0.0001)   // 写しも、同じ
        UIScale.shared.apply(10)
        #expect(bodySize() < standard)                                     // 小さくもなる
    }
}
