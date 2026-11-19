import Testing
import VCCore
@testable import VCSpeech

/// 音声入力のあとに送るキーの候補：先頭は「送らない」。古い設定（`dictateEnter`）のまま使える。切り替えは、順に回る。
@Suite struct DictateSendModesTests {
    @Test func anUntouchedSettingIsOffAndEnterIsTheOnlyKey() {
        let modes = Settings().dictateSend
        #expect(modes.modes.map { $0.stroke?.description } == [nil, "return"] && modes.active == 0 && modes.current.stroke == nil)
        var legacyOn = Settings(); legacyOn.dictateEnter = true; legacyOn.dictateKey = "cmd+return"
        #expect(legacyOn.dictateSend.active == 1 && legacyOn.dictateSend.current.stroke?.description == "cmd+return")   // 古い設定は、そのまま
    }

    @Test func extraKeysJoinInOrderAndTheModeNumberPicksOne() {
        var settings = Settings(); settings.dictateKey = "return"; settings.dictateKey2 = "cmd+return"; settings.dictateKey3 = ""; settings.dictateKey4 = "tab"
        settings.dictateMode = 3
        let modes = settings.dictateSend
        #expect(modes.modes.count == 4)   // 送らない・Enter・⌘Enter・Tab（空の 3 番は、使わない）
        #expect(modes.current.stroke?.description == "tab" && modes.active == 3)
        settings.dictateMode = 99; #expect(settings.dictateSend.active == 3)   // 範囲外は、収める
        settings.dictateMode = -4; #expect(settings.dictateSend.active == 0)
    }

    @Test func switchingCyclesAndWrapsToNotSending() {
        var settings = Settings(); settings.dictateKey2 = "shift+return"; settings.dictateMode = 0
        var seen: [String] = []
        for _ in 0..<4 {
            let modes = settings.dictateSend
            seen.append(modes.current.stroke?.description ?? "-")
            settings.dictateMode = modes.nextIndex
        }
        #expect(seen == ["-", "return", "shift+return", "-"])   // 最後の次は、先頭へ
    }

    @Test func anUnreadableKeyIsReportedNotTurnedIntoEnter() {
        var settings = Settings(); settings.dictateKey2 = "no-such-key"; settings.dictateMode = 2
        let mode = settings.dictateSend.current
        #expect(mode.stroke == nil && mode.problem != nil)
    }
}
