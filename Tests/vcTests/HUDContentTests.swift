import Testing
@testable import vc

/// 小さなカプセルで出すか、カードで出すか：録音中と、題だけの認識中はカプセル。本文（聞こえた文・スキル・コマンド・返事・ボタン）があれば、カード。
@Suite struct HUDContentTests {
    @Test func recordingIsAlwaysCompact() {
        #expect(HUDContent(phase: .recording, title: "録音中").isCompact)
    }

    @Test func aBareWorkingTitleIsCompactButAnyBodyMakesItACard() {
        #expect(HUDContent(phase: .working, title: "認識中…", hint: "Esc で取りやめ", chip: "shift").isCompact)
        #expect(!HUDContent(phase: .working, title: "実行中", heard: "次の曲にして", skill: "spotify").isCompact)
        var withStep = HUDContent(phase: .working, title: "実行中")
        withStep.steps = [.init(command: "ls")]
        #expect(!withStep.isCompact)
        var withReply = HUDContent(phase: .working, title: "実行中")
        withReply.reply = "done"
        #expect(!withReply.isCompact)
    }

    @Test func resultsAndConfirmationsAreCards() {
        #expect(!HUDContent(phase: .success, title: "完了").isCompact)
        #expect(!HUDContent(phase: .failure, title: "失敗").isCompact)
        var confirm = HUDContent(phase: .confirm, title: "実行しますか？")
        confirm.choices = true
        #expect(!confirm.isCompact)
    }
}
