import Foundation
import Testing
@testable import VCPCControl
import VCCore
import VCDecision

private struct BrokenScreenDesktop: Desktop {
    func snapshot() throws -> Snapshot { throw SnapshotError.notOK(code: "INTERNAL") }
    func apps() throws -> [String] { ["Spotify"] }
    func perform(_ step: Step) throws {}
}

/// 「アプリを開く: Spotify」を選ぶ偽物。
private struct PicksSpotify: OptionScorer {
    func score(state: String, question: String, options: [String]) throws -> [Double] {
        let hit = options.firstIndex(of: "アプリを開く: Spotify")
        var p = options.map { _ in 0.001 }
        p[hit ?? options.count - 1] = 0.9
        let sum = p.reduce(0, +)
        return p.map { $0 / sum }
    }
}

@Suite struct TextExtractorTests {
    @Test func prefersQuotedText() {
        #expect(TextExtractor.text(in: "「こんにちは」と入力して") == "こんにちは")
        #expect(TextExtractor.text(in: "検索欄に\"hello world\"と打って") == "hello world")
    }

    @Test func fallsBackToTextBeforeTheVerb() {
        #expect(TextExtractor.text(in: "明日の会議と入力して") == "明日の会議")
    }

    @Test func returnsNilWithoutText() {
        #expect(TextExtractor.text(in: "メッセージを送って") == nil)
    }
}

