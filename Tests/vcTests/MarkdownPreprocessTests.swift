import Foundation
import Testing
@testable import vc

/// 数式（LaTeX）を読める文字に直すこと・金額やコードを壊さないこと・`<details>`・差分の色づけ。
@Suite struct MarkdownPreprocessTests {
    @Test func latexSymbolsBecomeReadableUnicode() {
        #expect(LaTeXText.convert(#"E = mc^2"#) == "E = mc²")
        #expect(LaTeXText.convert(#"\alpha + \beta \leq \gamma"#) == "α + β ≤ γ")
        #expect(LaTeXText.convert(#"\frac{1}{3}"#) == "1/3")
        #expect(LaTeXText.convert(#"\frac{a+b}{c}"#) == "(a+b)/c")
        #expect(LaTeXText.convert(#"\sqrt{x^2 + y^2}"#) == "√(x² + y²)")
        #expect(LaTeXText.convert(#"\sum_{i=1}^{n} x_i"#).contains("∑") && LaTeXText.convert(#"x_i"#) == "xᵢ")
        #expect(LaTeXText.convert(#"\int_0^1 x^2 \, dx"#) == "∫₀¹ x² dx")
        #expect(LaTeXText.convert(#"x \in \mathbb{R}"#) == "x ∈ ℝ")
        #expect(LaTeXText.convert(#"\text{速度} = \frac{d}{t}"#) == "速度 = d/t")
        #expect(LaTeXText.convert(#"a \to \infty"#) == "a → ∞")
        #expect(LaTeXText.convert(#"x^{10}"#) == "x¹⁰")
        #expect(LaTeXText.convert(#"a_{ab}"#) == "a_(ab)")   // 添え字にできないものは、そのまま見える形
    }

    @Test func inlineMathIsConvertedButMoneyAndCodeAreNot() {
        #expect(MarkdownPreprocess.apply(#"面積は $\pi r^2$ です"#) == "面積は π r² です")
        #expect(MarkdownPreprocess.apply("価格は $5 と $10 です") == "価格は $5 と $10 です")   // 金額
        #expect(MarkdownPreprocess.apply(#"変数 `$a^2$` はコード"#) == #"変数 `$a^2$` はコード"#)   // コード片の中は、触らない
        #expect(MarkdownPreprocess.apply(#"エスケープ \$x_1\$ は金額"#) == "エスケープ $x_1$ は金額")   // `\$` で逃がしたものは、金額
    }

    @Test func blockMathBecomesAMonospacedBlockAndFencedCodeIsUntouched() {
        let converted = MarkdownPreprocess.apply("前\n$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$\n後")
        #expect(converted.contains("```math\n∫₀¹ x² dx = 1/3\n```"))
        #expect(converted.hasPrefix("前") && converted.hasSuffix("後"))
        let code = "```python\nprice = '$' + str(x^2)\n$$ not math $$\n```"
        #expect(MarkdownPreprocess.apply(code) == code)
        #expect(MarkdownPreprocess.apply("$$a^2$$").contains("```math\na²\n```"))   // 1 行のブロック
    }

    @Test func detailsBecomeABoldSummaryLine() {
        let text = MarkdownPreprocess.apply("<details><summary>折りたたみ</summary>中身</details>")
        #expect(text.contains("**折りたたみ**") && text.contains("中身") && !text.contains("<"))
    }

    @Test func diffLinesAreColouredByTheirFirstCharacter() {
        let code = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n context\n-old\n+new"
        guard let language = CodeHighlighter.language(named: "diff") else { Issue.record("diff の表がない"); return }
        let tokens = CodeHighlighter.tokens(in: code, language: language).map { ((code as NSString).substring(with: $0.range), $0.kind) }
        #expect(tokens.contains { $0.0 == "-old" && $0.1 == .removed } && tokens.contains { $0.0 == "+new" && $0.1 == .added })
        #expect(tokens.contains { $0.0.hasPrefix("@@") && $0.1 == .type } && tokens.contains { $0.0 == "+++ b/x" && $0.1 == .comment })
        #expect(!tokens.contains { $0.0 == " context" })
    }
}
