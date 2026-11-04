import Foundation
import Testing
@testable import VCSkill

@Suite struct OutputCompactorTests {
    private let snapshot = #"""
    {"ok":true,"data":{"app":"Fixture","tree":{"role":"window","children":[
      {"role":"button","name":"Save","ref_id":"@s17tb038elj2nz:e1","available_actions":["Click"]},
      {"role":"button","name":"Off","ref_id":"@s17tb038elj2nz:e2","available_actions":["Click"],"states":["disabled"]},
      {"role":"group","ref_id":"@s17tb038elj2nz:e3"},
      {"role":"textfield","name":"Search","ref_id":"@s17tb038elj2nz:e4","available_actions":["TypeText"],"states":["focused"]}]}}}
    """#

    @Test func snapshotBecomesShortOperableLinesWithAliasedRefs() {
        let aliases = RefAliases()
        let text = OutputCompactor.compact(argv: ["agent-desktop", "snapshot", "-i"], output: snapshot, aliases: aliases)
        #expect(text == "app: Fixture\n@a1:e1 [button] Save\n@a1:e4 [textfield] Search (focused)")
        // 別名は、実行の直前に、元の参照に戻る
        #expect(aliases.expand("@a1:e4") == "@s17tb038elj2nz:e4")
        #expect(aliases.expand("@zzz:e4") == "@zzz:e4")
        #expect(aliases.expand("Settings") == "Settings")
    }

    @Test func errorsKeepTheirCodeAndLongOutputIsCut() {
        let error = #"{"ok":false,"error":{"code":"STALE_REF","message":"gone"}}"#
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "click", "@a1:e1"], output: error) == "error STALE_REF: gone")
        let long = String(repeating: "x", count: OutputCompactor.maxChars + 50)
        #expect(OutputCompactor.compact(argv: ["ls"], output: long).contains("50 文字を省略"))
    }
}

/// 画面の文字を読む出力（`snapshot`〔`-i` なし〕・`get`）。操作用の整形は、メッセージの本文を捨てるので、読む用は別。
@Suite struct ReadingOutputTests {
    private let screen = #"""
    {"ok":true,"data":{"app":"Messages","tree":{"role":"window","children":[
      {"role":"statictext","name":"Alice","value":"Alice"},
      {"role":"statictext","value":"明日の会議、14時からで大丈夫？"},
      {"role":"statictext","value":"明日の会議、14時からで大丈夫？"},
      {"role":"row","name":"Alice 明日の会議、14時からで大丈夫？"},
      {"role":"button","name":"Send","ref_id":"@s1:e1","available_actions":["Click"]},
      {"role":"textfield","name":"iMessage","ref_id":"@s1:e2","available_actions":["TypeText"]},
      {"role":"scrollbar","value":"0"},
      {"role":"group","children":[{"role":"link","name":"資料はこちら"}]}]}}}
    """#

    @Test func aSnapshotWithoutInteractiveOnlyYieldsTheTextInOrder() {
        let text = OutputCompactor.compact(argv: ["agent-desktop", "snapshot"], output: screen)
        // 本文・リンクが残る。同じ行の連続・行（row）の重複・空の入力欄の名前・ボタン・値だけのスクロールバーは、出ない
        #expect(text == "app: Messages\nAlice\n明日の会議、14時からで大丈夫？\n資料はこちら")
    }

    @Test func theOperationalSnapshotIsUnchanged() {
        let text = OutputCompactor.compact(argv: ["agent-desktop", "snapshot", "-i", "--app", "Messages"], output: screen)
        #expect(text.hasPrefix("app: Messages\n@a1:e1 [button] Send"))
        #expect(!text.contains("明日の会議"))
    }

    @Test func getReturnsTheTextItself() {
        let got = #"{"ok":true,"data":{"property":"text","ref":"@s1:e5","value":"line 1\nline 2"}}"#
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "get", "@a1:e5"], output: got) == "line 1\nline 2")
    }

    @Test func aScreenWithoutTextSaysSo() {
        let empty = #"{"ok":true,"data":{"app":"Preview","tree":{"role":"window","children":[{"role":"button","name":"Zoom"}]}}}"#
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "snapshot"], output: empty) == "app: Preview\n(no readable text)")
    }

    /// 長い画面は、先頭と末尾を残す（チャットの新しい発言は、下にある）。上限を超えない。
    @Test func aLongScreenKeepsTheStartAndTheEnd() {
        let lines = (1...400).map { #"{"role":"statictext","value":"message \#($0)"}"# }.joined(separator: ",")
        let json = #"{"ok":true,"data":{"app":"Chat","tree":{"role":"window","children":[\#(lines)]}}}"#
        let text = OutputCompactor.compact(argv: ["agent-desktop", "snapshot"], output: json)
        #expect(text.hasPrefix("app: Chat\nmessage 1\n"))
        #expect(text.hasSuffix("message 400"))
        #expect(text.contains("文字を省略"))
        #expect(text.count <= OutputCompactor.maxReadChars + 40)
    }

    @Test func aFailedReadFallsBackToTheErrorLine() {
        let error = #"{"ok":false,"error":{"code":"WINDOW_NOT_FOUND","message":"No focused window found"}}"#
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "snapshot"], output: error) == "error WINDOW_NOT_FOUND: No focused window found")
    }
}

/// agent-desktop は、警告を stderr に出す（標準出力と混ざる）。JSON の前に警告の行があっても、整形が効く。
@Suite struct WarningLinesTests {
    private let warning = "2026-11-04T14:40:57Z  WARN agent_desktop_macos: Skipped invalid AppKit application records skipped=[{\"field\":\"pid\"}]\n"
    private let snapshot = #"{"ok":true,"data":{"app":"Fixture","tree":{"role":"window","children":[{"role":"statictext","value":"hello"},{"role":"button","name":"Save","ref_id":"@s1:e1","available_actions":["Click"]}]}}}"#

    @Test func readingAndOperationalSnapshotsStillWorkWithWarningLinesInFront() {
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "snapshot"], output: warning + warning + snapshot) == "app: Fixture\nhello")
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "snapshot", "-i"], output: warning + snapshot) == "app: Fixture\n@a1:e1 [button] Save")
    }

    @Test func anOutputWithoutJsonIsLeftAlone() {
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "snapshot"], output: warning) == warning)
    }
}

/// ブラウザの画面：メニュー・アドレス欄・ポップアップではなく、ページの本文を渡す。長いときは、雑音（短い行）から落とす。
@Suite struct BrowserPageTests {
    @Test func onlyThePageWithTheMostTextIsKeptAndTheBrowsersOwnTextIsDropped() {
        let json = #"""
        {"ok":true,"data":{"app":"Google Chrome","tree":{"role":"window","children":[
          {"role":"toolbar","children":[{"role":"textfield","value":"https://example.com/post/1"}]},
          {"role":"webarea","name":"Omnibox Popup","children":[{"role":"statictext","value":"[このページについて質問する]"}]},
          {"role":"webarea","name":"ページ","children":[
            {"role":"link","name":"ホーム"},
            {"role":"statictext","value":"来週の勉強会、場所を新宿に変更します。"},
            {"role":"statictext","value":"2"}]}]}}}
        """#
        #expect(OutputCompactor.compact(argv: ["agent-desktop", "snapshot"], output: json) == "app: Google Chrome\nホーム\n来週の勉強会、場所を新宿に変更します。\n2")
    }

    @Test func whenOverTheLimitShortNoiseAndRepeatsAreDroppedFirstSoTheLongTextSurvives() {
        let post = String(repeating: "本文です。", count: 100)   // 500 文字
        let noise = (1...300).map { #"{"role":"statictext","value":"\#($0 % 7)"},{"role":"link","name":"ホームへ戻る"}"# }.joined(separator: ",")
        let json = #"{"ok":true,"data":{"app":"Chrome","tree":{"role":"webarea","children":[\#(noise),{"role":"statictext","value":"\#(post)"}]}}}"#
        let text = OutputCompactor.compact(argv: ["agent-desktop", "snapshot"], output: json)
        #expect(text.contains(post))
        #expect(!text.contains("文字を省略"))
        #expect(text.components(separatedBy: "\n").filter { $0 == "ホームへ戻る" }.count == 1)
    }
}
