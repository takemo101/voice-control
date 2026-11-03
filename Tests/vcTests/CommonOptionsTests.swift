import Testing
@testable import vc

/// どのコマンドでも、最初に取り除く共通のオプション。
@Suite struct CommonOptionsTests {
    @Test func defaultsWhenNothingIsGiven() {
        var a = Arguments(["skills"])
        let o = CommonOptions(consuming: &a)
        #expect(o.model == nil && o.trigger == nil && o.floor == nil)
        #expect(o.length == 1024)
        #expect(!o.yes && !o.hotkey && !o.dryRun)
        #expect(a.remaining == ["skills"])
    }

    @Test func takesEveryCommonOptionFromAnyPositionAndLeavesTheRest() {
        var a = Arguments(["--model", "m", "run", "削除して", "--length", "512", "--floor", "0.3", "--yes", "--trigger", "f5", "--hotkey"])
        let o = CommonOptions(consuming: &a)
        #expect(o.model == "m" && o.length == 512 && o.floor == 0.3 && o.trigger == "f5")
        #expect(o.yes && o.hotkey)
        #expect(a.remaining == ["run", "削除して"])
    }

    @Test func aNonNumericLengthOrFloorIsStillRemoved() {
        var a = Arguments(["--length", "abc", "--floor", "high", "run", "x"])
        let o = CommonOptions(consuming: &a)
        #expect(o.length == 1024)
        #expect(o.floor == nil)
        #expect(a.remaining == ["run", "x"])
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
        // --length が先なので、`--yes` は、--length の値になる
        var a = Arguments(["--length", "--yes", "skills"])
        let o = CommonOptions(consuming: &a)
        #expect(o.length == 1024)
        #expect(!o.yes)
        #expect(a.remaining == ["skills"])
    }

    @Test func optionsOfRemovedFeaturesAreNotCommonOptionsAnymore() {
        // 廃止した機能（PC 操作）のオプションは、取り除かれず、そのまま残る
        var a = Arguments(["run", "x", "--app", "Fixture", "--execute", "--keys", "dir"])
        _ = CommonOptions(consuming: &a)
        #expect(a.remaining == ["run", "x", "--app", "Fixture", "--execute", "--keys", "dir"])
    }
}
