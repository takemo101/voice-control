import Foundation
import Testing
@testable import VCPCControl

@Suite struct ClauseSplitterTests {
    @Test func splitsOnTeFormCommaAndConnectors() {
        #expect(ClauseSplitter.split("Chromeをアクティブにして、ウィンドウを最大化して") == ["Chromeをアクティブにして", "ウィンドウを最大化して"])
        #expect(ClauseSplitter.split("メモを開いてから最大化して") == ["メモを開いて", "最大化して"])
        #expect(ClauseSplitter.split("コピーして、そのあと貼り付けて、保存して") == ["コピーして", "貼り付けて", "保存して"])
    }

    @Test func keepsASingleRequestWhole() {
        #expect(ClauseSplitter.split("下にスクロールして") == ["下にスクロールして"])
        #expect(ClauseSplitter.split("") == [])
    }

    @Test func neverSplitsInsideQuotedText() {
        #expect(ClauseSplitter.split("「りんご、みかんで、ぶどう」と入力して、保存して") == ["「りんご、みかんで、ぶどう」と入力して", "保存して"])
    }
}

@Suite struct SplitWithoutCommaTests {
    @Test func splitsAfterTeFormWhenAnotherRequestFollows() {
        #expect(ClauseSplitter.split("Chromeを開いて最近の流行を検索して") == ["Chromeを開いて", "最近の流行を検索して"])
    }

    @Test func doesNotSplitInsideOneRequest() {
        for s in ["下にスクロールしてほしい", "新しいタブについて調べて", "エンターを押して", "チャットを開いてもいい"] {
            #expect(ClauseSplitter.split(s) == [s], "\(s)")
        }
    }

    @Test func extractsSearchQuery() {
        #expect(TextExtractor.searchQuery(in: "最近の流行を検索して") == "最近の流行")
        #expect(TextExtractor.searchQuery(in: "Googleで猫の画像を調べて") == "猫の画像")
        #expect(TextExtractor.searchQuery(in: "「東京 天気」を検索して") == "東京 天気")
        #expect(TextExtractor.searchQuery(in: "下にスクロールして") == nil)
    }
}

@Suite struct LongRequestTests {
    @Test func splitsPoliteSentencesIntoSteps() {
        let spoken = "まずChromeをアクティブにしてください。次に新しいタブを追加するボタンを押してください。で、「最近の流行」を入力してください。そこでエンターを押して検索一覧を表示してください"
        #expect(ClauseSplitter.split(spoken) == [
            "Chromeをアクティブにして", "新しいタブを追加するボタンを押して", "「最近の流行」を入力して", "エンターを押して", "検索一覧を表示して",
        ])
    }

    @Test func extractsTextCalledSomething() {
        #expect(TextExtractor.text(in: "新しく追加されたChromeのタブに最近の流行という言葉を入力して") == "最近の流行")
    }
}

@Suite struct PoliteTests {
    @Test func dropsTheRequestSuffixButKeepsOneStep() {
        #expect(ClauseSplitter.split("ミュートしてください") == ["ミュートして"])
    }
}
