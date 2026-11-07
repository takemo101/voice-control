import Testing
@testable import VCSkill

/// 道具を呼ばずに答えたときだけ、1 回、道具を呼ぶよう促す（実際に、Apple のモデルが、`run_command{command: "open"}` という文字を返し、何も実行されなかった）。
@Suite struct CommandSessionNudgeTests {
    @Test func aReplyThatIsNotAnAnswerAfterNoToolCallIsNudged() {
        #expect(CommandSession.shouldNudge(callCount: 0, reply: #"run_command{command: "open"}"#))
        #expect(CommandSession.shouldNudge(callCount: 0, reply: "クリップボードの内容を貼り付けてください"))
        #expect(CommandSession.shouldNudge(callCount: 0, reply: ""))
    }

    /// 答え（`done`・`failed`・`skip`）なら、促さない。道具を 1 回でも呼んでいたら、促さない。
    @Test func realAnswersAndRunsThatCalledTheToolAreLeftAlone() {
        for reply in ["done: 開いた", "Done: ok", "failed: 見つからない", "skip: 操作の依頼ではない", "  done: 空白つき"] {
            #expect(!CommandSession.shouldNudge(callCount: 0, reply: reply))
        }
        #expect(!CommandSession.shouldNudge(callCount: 1, reply: #"run_command{command: "open"}"#))
    }
}
