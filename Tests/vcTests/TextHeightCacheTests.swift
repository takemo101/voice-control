import CoreGraphics
import Testing
@testable import vc

/// 文章の高さの記憶：同じ幅・同じ文字は、測り直さない。幅か文字が違えば、測り直す。
@Suite struct TextHeightCacheTests {
    @Test func theSameWidthAndTextAreMeasuredOnceAndOthersAreMeasuredAgain() {
        let text = "測る文章 \(#function)"
        var calls = 0
        func measure(_ width: CGFloat, _ string: String, _ result: CGFloat) -> CGFloat { TextHeightCache.height(width: width, text: string) { calls += 1; return result } }
        #expect(measure(400, text, 120) == 120 && calls == 1)
        #expect(measure(400, text, 999) == 120 && calls == 1)          // 同じ：記憶から（測らない）
        #expect(measure(401, text, 130) == 130 && calls == 2)          // 幅が違う：測る
        #expect(measure(400, text + "。", 140) == 140 && calls == 3)   // 文字が違う：測る
    }

    @Test func anUnboundedOrNotANumberWidthDoesNotCrashAndIsRememberedToo() {
        // SwiftUI は、理想の幅を、`.infinity` で問い合わせる（`Int` にして、クラッシュした）
        var calls = 0
        let text = "無限の幅 \(#function)"
        func measure(_ width: CGFloat) -> CGFloat { TextHeightCache.height(width: width, text: text) { calls += 1; return 50 } }
        #expect(measure(.infinity) == 50 && measure(.infinity) == 50 && calls == 1)
        #expect(measure(.nan) == 50)
    }
}
