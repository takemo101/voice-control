import Testing
@testable import vc

/// `vc` の引数の読み方。取り除く順番・値の取り方の癖も、そのまま固定する。
@Suite struct ArgumentsTests {
    @Test func optionTakesTheNextWordAndRemovesBoth() {
        var a = Arguments(["plan", "下にスクロールして", "--app", "Safari"])
        let app = a.option("--app")
        #expect(app == "Safari")
        #expect(a.remaining == ["plan", "下にスクロールして"])
    }

    @Test func optionBeforeTheCommandWorksToo() {
        var a = Arguments(["--app", "Safari", "plan", "x"])
        let app = a.option("--app")
        #expect(app == "Safari")
        #expect(a.command == "plan")
    }

    @Test func equalsFormIsNotSupported() {
        var a = Arguments(["plan", "--app=Safari"])
        let app = a.option("--app")
        #expect(app == nil)
        #expect(a.positionals == ["--app=Safari"])
    }

    @Test func optionAtTheEndHasNoValueAndStaysAsAPositional() {
        var a = Arguments(["plan", "--app"])
        let app = a.option("--app")
        #expect(app == nil)
        #expect(a.remaining == ["plan", "--app"])
        #expect(a.positionals == ["--app"])
    }

    @Test func optionTakesTheNextWordEvenWhenItLooksLikeAnOption() {
        var a = Arguments(["plan", "--app", "--execute"])
        let app = a.option("--app")
        let execute = a.flag("--execute")
        #expect(app == "--execute")
        #expect(!execute)
        #expect(a.remaining == ["plan"])
    }

    @Test func optionAcceptsAnEmptyValue() {
        var a = Arguments(["plan", "--app", "", "x"])
        let app = a.option("--app")
        #expect(app == "")
        #expect(a.remaining == ["plan", "x"])
    }

    @Test func onlyTheFirstOccurrenceOfAnOptionIsTaken() {
        var a = Arguments(["plan", "--app", "A", "--app", "B"])
        let first = a.option("--app")
        #expect(first == "A")
        #expect(a.remaining == ["plan", "--app", "B"])
        let second = a.option("--app")
        let third = a.option("--app")
        #expect(second == "B")
        #expect(third == nil)
    }

    @Test func optionCanTakeTheCommandPosition() {
        // 先頭の語も、探す対象（コマンド名が値として取られ、コマンドがなくなる）
        var a = Arguments(["--app", "plan"])
        let app = a.option("--app")
        #expect(app == "plan")
        #expect(a.command == nil)
    }

    @Test func flagRemovesOnlyTheFirstOccurrence() {
        var a = Arguments(["plan", "--yes", "x", "--yes"])
        let first = a.flag("--yes")
        #expect(first)
        #expect(a.remaining == ["plan", "x", "--yes"])
        let second = a.flag("--yes")
        let third = a.flag("--yes")
        #expect(second)
        #expect(!third)
        #expect(a.remaining == ["plan", "x"])
    }

    @Test func absentFlagChangesNothing() {
        var a = Arguments(["plan", "x"])
        let yes = a.flag("--yes")
        #expect(!yes)
        #expect(a.remaining == ["plan", "x"])
    }

    @Test func unknownOptionsAreNotRemovedAndBecomePositionals() {
        var a = Arguments(["plan", "--foo", "bar"])
        let yes = a.flag("--yes")
        let app = a.option("--app")
        #expect(!yes)
        #expect(app == nil)
        #expect(a.positionals == ["--foo", "bar"])
    }

    @Test func positionalsExcludeTheCommandName() {
        #expect(Arguments(["hotkey", "set", "ctrl", "opt"]).positionals == ["set", "ctrl", "opt"])
        #expect(Arguments(["keys"]).positionals.isEmpty)
        #expect(Arguments([]).command == nil)
        #expect(Arguments([]).positionals.isEmpty)
    }

    @Test func containsDoesNotRemove() {
        let a = Arguments(["listen", "--dry-run"])
        #expect(a.contains("--dry-run"))
        #expect(a.remaining == ["listen", "--dry-run"])
        #expect(!a.contains("--yes"))
    }

    @Test func positionalsDependOnWhatWasRemovedFirst() {
        // `vc model --verify`：--verify を取り除く前は、サブコマンドが `--verify` に見える（使い方の誤りになる）
        var a = Arguments(["model", "--verify"])
        #expect(a.positionals.first == "--verify")
        let verify = a.flag("--verify")
        #expect(verify)
        #expect(a.positionals.first == nil)
    }
}
