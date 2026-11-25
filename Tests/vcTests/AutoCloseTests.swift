import Foundation
import Testing
@testable import vc

/// `vc show --timeout` の秒数の読み方：0 以下・数でない・上限超え・無限は、受けない（閉じない窓・即座に閉じる窓を作らない）。
@Suite struct AutoCloseTests {
    @Test func positiveFiniteSecondsWithinTheLimitAreAccepted() {
        #expect(AutoClose.seconds(from: "15") == 15 && AutoClose.seconds(from: " 2.5 ") == 2.5 && AutoClose.seconds(from: "3600") == 3600)
    }

    @Test func zeroNegativeJunkInfiniteAndOverLimitAreRefused() {
        for text in ["0", "-3", "abc", "", "3601", "inf", "nan", "1e9"] { #expect(AutoClose.seconds(from: text) == nil, "\(text)") }
    }
}
