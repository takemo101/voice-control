import Testing
import VCCore
@testable import VCSpeech

/// 音声入力のあとに送るキーの候補：先頭は「送らない」。古い設定（`dictateEnter`・`dictateKey`）のまま使える。切り替えは、順に回る。
@Suite struct DictateSendModesTests {
    @Test func anUntouchedSettingIsOffAndEnterIsTheOnlyKey() {
        let modes = Settings().dictateSend
        #expect(modes.modes.map { $0.stroke?.description } == [nil, "return"] && modes.active == 0 && modes.current.stroke == nil)
        var legacyOn = Settings(); legacyOn.dictateEnter = true; legacyOn.dictateKey = "cmd+return"
        #expect(legacyOn.dictateSend.modes.map { $0.stroke?.description } == [nil, "cmd+return"])      // 古い設定は、そのまま
        #expect(legacyOn.dictateSend.active == 1 && legacyOn.dictateSend.current.stroke?.description == "cmd+return")
    }

    @Test func theKeyListReplacesTheLegacyKeyAndAnEmptyListLeavesOnlyNotSending() {
        var settings = Settings(); settings.dictateKey = "tab"; settings.dictateKeys = ["return", "cmd+return"]
        #expect(settings.dictateSend.modes.map { $0.stroke?.description } == [nil, "return", "cmd+return"])   // 一覧が、あれば、古い `dictateKey` は、使わない
        settings.dictateKeys = []
        #expect(settings.dictateSend.modes.count == 1 && settings.dictateSend.current.stroke == nil)          // 全部外すと、Enter に戻らず、送らない
        settings.dictateKeys = ["return", "  ", "shift+return"]
        #expect(settings.dictateSend.modes.count == 3)                                                         // 空の項目は、数えない
    }

    @Test func theModeNumberPicksOneAndIsClamped() {
        var settings = Settings(); settings.dictateKeys = ["return", "cmd+return", "tab"]
        settings.dictateMode = 3
        #expect(settings.dictateSend.current.stroke?.description == "tab" && settings.dictateSend.active == 3)
        settings.dictateMode = 99; #expect(settings.dictateSend.active == 3)   // 範囲外は、収める
        settings.dictateMode = -4; #expect(settings.dictateSend.active == 0)
    }

    @Test func switchingCyclesAndWrapsToNotSending() {
        var settings = Settings(); settings.dictateKeys = ["return", "shift+return"]; settings.dictateMode = 0
        var seen: [String] = []
        for _ in 0..<4 {
            let modes = settings.dictateSend
            seen.append(modes.current.stroke?.description ?? "-")
            settings.dictateMode = modes.nextIndex
        }
        #expect(seen == ["-", "return", "shift+return", "-"])   // 最後の次は、先頭へ
    }

    @Test func anUnreadableKeyIsReportedNotTurnedIntoEnter() {
        var settings = Settings(); settings.dictateKeys = ["return", "no-such-key"]; settings.dictateMode = 2
        let mode = settings.dictateSend.current
        #expect(mode.stroke == nil && mode.problem != nil)
    }
}
