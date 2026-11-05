import Foundation
import VCDecision

/// 直前の候補（`vc find` の結果・直前のコマンドの出力の行）：`vc pick` が、選ぶ相手。1 回の実行の中だけ（記憶は、プロセスの外へ出さない・ファイルに残さない）。
/// `@unchecked Sendable` の理由：可変な状態（`entries`）は、すべて `lock` で守る。
final class OptionMemory: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        /// 選択（Tiny-Jev）に渡す、短い 1 行。
        let line: String
        /// 選んだときに、添える情報（ファイルのフルパスなど）。
        let detail: String?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func set(_ new: [Entry]) { lock.lock(); entries = new; lock.unlock() }
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    /// コマンドの出力の、空でない行（`maxLines` まで）を、候補にする。
    func setLines(from output: String, maxLines: Int = 200) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set(lines.prefix(maxLines).map { Entry(line: $0, detail: nil) })
    }
}

/// スキルの実行の中で、`vc` 自身が処理するコマンド：`vc find`（ファイルの検索）・`vc pick`（Tiny-Jev での選択）。モデルが呼ぶ（スキルの `allowed-commands` に書く。許可の照合は、ほかのコマンドと同じ）。
/// **外のプロセスは起こさない**（`vc` の実行ファイルを、呼び直さない：Tiny-Jev を、読み直さずに済み、検索の引数は、決まった形で受ける）。
struct InternalCommands {
    /// 依頼の文（`vc pick` が、何を選ぶかの、既定）。
    let request: String
    /// Tiny-Jev（使うときまで、読み込まない）。
    let scorer: (@Sendable () -> OptionScorer?)?
    let memory: OptionMemory
    var spotlight: FileSearch.Spotlight = FileSearch.live

    static func handles(_ argv: [String]) -> Bool { argv.count >= 2 && argv[0] == "vc" && ["find", "pick"].contains(argv[1]) }

    /// 終了コードと、モデルへ返す文。
    func run(_ argv: [String]) -> (exitCode: Int32, output: String) {
        let arguments = Array(argv.dropFirst(2))
        return argv[1] == "find" ? find(arguments) : pick(arguments)
    }

    // MARK: vc find

    /// 画面・言語モデルへ返す候補の数（多いと、入力に入らない）。残りは、`vc pick` が、選ぶ。
    static let shownCandidates = 15

    private func find(_ arguments: [String]) -> (Int32, String) {
        let query: FileQuery
        do { query = try FileSearch.parse(arguments) } catch { return (2, "error: \(error)") }
        let found = FileSearch.search(query, spotlight: spotlight)
        memory.set(found.map { FileCandidate in .init(line: FileCandidate.line(), detail: FileCandidate.path) })
        var text = FileSearch.render(Array(found.prefix(Self.shownCandidates)))
        if found.count > Self.shownCandidates { text += "\n(+\(found.count - Self.shownCandidates) more. Run: vc pick   to choose among all \(found.count))" }
        else if found.count > 1 { text += "\nTo choose the one that fits the user's request, run: vc pick" }
        return (0, text)
    }

    // MARK: vc pick

    private func pick(_ arguments: [String]) -> (Int32, String) {
        var query = request
        var options: [String] = []
        var threshold = Picker.defaultThreshold
        var top = 5
        var i = 0
        func value(_ flag: String) -> String? { i += 1; return i < arguments.count ? arguments[i] : nil }
        while i < arguments.count {
            let flag = arguments[i]
            switch flag {
            case "--query": guard let v = value(flag) else { return (2, "error: --query needs a text") }; query = v
            case "--option": guard let v = value(flag) else { return (2, "error: --option needs a text") }; options.append(v)
            case "--threshold": guard let v = value(flag), let t = Double(v), (0...1).contains(t) else { return (2, "error: --threshold needs a number 0-1") }; threshold = t
            case "--top": guard let v = value(flag), let n = Int(v), (1...20).contains(n) else { return (2, "error: --top needs a number 1-20") }; top = n
            case "--from-last": break   // 既定（--option がなければ、直前の候補）
            default: return (2, "error: unknown option \(flag) (--query, --option, --threshold, --top, --from-last)")
            }
            i += 1
        }
        // 候補：--option、なければ、直前の候補（`vc find` の結果・直前のコマンドの出力）
        let entries = options.isEmpty ? memory.all : options.map { OptionMemory.Entry(line: $0, detail: nil) }
        guard !entries.isEmpty else { return (1, "error: no options. Give --option <text> (repeatable), or run a command that prints candidates first (for example: vc find).") }
        guard !query.isEmpty else { return (2, "error: no query (--query <text>)") }
        guard let scorer = scorer?() else { return (1, "error: Tiny-Jev is not available (vc model download)") }
        do {
            let result = try Picker.pick(query: query, options: entries.map(\.line), threshold: threshold, scorer: scorer)
            var text = Picker.format(result, options: entries.map(\.line), top: top)
            // 添える情報（フルパス）：選んだもの・上位の候補に付ける
            let details = result.ranked.prefix(top).compactMap { $0.index }.compactMap { i in entries[i].detail.map { "\(i + 1)) \($0)" } }
            if !details.isEmpty { text += "\npaths:\n" + details.joined(separator: "\n") }
            return (0, text)
        } catch { return (1, "error: \(error)") }
    }
}

/// `vc find`・`vc pick` を、スキルの外（端末）から使う入口（同じ処理）。
public enum ToolCommands {
    public static func find(_ arguments: [String]) -> (exitCode: Int32, output: String) {
        InternalCommands(request: "", scorer: nil, memory: OptionMemory()).run(["vc", "find"] + arguments)
    }

    /// `stdinText`：標準入力の文字（`--option` がなければ、この行を、候補にする）。
    public static func pick(_ arguments: [String], stdinText: String?, scorer: @escaping @Sendable () -> OptionScorer?) -> (exitCode: Int32, output: String) {
        let memory = OptionMemory()
        if let stdinText { memory.setLines(from: stdinText) }
        return InternalCommands(request: "", scorer: scorer, memory: memory).run(["vc", "pick"] + arguments)
    }
}
