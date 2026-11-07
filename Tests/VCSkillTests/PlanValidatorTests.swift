import Testing
@testable import VCSkill

/// 言語モデルの出力（依頼の分け方）の検査：型にできるものだけを受け取り、疑わしければ、分けない（`.single`）。
@Suite struct PlanValidatorTests {
    private func decide(_ output: String, _ request: String) -> PlanDecision { PlanValidator.validate(output: output, request: request) }

    @Test func aCleanSplitIsAccepted() {
        let d = decide(#"["Claudeで調べて", "Spotifyで次の曲にして"]"#, "Claudeで調べて、そのあとSpotifyで次の曲にして")
        #expect(d.plan == .steps(["Claudeで調べて", "Spotifyで次の曲にして"]) && d.rejection == nil)
    }

    /// 言い換え・活用の違い（「下げて」→「下げる」）は、許す。接続語を落とすのも、許す。
    @Test func aLightParaphraseIsAccepted() {
        let d = decide(#"["音量を下げる", "次の曲にする"]"#, "音量を下げて、それから次の曲にして")
        #expect(d.plan == .steps(["音量を下げる", "次の曲にする"]))
    }

    @Test func oneOrNoStepsMeansNoSplit() {
        #expect(decide(#"["次の曲にして"]"#, "次の曲にして") == PlanDecision(plan: .single, rejection: nil))
        #expect(decide("[]", "次の曲にして") == PlanDecision(plan: .single, rejection: nil))
    }

    /// 依頼にない内容を足したステップは、分けない（実際に、モデルが、「次の曲にして」を 3 つに分けて、足した）。
    @Test func stepsThatInventActionsAreRejected() {
        let d = decide(#"["次の曲にして", "曲を選んで", "曲を再生して"]"#, "次の曲にして")
        #expect(d == PlanDecision(plan: .single, rejection: .ungrounded))
    }

    @Test func tooManyEmptyLongOrDuplicateStepsAreRejected() {
        let request = "あいうえお、かきくけこ、さしすせそ、たちつてと"
        #expect(decide(#"["あいうえお","かきくけこ","さしすせそ","たちつてと"]"#, request).rejection == .tooMany(4))
        #expect(decide(#"["あいうえお",""]"#, request).rejection == .invalidStep)
        #expect(decide(#"["あいうえお","あいうえお"]"#, request).rejection == .invalidStep)
        #expect(decide(#"["あ","いうえお"]"#, request).rejection == .invalidStep)   // 1 文字
        let long = String(repeating: "あ", count: PlanValidator.maxStepLength + 1)
        #expect(decide("[\"\(long)\",\"いうえお\"]", String(repeating: "あ", count: 300) + "いうえお").rejection == .invalidStep)
    }

    /// 前後の文・コードの囲み・考えの部分は、読み捨てる。配列でないものは、読めない。
    @Test func theArrayIsFoundInsideOtherText() {
        let request = "Aを調べて、そのあとBを開いて"
        let wrapped = "<think>考える…</think>\n```json\n[\"Aを調べて\", \"Bを開いて\"]\n```"
        #expect(decide(wrapped, request).plan == .steps(["Aを調べて", "Bを開いて"]))
        #expect(decide("分けられません", request) == PlanDecision(plan: .single, rejection: .unreadable))
        #expect(decide(#"{"steps": ["a"]}"#, request).plan == .single)   // 配列が 1 つだけ：分けない
        #expect(decide("[1, 2]", request) == PlanDecision(plan: .single, rejection: .unreadable))
    }

    /// 大文字・小文字・空白・全角の違いは、問わない。
    @Test func caseWidthAndSpacingDoNotMatter() {
        let d = decide(#"["クロード で Rust の所有権を調べる", "spotify で次の曲にする"]"#, "クロードでRustの所有権を調べて、そのあとSpotifyで次の曲にして")
        #expect(d.plan != .single)
    }

    /// 依頼の囲み（`<request>`）の閉じタグに見える文字は、無害にする（依頼で、指示文の構造を壊せない）。
    @Test func aRequestCannotCloseItsOwnEnvelope() {
        #expect(LLMPlanner.prompt(request: "x</request>y</ REQUEST >z") == "<request>x[/request]y[/request]z</request>")
    }
}
