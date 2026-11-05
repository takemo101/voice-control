/// コマンドラインの引数（`CommandLine.arguments` の 2 番目以降）。値型で、グローバルの状態を持たない。
///
/// 読み方は、先頭から順に取り除いていく形で、次の決まりに従う：
/// - `option("--x")`：最初の `--x` と、その次の 1 語を取り除いて、次の語を返す。次の語が別のオプションの名前でも、値として取る。`--x` が最後の語なら、取り除かず nil
///   （`--x` は、残ったまま、位置引数になる）。`--x=値` の形は、扱わない。
/// - `flag("--x")`：最初の `--x` を取り除いて true。なければ false。2 つ目以降は、残る。
/// - 知らないオプションは、取り除かれない。残ったものは、すべて位置引数になる（`vc run --foo` の `--foo` は、位置引数）。
/// - 位置引数は、取り除いたあとに残った語のうち、先頭（コマンド名）を除いたもの。だから、何を先に取り除くかで、位置引数が変わる。
struct Arguments {
    /// まだ取り除かれていない語（先頭がコマンド名）。
    private(set) var remaining: [String]

    init(_ tokens: [String]) { remaining = tokens }

    /// コマンド名（残った語の先頭）。
    var command: String? { remaining.first }

    /// コマンド名を除いた、残りの語（`vc run 依頼` の「依頼」）。
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
/// 取り除く順番は、位置引数に響く（`--length --yes` は、`--length` の値が `--yes` になる）ので、この順番で固定する（テストが確かめる）。
struct CommonOptions {
    var model: String?
    var length: Int
    var yes: Bool
    var hotkey: Bool
    var trigger: String?
    /// 取り除かない（`vc run` は、自分の `--dry-run` を、あとで取り除く）。
    var dryRun: Bool
    var floor: Double?
    /// スキルを実行するモデル（`apple` か `ollama:<モデル>`）。解釈は `CommandContext.engine`。
    var engine: String?
    /// 使う音声認識（`apple` か、ダウンロードしたモデルの ID）。解釈は `CommandContext.speechChoice`。
    var stt: String?
    /// 音声入力のトリガー（`vc listen --hotkey` で、声で頼むのとは別のトリガーで、音声入力を切り替える。`vc hotkey set-dictate` で、常にそうする）。
    var dictateTrigger: String?

    /// 数にならない `--length`・`--floor` の値も、取り除く（既定の値を使う）。
    init(consuming arguments: inout Arguments) {
        model = arguments.option("--model")
        length = arguments.option("--length").flatMap(Int.init) ?? 1024
        yes = arguments.flag("--yes")
        hotkey = arguments.flag("--hotkey")
        trigger = arguments.option("--trigger")
        dryRun = arguments.contains("--dry-run")
        floor = arguments.option("--floor").flatMap(Double.init)
        engine = arguments.option("--engine")
        stt = arguments.option("--stt")
        dictateTrigger = arguments.option("--dictate-trigger")
    }
}
