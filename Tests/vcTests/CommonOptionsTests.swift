import Testing
@testable import vc

/// どのコマンドでも、最初に取り除く共通のオプション。
@Suite struct CommonOptionsTests {
    @Test func defaultsWhenNothingIsGiven() {
        var a = Arguments(["keys"])
        let o = CommonOptions(consuming: &a)
        #expect(o.model == nil && o.app == nil && o.audio == nil && o.trigger == nil && o.floor == nil)
        #expect(o.length == 1024)
        #expect(!o.execute && !o.yes && !o.speak && !o.hotkey && !o.llm && !o.llmSplit && !o.noContext && !o.noLocation && !o.dryRun)
        #expect(a.remaining == ["keys"])
    }

    @Test func takesEveryCommonOptionFromAnyPositionAndLeavesTheRest() {
        var a = Arguments(["--model", "m", "act", "削除して", "--execute", "--length", "512", "--floor", "0.3", "--yes", "--app", "Fixture",
                           "--audio", "a.wav", "--trigger", "f5", "--speak", "--hotkey", "--llm", "--llm-split", "--no-context", "--no-location"])
        let o = CommonOptions(consuming: &a)
        #expect(o.model == "m" && o.length == 512 && o.floor == 0.3 && o.app == "Fixture" && o.audio == "a.wav" && o.trigger == "f5")
        #expect(o.execute && o.yes && o.speak && o.hotkey && o.llm && o.llmSplit && o.noContext && o.noLocation)
        #expect(a.remaining == ["act", "削除して"])
    }

    @Test func aNonNumericLengthOrFloorIsStillRemoved() {
        var a = Arguments(["--length", "abc", "--floor", "high", "plan", "x"])
        let o = CommonOptions(consuming: &a)
        #expect(o.length == 1024)
        #expect(o.floor == nil)
        #expect(a.remaining == ["plan", "x"])
    }

    @Test func dryRunIsReadButLeftForTheCommand() {
        var a = Arguments(["run", "x", "--dry-run"])
        let o = CommonOptions(consuming: &a)
        #expect(o.dryRun)
        #expect(a.remaining == ["run", "x", "--dry-run"])
        let removed = a.flag("--dry-run")
        #expect(removed)
    }

    @Test func removalOrderDecidesWhoGetsTheValue() {
        // --app が先なので、`--execute` は、--app の値になる
        var a = Arguments(["--app", "--execute", "keys"])
        let o = CommonOptions(consuming: &a)
        #expect(o.app == "--execute")
        #expect(!o.execute)
        #expect(a.remaining == ["keys"])
    }

    @Test func keysIsNotACommonOptionSoItBecomesTheCommandWhenPlacedFirst() {
        // `--keys` は、コマンド名を決めたあとに取り除く（main.swift）。コマンド名の前に置くと、`--keys` がコマンド名になる
        var a = Arguments(["--keys", "dir", "plan", "x"])
        _ = CommonOptions(consuming: &a)
        #expect(a.command == "--keys")
        #expect(a.remaining == ["--keys", "dir", "plan", "x"])
    }
}
