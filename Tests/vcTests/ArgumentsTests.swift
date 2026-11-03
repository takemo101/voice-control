import Testing
@testable import vc

/// `vc` の引数の読み方。取り除く順番・値の取り方の癖も、そのまま固定する。
@Suite struct ArgumentsTests {
    @Test func optionTakesTheNextWordAndRemovesBoth() {
        var a = Arguments(["run", "テスト", "--model", "m"])
        let model = a.option("--model")
        #expect(model == "m")
        #expect(a.remaining == ["run", "テスト"])
    }

    @Test func optionBeforeTheCommandWorksToo() {
        var a = Arguments(["--model", "m", "run", "x"])
        let model = a.option("--model")
        #expect(model == "m")
        #expect(a.command == "run")
    }

    @Test func equalsFormIsNotSupported() {
        var a = Arguments(["run", "--model=m"])
        let model = a.option("--model")
        #expect(model == nil)
        #expect(a.positionals == ["--model=m"])
    }

    @Test func optionAtTheEndHasNoValueAndStaysAsAPositional() {
        var a = Arguments(["run", "--model"])
        let model = a.option("--model")
        #expect(model == nil)
        #expect(a.remaining == ["run", "--model"])
        #expect(a.positionals == ["--model"])
    }

    @Test func optionTakesTheNextWordEvenWhenItLooksLikeAnOption() {
        var a = Arguments(["run", "--model", "--yes"])
        let model = a.option("--model")
        let yes = a.flag("--yes")
        #expect(model == "--yes")
        #expect(!yes)
        #expect(a.remaining == ["run"])
    }

    @Test func optionAcceptsAnEmptyValue() {
        var a = Arguments(["run", "--model", "", "x"])
        let model = a.option("--model")
        #expect(model == "")
        #expect(a.remaining == ["run", "x"])
    }

    @Test func onlyTheFirstOccurrenceOfAnOptionIsTaken() {
        var a = Arguments(["run", "--model", "A", "--model", "B"])
        let first = a.option("--model")
        #expect(first == "A")
        #expect(a.remaining == ["run", "--model", "B"])
        let second = a.option("--model")
        let third = a.option("--model")
        #expect(second == "B")
        #expect(third == nil)
    }

    @Test func optionCanTakeTheCommandPosition() {
        // 先頭の語も、探す対象（コマンド名が値として取られ、コマンドがなくなる）
        var a = Arguments(["--model", "run"])
        let model = a.option("--model")
        #expect(model == "run")
        #expect(a.command == nil)
    }

    @Test func flagRemovesOnlyTheFirstOccurrence() {
        var a = Arguments(["run", "--yes", "x", "--yes"])
        let first = a.flag("--yes")
        #expect(first)
        #expect(a.remaining == ["run", "x", "--yes"])
        let second = a.flag("--yes")
        let third = a.flag("--yes")
        #expect(second)
        #expect(!third)
        #expect(a.remaining == ["run", "x"])
    }

    @Test func absentFlagChangesNothing() {
        var a = Arguments(["run", "x"])
        let yes = a.flag("--yes")
        #expect(!yes)
        #expect(a.remaining == ["run", "x"])
    }

    @Test func unknownOptionsAreNotRemovedAndBecomePositionals() {
        var a = Arguments(["run", "--foo", "bar"])
        let yes = a.flag("--yes")
        let model = a.option("--model")
        #expect(!yes)
        #expect(model == nil)
        #expect(a.positionals == ["--foo", "bar"])
    }

    @Test func positionalsExcludeTheCommandName() {
        #expect(Arguments(["hotkey", "set", "ctrl", "opt"]).positionals == ["set", "ctrl", "opt"])
        #expect(Arguments(["skills"]).positionals.isEmpty)
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
