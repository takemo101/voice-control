import Testing
@testable import vc

/// 撮ったスクリーンショットの、残り時間の表示：切り上げ・0 の境界・過ぎたあと。
@Suite struct ImageExpiryTests {
    @Test func showsRemainingTimeRoundedUpToTheSecond() {
        #expect(ImageExpiry.text(remaining: 180).hasSuffix("残り 3:00"))
        #expect(ImageExpiry.text(remaining: 95.2).hasSuffix("残り 1:36"))
        #expect(ImageExpiry.text(remaining: 0.4).hasSuffix("残り 0:01"))   // 0 になるまで、「残り」と出す
    }

    @Test func tellsToRetakeOnceTheTimeIsUp() {
        for remaining in [0, -1, -500] as [Double] { #expect(ImageExpiry.text(remaining: remaining).contains("撮り直してください")) }
    }
}
