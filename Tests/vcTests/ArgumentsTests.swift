import Testing
@testable import vc

/// 端末の色の指定（端末で実行したときだけ付く）を取り除く。
private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }

/// `vc` の引数の読み方（従来の `option()`・`flag()` と同じ）。取り除く順番・値の取り方の癖も、そのまま固定する。
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

    @Test func copiesAreIndependent() {
        let original = Arguments(["run", "x", "--dry-run"])
        var copy = original
        let removed = copy.flag("--dry-run")
        #expect(removed)
        #expect(original.remaining == ["run", "x", "--dry-run"])
        #expect(copy.remaining == ["run", "x"])
    }
}

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

/// コマンドの一覧と、ヘルプ。
@Suite struct CommandRegistryTests {
    @Test func namesAreUniqueAndFindable() {
        let names = Commands.all.map { $0.info.name }
        #expect(Set(names).count == names.count)
        for name in names { #expect(Commands.find(name)?.info.name == name) }
        #expect(Commands.find("nope") == nil)
    }

    @Test func helpIsNotACommandButIsListed() {
        #expect(Commands.find("help") == nil)
        #expect(Help.commands.last?.name == "help")
        #expect(Help.commands.count == Commands.all.count + 1)
    }

    @Test func overviewListsEveryCommandUnderItsGroup() {
        let lines = plain(Help.overview()).split(separator: "\n").map(String.init)
        for group in CommandGroup.allCases {
            guard let start = lines.firstIndex(of: group.rawValue) else { Issue.record("見出しがない: \(group.rawValue)"); continue }
            let end = lines[(start + 1)...].firstIndex { !$0.hasPrefix("  ") && !$0.isEmpty } ?? lines.endIndex
            let section = lines[(start + 1)..<end].joined(separator: "\n")
            for info in Help.commands where info.group == group {
                #expect(section.contains("  " + pad(info.name, to: 14) + info.summary))
            }
        }
    }
}
