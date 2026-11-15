import Testing
@testable import vc

@Suite struct SpokenTextTests {
    private func spoken(_ markdown: String, maxLength: Int = 200) -> String { SpokenText.chunks(from: markdown, maxLength: maxLength).joined() }

    @Test func marksAreNotReadButTheWordsAre() {
        let text = spoken("# 見出し\n\n**大事な**こと。\n\n- 一つ目\n- 二つ目\n1. 三つ目\n> 引用")
        #expect(text == "見出し。大事なこと。一つ目。二つ目。三つ目。引用。")
    }

    @Test func codeBlocksUrlsAndTableRulesAreSkippedLinksKeepTheirLabel() {
        let markdown = "コマンドは次です。\n```sh\nrm -rf /tmp/x\n```\n詳しくは [公式の説明](https://example.com/doc) と https://example.com/raw を見て。\n\n| 名前 | 値 |\n|---|---|\n| a | 1 |"
        let text = spoken(markdown)
        #expect(text.hasSuffix("コードは、画面に出しています。"))   // 読まなかったコードが、画面にあることを、伝える
        #expect(!text.contains("rm") && !text.contains("http") && !text.contains("---") && !text.contains("|"))
        #expect(text.contains("公式の説明") && text.contains("名前、値") && text.contains("a、1"))
    }

    @Test func longAnswersAreReadInFullInChunksNotCutShort() {
        let sentence = String(repeating: "あ", count: 40) + "。"
        let markdown = Array(repeating: sentence, count: 30).joined()   // 1 行・1,230 文字
        let chunks = SpokenText.chunks(from: markdown, maxLength: 200)
        #expect(chunks.joined() == markdown)                              // 1 文字も、落とさない
        #expect(chunks.count > 5 && chunks.allSatisfy { $0.count <= 205 })
    }

    @Test func nothingToReadGivesNoChunks() {
        #expect(SpokenText.chunks(from: "").isEmpty)
        #expect(SpokenText.chunks(from: "```\ncode only\n```\n---").isEmpty)   // コードだけなら、何も読まない（「画面に出しています」だけを、読まない）
    }
}
