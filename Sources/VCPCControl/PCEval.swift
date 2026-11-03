import Foundation
import VCDecision

/// 固定した画面での、操作の当たり率（`vc eval`・`vc eval-context`）の部品。画面（コーパス）を読む・手を文字にする・当たりを数える、だけ。表示は持たない。
///
/// コーパスの「期待」は、`open:<アプリ>`・`click:<要素名>`・`type:<文字>`・`press:<キー>`・`scroll:<向き>`・`none` など（`canonical` と同じ形）。
/// 同じ結果になる操作が複数あるときは「|」で並べる。位置つきの期待（`click:Open@右上`）は、選んだ要素の、ウィンドウの中の位置も添えて比べる。
public enum PCEval {
    // MARK: 手の文字列化

    /// 手を、コーパスの「期待」と同じ形の文字にする。
    public static func canonical(_ step: Step?) -> String {
        switch step {
        case nil: return "none"
        case .openApp(let n)?: return "open:" + n
        case .click(let e)?: return "click:" + e.name   // 位置つきの期待（「click:Open@右上」）は、`judge` が別に比べる
        case .type(let t, _)?: return "type:" + t
        case .press(let s)?: return "press:" + s.combo
        case .scroll(let d, _)?: return "scroll:" + d.rawValue
        case .window(let a, _)?: return "window:" + a.rawValue
        case .search(let q, _)?: return "search:" + q
        case .element(let v, let e)?: return v.rawValue + ":" + e.name
        case .closeApp(let n)?: return "close:" + n
        }
    }

    /// 計画の結果を、「期待」と同じ形の文字にする。ゲートが捨てたものは、「実行しない」＝ `none`。
    public static func outcome(of plan: Plan) -> String {
        plan.verdict == .reject ? "none" : canonical(plan.step)
    }

    /// 「scroll:down」「window:maximize」「press:cmd+c」「click:名前」「open:アプリ」→ `Step`（eval-context の、直前の操作）。
    public static func step(fromCanonical s: String, snapshot: Snapshot) -> Step? {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "scroll": return ScrollDirection(rawValue: parts[1]).flatMap { d in snapshot.elements.first(where: \.isScrollable).map { .scroll(d, $0) } }
        case "window": return WindowAction(rawValue: parts[1]).map { .window($0, app: snapshot.app) }
        case "press": return Shortcut.all.first { $0.combo == parts[1] }.map { .press($0) }
        case "click": return snapshot.elements.first { $0.name == parts[1] && $0.canClick }.map { .click($0) }
        case "open": return .openApp(parts[1])
        default: return nil
        }
    }

    // MARK: コーパス

    /// コーパス（TSV）の行を、`columns` 列に分ける。「#」で始まる行・空行・列の数が違う行は、飛ばす。最後の列は、タブを含んでもよい。
    public static func rows(in text: String, columns: Int) -> [[String]] {
        text.split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", maxSplits: columns - 1, omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == columns }
    }

    /// コーパスのディレクトリの `snapshots/<name>.json`。読めなければ `nil`。
    public static func snapshot(named name: String, in directory: URL) -> Snapshot? {
        // try?: 読めない理由は、呼び出し側が「読めません」として知らせる（黙って飛ばさない）
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("snapshots/\(name).json")) else { return nil }
        return try? SnapshotParser.parse(data)
    }

    /// コーパスのディレクトリの `apps.txt`（アプリ名の一覧）。なくてもよい（空の一覧）。
    public static func apps(in directory: URL) -> [String] {
        // try?: apps.txt は、なくてもよい（空の一覧で続ける）
        ((try? String(contentsOf: directory.appendingPathComponent("apps.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// 期待に書かれた、正解の操作（「|」で並べたもの）。
    public static func accepted(_ expected: String) -> [String] {
        expected.split(separator: "|").map(String.init)
    }

    // MARK: 判定

    /// 1 文の、計画と期待の比較。
    public struct Judgement: Sendable {
        public let verdict: Gate.Verdict
        /// 計画の結果（`outcome(of:)`）。
        public let got: String
        public let expected: String
        public let accepted: [String]
        /// 期待の種類（`click`・`scroll`・`none` など。`accepted` の先頭の、「:」の前）。
        public let kind: String
        public let hit: Bool
    }

    /// 計画を、期待と比べる。`snapshot`：位置つきの期待のための、ウィンドウの矩形。
    public static func judge(_ plan: Plan, expected: String, snapshot: Snapshot) -> Judgement {
        let got = outcome(of: plan)
        let accepted = accepted(expected)
        var gotRegion = got
        if case .click(let e)? = plan.step, let r = e.region(in: snapshot.window) { gotRegion = got + "@" + r }
        let kind = String(accepted[0].split(separator: ":").first ?? "none")
        return Judgement(verdict: plan.verdict, got: got, expected: expected, accepted: accepted, kind: kind, hit: accepted.contains { $0 == got || $0 == gotRegion })
    }

    /// 判定の集計。
    public struct Tally: Sendable {
        public private(set) var total = 0
        public private(set) var hits = 0
        /// 確認なしで、違う操作を実行した数。
        public private(set) var wrongExecuted = 0
        public private(set) var positives = 0
        public private(set) var positiveExecuted = 0
        public private(set) var negatives = 0
        /// 操作でない発話が、確認か実行へ通った数。
        public private(set) var negativeLeaked = 0
        public private(set) var byKind: [String: (hit: Int, total: Int)] = [:]

        public init() {}

        public mutating func record(_ j: Judgement) {
            total += 1
            byKind[j.kind, default: (0, 0)].total += 1
            if j.hit { hits += 1; byKind[j.kind]!.hit += 1 } else if j.verdict == .execute { wrongExecuted += 1 }
            if j.expected == "none" { negatives += 1; if j.verdict != .reject { negativeLeaked += 1 } }
            else { positives += 1; if j.verdict == .execute && j.hit { positiveExecuted += 1 } }
        }
    }

    /// Apple の言語モデルに、同じ文を選ばせたときの集計（`--llm`）。
    public struct LLMTally: Sendable {
        public private(set) var hits = 0
        /// 違う手を返した数（全体）。
        public private(set) var wrongAny = 0
        /// 併用で、誤って確認なしで実行した数。併用：言語モデルの手を使い、Tiny-Jev と一致して、Tiny-Jev のゲートが「実行」のときだけ、確認なしで実行する。
        public private(set) var hybridWrongExecuted = 0
        public private(set) var hybridPositiveExecuted = 0
        /// 会話に手を返した数。
        public private(set) var negativeLeaked = 0

        public init() {}

        /// 言語モデルの手（`llmGot`）を、判定（Tiny-Jev の）と比べて数える。期待と一致していれば true。
        public mutating func record(llmGot: String, against j: Judgement) -> Bool {
            let ok = j.accepted.contains(llmGot)
            if ok { hits += 1 }
            let silent = llmGot != "none" && llmGot == j.got && j.verdict == .execute
            if llmGot != "none" && !ok && silent { hybridWrongExecuted += 1 }
            if llmGot != "none" && !ok { wrongAny += 1 }
            if j.expected != "none" && ok && silent { hybridPositiveExecuted += 1 }
            if j.expected == "none" && llmGot != "none" { negativeLeaked += 1 }
            return ok
        }
    }

    /// 1 発話あたりの時間（ミリ秒）の、中央値と p95。空では呼ばない。
    public static func latency(_ millis: [Double]) -> (median: Double, p95: Double) {
        let sorted = millis.sorted()
        return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }
}
