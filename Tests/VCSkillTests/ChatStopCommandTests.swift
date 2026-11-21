import Testing
@testable import VCSkill

/// 会話のストップワード：**発話の全体が、決まった言い方と同じときだけ**止める。長い文は、普通の質問・依頼（止めない）。
@Suite struct ChatStopCommandTests {
    @Test func shortStopPhrasesMatchRegardlessOfPunctuationSpacingAndCase() {
        for text in ["止めて", "止めて。", "ストップ！", "ストップ", "とめて", "やめて", "キャンセル", "待って", "ちょっと待って", "ちょっと、待って。",
                     "stop", "Stop.", "STOP!", "stop it", "Stop  it", "please stop", "never mind", "Never mind.", "hold on", "cancel"] {
            #expect(ChatStopCommand.matches(text), "\(text)")
        }
    }

    @Test func aLongerSentenceIsAnOrdinaryRequestEvenIfItContainsAStopWord() {
        for text in ["音楽を止めて", "ストップウォッチを見せて", "タイマーを止めて", "止めてから、天気を教えて", "電車が止まっている理由は", "stop the music", "cancel my meeting", "wait for the build", "ストップ高の銘柄を教えて"] {
            #expect(!ChatStopCommand.matches(text), "\(text)")
        }
    }

    @Test func emptyOrPunctuationOnlyIsNotAStopWord() {
        #expect(!ChatStopCommand.matches("") && !ChatStopCommand.matches("   ") && !ChatStopCommand.matches("。。。"))
    }
}
