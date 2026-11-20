import Testing
@testable import vc

/// 少しずつ届く答えを、読める文から読む塊にする：最初の文が届いたら読み始める・区切りまで読まない・全部足すと、一度に読むのと、同じ文になる。
@Suite struct SpokenStreamTests {
    /// 全文を、`size` 文字ずつ届けて、出た塊（と、終わりの分）を、つなげる。
    private func streamed(_ markdown: String, size: Int) -> String {
        var stream = SpokenStream()
        var out: [String] = []
        var index = markdown.startIndex
        while index < markdown.endIndex {
            let end = markdown.index(index, offsetBy: size, limitedBy: markdown.endIndex) ?? markdown.endIndex
            out += stream.push(String(markdown[index..<end]))
            index = end
        }
        out += stream.finish()
        return out.joined()
    }

    private let samples = [
        "今日は、晴れです。気温は 24 度です。\n\n- 傘は、要りません\n- 風が、少し、あります\n\n以上です。",
        "# 見出し\n\n**重要**：3.14 は、円周率です。Hello world. Next sentence! Is it ok? Yes.\n最後の行",
        "説明です。\n\n```swift\nlet x = 1\nprint(x)\n```\n\nコードは、これです。",
        "| 名前 | 内容 |\n|---|---|\n| a | 一つ目 |\n| b | 二つ目 |",
    ]

    @Test func theSumOfWhatIsReadEqualsReadingTheWholeAtOnceWhateverTheSizeOfThePieces() {
        for sample in samples {
            // 文と文の間の空白だけは、違ってよい（別々の塊として読む：塊の切れ目で、空白は、読み上げに、効かない）
            func bare(_ text: String) -> String { text.filter { !$0.isWhitespace } }
            let whole = bare(SpokenText.chunks(from: sample).joined())
            for size in [1, 2, 3, 7, 50, 1000] {
                #expect(bare(streamed(sample, size: size)) == whole, "size \(size)：\(sample.prefix(20))")
            }
        }
    }

    @Test func theFirstSentenceIsReadAsSoonAsItArrivesBeforeTheLineEnds() {
        var stream = SpokenStream()
        #expect(stream.push("今日は、晴れです").isEmpty)                  // まだ、文の終わりがない
        #expect(stream.push("。気温は").joined() == "今日は、晴れです。")      // 区切りが届いた：すぐ読む（行は、まだ続く）
        #expect(stream.finish().joined() == "気温は。")                   // 終わり：残りを読む（句点がなければ、足す：`SpokenText` と同じ）
    }

    @Test func anEnglishSentenceEndsOnlyWhenWhitespaceFollowsSoDecimalsAreNotCut() {
        var stream = SpokenStream()
        #expect(stream.push("Pi is 3.").isEmpty)                         // 「3.」の後ろが、まだ、届かない
        #expect(stream.push("14 today. ").joined() == "Pi is 3.14 today.")
        #expect(stream.push("Next").isEmpty)
    }

    @Test func codeBlocksAreSkippedAndTheNoteIsGivenOnceAtTheEnd() {
        var stream = SpokenStream()
        var out = stream.push("説明です。\n```\nlet x = 1\n")
        out += stream.push("print(x)\n```\n次です。\n")
        out += stream.finish()
        #expect(out.joined() == "説明です。次です。コードは、画面に出しています。")
        #expect(!out.joined().contains("let x"))
    }

    @Test func nothingIsReadUntilABoundaryAndANoteIsNotGivenWithoutAnySpeech() {
        var stream = SpokenStream()
        #expect(stream.push("長い文が続いていて").isEmpty && stream.push("まだ区切りがない").isEmpty && !stream.emitted)
        #expect(stream.finish().joined() == "長い文が続いていてまだ区切りがない。" && stream.emitted)
        var onlyCode = SpokenStream()
        _ = onlyCode.push("```\ncode\n```\n")
        #expect(onlyCode.finish().isEmpty)                              // 読むものが、なかった：「コードは…」だけを、話さない
    }
}
