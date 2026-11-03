import Foundation
import VCDecision

/// 操作する Mac。実機は `AgentDesktop`。テストは、決まった画面を返す偽物。
public protocol Desktop: Sendable {
    /// 前面のアプリの、操作できる要素。
    func snapshot() throws -> Snapshot
    /// 開けるアプリの名前（起動中と、インストール済み）。
    func apps() throws -> [String]
    func perform(_ step: Step) throws
    /// 画面（snapshot）を読めないときの、前面のアプリの名前（アプリごとのスキルの条件に使う）。分からなければ `nil`。
    func frontAppName() -> String?
}

public extension Desktop {
    func frontAppName() -> String? { nil }
}

public struct Plan: Sendable {
    /// 選んだもの（選択肢の文）と、その確率。
    public let choice: String
    public let probability: Double
    /// `nil` は、実行しない（`rejection` に理由）。
    public let step: Step?
    /// 取り消しにくい操作である確率（判断した場合）。
    public let risk: Double?
    public let verdict: Gate.Verdict
    public let rejection: String?
    /// この判断に使った採点の回数（勝ち抜き戦の回数）。
    public let rounds: Int
    /// 注意（画面を読めなかった、など）。
    public var note: String? = nil
}

/// 発話 → 1 手。画面・アプリ・ショートカット・スクロールの、**具体的な操作を全部、1 つの選択肢の一覧にして**選ぶ（「操作の種類」を先に選ぶ段は置かない：測定で、その段が最も外れた）。
public struct Planner: Sendable {
    static let question = "この発話に対応する操作はどれか"
    static let noneOption = "どれでもない（会話・独り言・報告）"
    /// アプリを開く言い方（開く・起動・立ち上げ・アクティブ・切り替え・前面・出す・見る・使う）。
    /// 直前の操作に触れる言い方（もう一回・同じ・さっき・逆・戻す・取り消す…）。このときだけ、「繰り返す・逆にする」を候補にする（なければ、あらゆる発話が「繰り返し」に引きずられた：測定）。
    static let refersToPrevious = try! NSRegularExpression(pattern: "もう一|もう少し|また|同じ|さっき|直前|逆|戻|取り消|やり直|繰り返|もう一個")
    /// アプリを終了する言い方。
    static let closesApp = try! NSRegularExpression(pattern: "終了|落と|quit|閉じ")
    /// 位置で指す言い方（上・下・左・右・中央・端・隅・一番・番目）。
    static let refersToPosition = try! NSRegularExpression(pattern: "上|下|左|右|真ん中|中央|端|隅|一番|番目")
    static let opensApp = try! NSRegularExpression(pattern: "開|起動|立ち上|アクティブ|切り替|前面|出して|見たい|見せて|使いたい")

    private let scorer: OptionScorer
    private let chooser: Chooser
    private let desktop: Desktop
    private let gate: Gate

    /// 利用者が足したキー操作（`KeyBindingCatalog`）。
    private let keyBindings: [Shortcut]

    /// 選択肢に、要素の位置（左上・右・下…）を添えるか（`--no-location` で外して、比べる）。
    private let useLocation: Bool

    public init(scorer: OptionScorer, desktop: Desktop, gate: Gate = Gate(), keyBindings: [Shortcut] = [], useLocation: Bool = true) {
        self.useLocation = useLocation
        self.keyBindings = keyBindings
        self.scorer = scorer
        chooser = Chooser(scorer: scorer)
        self.desktop = desktop
        self.gate = gate
    }

    private struct Candidate {
        let option: String
        let step: Step
        var confirm = false
    }

