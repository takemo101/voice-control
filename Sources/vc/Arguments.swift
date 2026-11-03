/// コマンドラインの引数（`CommandLine.arguments` の 2 番目以降）。値型で、グローバルの状態を持たない。
///
/// 読み方は、先頭から順に取り除いていく形で、次の決まりに従う（従来の `option()`・`flag()` と同じ）：
/// - `option("--x")`：最初の `--x` と、その次の 1 語を取り除いて、次の語を返す。次の語が別のオプションの名前でも、値として取る。`--x` が最後の語なら、取り除かず nil
///   （`--x` は、残ったまま、位置引数になる）。`--x=値` の形は、扱わない。
/// - `flag("--x")`：最初の `--x` を取り除いて true。なければ false。2 つ目以降は、残る。
/// - 知らないオプションは、取り除かれない。残ったものは、すべて位置引数になる（`vc plan --foo` の `--foo` は発話）。
/// - 位置引数は、取り除いたあとに残った語のうち、先頭（コマンド名）を除いたもの。だから、何を先に取り除くかで、位置引数が変わる。
struct Arguments: Equatable {
    /// まだ取り除かれていない語（先頭がコマンド名）。
    private(set) var remaining: [String]

    init(_ tokens: [String]) { remaining = tokens }

    /// コマンド名（残った語の先頭）。
    var command: String? { remaining.first }

    /// コマンド名を除いた、残りの語（`vc plan 発話` の「発話」）。
    var positionals: [String] { Array(remaining.dropFirst()) }

    /// `--x 値` の値。取り除く。
    mutating func option(_ name: String) -> String? {
        guard let i = remaining.firstIndex(of: name), i + 1 < remaining.count else { return nil }
        let value = remaining[i + 1]
        remaining.removeSubrange(i...(i + 1))
        return value
    }

    /// `--x` があるか。あれば、最初の 1 つを取り除く。
    mutating func flag(_ name: String) -> Bool {
        guard let i = remaining.firstIndex(of: name) else { return false }
        remaining.remove(at: i)
        return true
    }

    /// `--x` が残っているか（取り除かない）。
    func contains(_ name: String) -> Bool { remaining.contains(name) }
}

/// どのコマンドでも、起動の最初に取り除く共通のオプション（`vc <コマンド>` のコマンド名の前後どちらに書いてもよい）。
/// 取り除く順番は、位置引数に響く（`--app --execute` は、`--app` の値が `--execute` になる）ので、従来のまま変えない。
/// `--keys` は、コマンド名を決めたあとに取り除く（`CommandContext.make`）。
struct CommonOptions: Equatable {
    var model: String?
    var length: Int
    var app: String?
    var execute: Bool
    var yes: Bool
    var speak: Bool
    var hotkey: Bool
    var llm: Bool
    var llmSplit: Bool
    var noContext: Bool
    var noLocation: Bool
    var audio: String?
    var trigger: String?
    /// 取り除かない（`vc run` は、自分の `--dry-run` を、あとで取り除く）。
    var dryRun: Bool
    var floor: Double?

    /// 数にならない `--length`・`--floor` の値も、取り除く（既定の値を使う）。
    init(consuming arguments: inout Arguments) {
        model = arguments.option("--model")
        length = arguments.option("--length").flatMap(Int.init) ?? 1024
        app = arguments.option("--app")
        execute = arguments.flag("--execute")
        yes = arguments.flag("--yes")
        speak = arguments.flag("--speak")
        hotkey = arguments.flag("--hotkey")
        llm = arguments.flag("--llm")
        llmSplit = arguments.flag("--llm-split")
        noContext = arguments.flag("--no-context")
        noLocation = arguments.flag("--no-location")
        audio = arguments.option("--audio")
        trigger = arguments.option("--trigger")
        dryRun = arguments.contains("--dry-run")
        floor = arguments.option("--floor").flatMap(Double.init)
    }
}