@Suite struct SnapshotParserTests {
    private func json(_ tree: String) -> Data { Data(#"{"ok":true,"data":{"app":"A","tree":\#(tree)}}"#.utf8) }

    @Test func keepsOperableElementsInTreeOrder() throws {
        let tree = """
        {"role":"window","name":"w","children":[
          {"role":"group","name":"g","children":[
            {"role":"button","name":"Mute","ref_id":"@s:e1","available_actions":["Click"]}]},
          {"role":"button","name":"","ref_id":"@s:e2","available_actions":["Click"]},
          {"role":"button","name":"Zoom","ref_id":"@s:e3","states":["disabled"],"available_actions":["Click"]},
          {"role":"textfield","name":"Note","ref_id":"@s:e4","available_actions":["TypeText"]},
          {"role":"textfield","name":"Name","ref_id":"@s:e5","available_actions":["SetValue"]},
          {"role":"scrollarea","ref_id":"@s:e6","available_actions":["Scroll"]}]}
        """
        let snapshot = try SnapshotParser.parse(json(tree))
        #expect(snapshot.app == "A")
        #expect(snapshot.elements.map(\.ref) == ["@s:e1", "@s:e2", "@s:e4", "@s:e6"])   // 名前のない押せる要素（e2）も入る。無効（e3）は入らない
    }

    @Test func surfacesAgentDesktopErrorCode() {
        let data = Data(#"{"ok":false,"error":{"code":"WINDOW_NOT_FOUND"}}"#.utf8)
        #expect(throws: SnapshotError.notOK(code: "WINDOW_NOT_FOUND")) { try SnapshotParser.parse(data) }
    }
}

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

@Suite struct HistoryTests {
    private let area = UIElement(ref: "@a:e1", role: "scrollarea", name: "notes", actions: ["Scroll"])

    @Test func inversesPairUp() {
        #expect(Step.scroll(.down, area).inverse == .scroll(.up, area))
        #expect(Step.window(.maximize, app: "A").inverse == .window(.restore, app: "A"))
        #expect(Step.window(.restore, app: "A").inverse == .window(.maximize, app: "A"))
        #expect(Step.press(Shortcut.all.first { $0.combo == "cmd+z" }!).inverse == .press(Shortcut.all.first { $0.combo == "cmd+shift+z" }!))
        #expect(Step.openApp("A").inverse == nil)
    }

    @Test func reboundFindsTheSameElementInANewSnapshot() {
        let old = UIElement(ref: "@old:e3", role: "button", name: "Save", actions: ["Click"])
        let fresh = UIElement(ref: "@new:e9", role: "button", name: "Save", actions: ["Click"])
        let snapshot = Snapshot(app: "A", elements: [UIElement(ref: "@new:e1", role: "button", name: "Cancel", actions: ["Click"]), fresh])
        #expect(Step.click(old).rebound(to: snapshot) == .click(fresh))
        #expect(Step.click(UIElement(ref: "@old:e4", role: "button", name: "Gone", actions: ["Click"])).rebound(to: snapshot) == nil)
        #expect(Step.type(text: "secret", into: old).rebound(to: snapshot) == nil)   // 入れる文字は、繰り返さない
    }

    @Test func dropsOldEntriesAndKeepsTheNewest() {
        let now = Date()
        let step = Step.openApp("A")
        let entries = [Executed(step: step, at: now.addingTimeInterval(-500))] + (0..<5).map { Executed(step: .openApp("B\($0)"), at: now.addingTimeInterval(Double(-$0))) }.reversed()
        let recent = History.recent(entries, now: now)
        #expect(recent.count == History.maxCount)
        #expect(!recent.contains { $0.step == step })
        #expect(recent.last?.step == .openApp("B0"))
    }
}

@Suite struct PlannerResilienceTests {
    @Test func stillOpensAnAppWhenTheScreenCannotBeRead() throws {
        let plan = try Planner(scorer: PicksSpotify(), desktop: BrokenScreenDesktop()).plan("Spotifyを開いて")
        #expect(plan.step == .openApp("Spotify"))
        #expect(plan.note?.contains("INTERNAL") == true)
    }
}

@Suite struct KeyBindingCatalogTests {
    private func load(_ json: String) throws -> KeyBindingCatalog.Loaded {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(json.utf8).write(to: dir.appendingPathComponent("t.json"))
        return KeyBindingCatalog.load(directories: [dir])
    }

    @Test func loadsValidDefinitionsAndReportsInvalidOnes() throws {
        let loaded = try load("""
        [{"id":"a","label":"次の曲","keys":["cmd+right"],"app":"Spotify"},
         {"id":"quit","label":"終了","keys":["cmd+q"]},
         {"id":"bad","label":"x","keys":["a"],"when":"(["},
         {"id":"a","label":"重複","keys":["b"]},
         {"id":"empty","label":"","keys":["a"]}]
        """)
        #expect(loaded.shortcuts.map(\.combo) == ["cmd+right"])
        #expect(loaded.shortcuts.first?.app == "Spotify")
        #expect(loaded.problems.count == 4)
        #expect(loaded.problems.contains { $0.contains("終了") })
    }

    @Test func malformedFileIsReportedNotIgnored() throws {
        #expect(try load("not json").problems.count == 1)
    }

    @Test func appAndPhraseConditionsFilterCandidates() throws {
        struct D: Desktop {
            func snapshot() throws -> Snapshot { Snapshot(app: "Spotify", elements: []) }
            func apps() throws -> [String] { [] }
            func perform(_ step: Step) throws {}
        }
        final class Spy: OptionScorer, @unchecked Sendable {
            var seen: [String] = []
            func score(state: String, question: String, options: [String]) throws -> [Double] { seen += options; return options.map { _ in 1.0 / Double(options.count) } }
        }
        let bindings = [Shortcut(combos: ["cmd+right"], option: "次の曲", app: "Spotify"),
                      Shortcut(combos: ["cmd+left"], option: "前の曲", app: "Safari"),
                      Shortcut(combos: ["x"], option: "条件つき", when: "音量")]
        let spy = Spy()
        _ = try Planner(scorer: spy, desktop: D(), keyBindings: bindings).plan("曲を進めて")
        #expect(spy.seen.contains("キー操作: 次の曲"))
        #expect(!spy.seen.contains("キー操作: 前の曲"))
        #expect(!spy.seen.contains("キー操作: 条件つき"))
    }
}

@Suite struct ElementVerbTests {
    @Test func verbsAreOfferedOnlyWhereTheElementAdvertisesTheAction() {
        let checkbox = UIElement(ref: "@s:e1", role: "checkbox", name: "Dark", actions: ["Click", "Toggle", "SetFocus"])
        let disclosure = UIElement(ref: "@s:e2", role: "disclosure", name: "Details", actions: ["Click", "Expand", "Collapse"])
        let button = UIElement(ref: "@s:e3", role: "button", name: "Save", actions: ["Click"])
        let field = UIElement(ref: "@s:e4", role: "textfield", name: "Search", actions: ["Click", "SetValue", "SetFocus", "TypeText"])
        let sw = UIElement(ref: "@s:e5", role: "switch", name: "Sound", actions: ["Click", "Toggle"])
        func verbs(_ e: UIElement) -> Set<ElementVerb> { Set(ElementVerb.allCases.filter { $0.applies(to: e) }) }
        #expect(verbs(checkbox) == [.check, .uncheck, .toggle])
        #expect(verbs(disclosure) == [.expand, .collapse])
        #expect(verbs(button).isEmpty)
        #expect(verbs(field) == [.clear, .focus])
        #expect(verbs(sw).isEmpty)
    }

    @Test func destructiveVerbsAlwaysAskAndInversesPairUp() {
        let e = UIElement(ref: "@s:e1", role: "checkbox", name: "Dark", actions: ["Toggle"])
        #expect(ElementVerb.clear.needsConfirmation)
        #expect(!ElementVerb.check.needsConfirmation)
        #expect(Step.element(.check, e).inverse == .element(.uncheck, e))
        #expect(Planner.needsConfirmation(.closeApp("A")))
    }
}

@Suite struct RegionTests {
    private let window = Rect(x: 100, y: 100, width: 300, height: 600)

    private func element(x: Double, y: Double, w: Double = 20, h: Double = 20) -> UIElement {
        UIElement(ref: "@s:e1", role: "button", name: "B", actions: ["Click"], bounds: Rect(x: x, y: y, width: w, height: h))
    }

    @Test func mapsTheCenterToANineCellGridInsideTheWindow() {
        #expect(element(x: 110, y: 110).region(in: window) == "左上")
        #expect(element(x: 240, y: 110).region(in: window) == "上")
        #expect(element(x: 370, y: 110).region(in: window) == "右上")
        #expect(element(x: 240, y: 390).region(in: window) == "中央")
        #expect(element(x: 110, y: 670).region(in: window) == "左下")
        #expect(element(x: 370, y: 670).region(in: window) == "右下")
    }

    @Test func hasNoRegionWithoutBounds() {
        let e = UIElement(ref: "@s:e1", role: "button", name: "B", actions: ["Click"])
        #expect(e.region(in: window) == nil)
        #expect(element(x: 0, y: 0).region(in: nil) == nil)
    }

    @Test func parserReadsBoundsAndDropsZeroSizedElements() throws {
        let json = #"""
        {"ok":true,"data":{"app":"A","tree":{"role":"window","bounds":{"x":0,"y":0,"width":300,"height":600},"children":[
          {"role":"button","name":"A","ref_id":"@s:e1","available_actions":["Click"],"bounds":{"x":10,"y":10,"width":40,"height":20}},
          {"role":"button","name":"Hidden","ref_id":"@s:e2","available_actions":["Click"],"bounds":{"x":10,"y":10,"width":0,"height":0}}]}}}
        """#
        let snapshot = try SnapshotParser.parse(Data(json.utf8))
        #expect(snapshot.window == Rect(x: 0, y: 0, width: 300, height: 600))
        #expect(snapshot.elements.map(\.name) == ["A"])
        #expect(snapshot.elements.first?.bounds == Rect(x: 10, y: 10, width: 40, height: 20))
    }
}