    private func candidates(utterance: String, history: [Executed], snapshot: Snapshot) throws -> [Candidate] {
        var out: [Candidate] = []
        // 位置：「右上のボタン」「下のOpen」のように、位置で指す依頼に答えるため、選択肢に、ウィンドウの中の位置（3 × 3）を添える。
        // 名前のない要素（アイコンだけのボタン）は、位置を指す言い方のときだけ候補にする。
        let refersToPosition = Self.refersToPosition.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)) != nil
        for e in snapshot.elements where e.canClick && (!e.name.isEmpty || refersToPosition) {
            var label = "\(Self.roleLabel(e.role))を押す: \(e.name.isEmpty ? "名前なし" : e.name)"
            if useLocation, let region = e.region(in: snapshot.window) { label += "（\(region)）" }
            out.append(Candidate(option: label, step: .click(e)))
        }
        // 状態を変える操作：その操作を持つ要素にだけ、候補を作る（available_actions による）。
        for e in snapshot.elements { for v in ElementVerb.allCases where v.applies(to: e) {
            out.append(Candidate(option: v.label(for: e), step: .element(v, e), confirm: v.needsConfirmation))
        } }
        // 画面の要素の名前が、発話に出てくるなら、矢印キー（左・右・上・下だけのキー）は、候補にしない：「左のOpenを押して」が、左矢印キーに引きずられた（測定）。
        let namesAnElement = snapshot.elements.contains { $0.name.count >= 2 && utterance.localizedCaseInsensitiveContains($0.name) }
        let arrows: Set<String> = ["up", "down", "left", "right"]
        // 「ボタン・アイコン・メニュー・タブ」と言っているなら、矢印キーではない（「下の方にある再生ボタンを押して」が、下矢印キーに引きずられた：測定）。
        let namesAWidget = utterance.contains("ボタン") || utterance.contains("アイコン") || utterance.contains("メニュー") || utterance.contains("タブ")
        for s in Shortcut.all + keyBindings where applies(s, utterance: utterance, app: snapshot.app) && !((namesAnElement || namesAWidget) && arrows.contains(s.combo)) {
            out.append(Candidate(option: "キー操作: \(s.option)", step: .press(s), confirm: s.needsConfirmation))
        }
        if let target = snapshot.elements.first(where: \.isScrollable) {
            for d in ScrollDirection.allCases { out.append(Candidate(option: d.option, step: .scroll(d, target))) }
        }
        // 文字を入れる：話した文字が取り出せて、入れる欄があるときだけ。欄が複数なら、フォーカス中のものを使う。
        if let text = TextExtractor.text(in: utterance) {
            let fields = snapshot.elements.filter(\.isTextInput)
            if let field = fields.first(where: \.isFocused) ?? fields.first {
                out.append(Candidate(option: "文字を入力する: \(text.prefix(40))", step: .type(text: text, into: field)))
            }
        }
        if let query = TextExtractor.searchQuery(in: utterance), !snapshot.app.isEmpty {
            out.append(Candidate(option: "検索する: \(query.prefix(40))", step: .search(query, app: snapshot.app)))
        }
        // ウィンドウの操作：対象は、いま前面のアプリ（直前の「Chrome を開く」で前面になったものを含む）。
        if !snapshot.app.isEmpty { for a in WindowAction.allCases { out.append(Candidate(option: a.option, step: .window(a, app: snapshot.app))) } }
        // 前の指示：「もう一回」「さっきと逆」「戻して」に答えられるよう、直前の操作を、繰り返す・逆にする候補を足す。
        if let last = history.last, Self.refersToPrevious.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)) != nil {
            if let again = last.step.rebound(to: snapshot) {
                out.append(Candidate(option: "直前の操作をもう一度する（\(again.label)）", step: again, confirm: Self.needsConfirmation(again)))
            }
            if let inverse = last.step.inverse?.rebound(to: snapshot) {
                out.append(Candidate(option: "直前の操作を逆にする（\(inverse.label)）", step: inverse, confirm: Self.needsConfirmation(inverse)))
            }
        }
        // アプリは、「開く・起動・アクティブ…」の言い方のときだけ候補にする（アプリ名を含むだけの文が、アプリを開く操作にならないように）。
        if Self.opensApp.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)) != nil {
            for name in try desktop.apps() { out.append(Candidate(option: "アプリを開く: \(name)", step: .openApp(name))) }
        }
        // アプリの終了：「終了・閉じ・落と・quit」の言い方のときだけ候補にする。必ず確認する。
        if Self.closesApp.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)) != nil {
            for name in try desktop.apps() { out.append(Candidate(option: "アプリを終了する: \(name)", step: .closeApp(name), confirm: true)) }
        }
        return out
    }

    /// `history`：これまでに実行した手（古い順）。直前の操作を、判断の文脈に使う。
    public func plan(_ utterance: String, history: [Executed] = []) throws -> Plan {
        // 画面を読めなくても（アクセシビリティ・アプリの状態による）、アプリを開く・キー操作は、できる：画面の要素を使わずに、続ける。
        var note: String?
        let snapshot: Snapshot
        do { snapshot = try desktop.snapshot() } catch {
            snapshot = Snapshot(app: desktop.frontAppName() ?? "", elements: [])
            note = "画面を読めなかった（\(error)）。画面の要素・ウィンドウ・検索は、使えない"
        }
        var result = try plan(utterance, history: history, snapshot: snapshot)
        result.note = note
        return result
    }

    private func plan(_ utterance: String, history: [Executed], snapshot: Snapshot) throws -> Plan {
        let recent = History.recent(history)
        let all = try candidates(utterance: utterance, history: recent, snapshot: snapshot)
        let rounds = chooser.rounds(for: all.count)
        // 直前の操作は、前の指示に触れる言い方のときだけ、文に添える（常に添えると、あらゆる発話が「繰り返し」に引きずられた：測定）。
        let refers = Self.refersToPrevious.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)) != nil
        let state = recent.isEmpty || !refers ? utterance : "（直前に実行した操作：\(recent.map(\.step.label).joined(separator: " → "))）\n\(utterance)"
        let pick = try chooser.pick(state: state, question: Self.question, options: all.map(\.option), none: Self.noneOption)
        guard let i = pick.index else {
            return Plan(choice: Self.noneOption, probability: pick.probability, step: nil, risk: nil, verdict: .reject, rejection: "操作の依頼ではない", rounds: rounds)
        }
        let chosen = all[i]
        var risk: Double?
        if case .click = chosen.step { risk = try destructiveProbability(utterance: utterance, what: chosen.option) }
        let verdict = gate.verdict(stages: [pick.probability], destructive: risk, forceConfirm: chosen.confirm)
        return Plan(choice: chosen.option, probability: pick.probability, step: verdict == .reject ? nil : chosen.step, risk: risk, verdict: verdict,
                    rejection: verdict == .reject ? "確信度が低い" : nil, rounds: rounds)
    }

    /// 「取り消しにくい・外へ影響する操作か」の確率（はい／いいえの選択肢）。
    func destructiveProbability(utterance: String, what: String) throws -> Double {
        let p = try scorer.score(
            state: "依頼: \(utterance)\n操作: \(what)",
            question: "この操作は、削除・送信・購入・終了・退出など、取り消しにくい、または外へ影響する操作か",
            options: ["no", "yes"])
        return p[1]
    }

    /// アプリ・発話の条件（`app`・`when`）に合うキー操作か。
    private func applies(_ s: Shortcut, utterance: String, app: String) -> Bool {
        if let want = s.app, !app.localizedCaseInsensitiveContains(want) { return false }
        // try?: 正規表現は、読み込み時（KeyBindingCatalog の検査）に確かめ済み。ここで読めなければ、条件を満たさない扱い
        if let pattern = s.when, let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)) == nil { return false }
        return true
    }

    /// 確認が要る手（タブ・ウィンドウを閉じる、など）。
    static func needsConfirmation(_ step: Step) -> Bool {
        if case .press(let s) = step { return s.needsConfirmation }
        if case .element(let v, _) = step { return v.needsConfirmation }
        if case .closeApp = step { return true }
        return false
    }

    static func roleLabel(_ role: String) -> String {
        switch role {
        case "button": return "ボタン"
        case "checkbox": return "チェックボックス"
        case "tab": return "タブ"
        case "menuitem": return "メニュー項目"
        case "link": return "リンク"
        case "radiobutton": return "ラジオボタン"
        default: return role
        }
    }
}
