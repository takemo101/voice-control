import Foundation
import VCDecision

/// 既定スキル（`default`）：どのスキルにも当てはまらない依頼を、Apple の言語モデルが、`agent-desktop` と基本のコマンドで実行する。
/// - Tiny-Jev の選択肢（`SkillRouter`）には、**入れない**（説明が広すぎて、すべての依頼を吸うため）。当てはまるスキルがないときだけ、使う。
/// - 利用者が、同じ名前（`default`）のスキルを置けば、それが使われる（許可するコマンドを広げる・狭める）。
/// - `vc skills disable default` で、使わなくなる（声の流れは、当てはまるスキルがない依頼を実行しない）。
public enum DefaultSkill {
    public static let name = "default"

    /// 既定の許可。**控えめにしてある**（削除・移動・通信・任意のスクリプトを含まない）。広げるときは、利用者が `default` スキルを置く。
    /// シェル・`sudo`・`env` などは、どのスキルでも許可できない（`CommandPolicy`）。
    public static let allowedCommands = ["agent-desktop", "open", "say", "ls", "pwd", "date"]

    /// 「操作の依頼」とみなす確率の下限。自作の 40 文で測って、決めた（`vc eval-gate corpus/gate.tsv`。コーパスを見たあとに決めたので、楽観側）。
    /// 低いのは、この判定の確率が、極端に小さく出るため（会話の文は、ほぼ 0）。
    public static let actionableThreshold = 0.05

    public static let skill = Skill(
        name: name,
        description: "どのスキルにも当てはまらない依頼を、agent-desktop と基本のコマンドで実行する（組み込み）",
        allowedCommands: allowedCommands,
        confirm: false,
        body: body,
        file: URL(string: "builtin:default")!,
        scope: .builtin)

    static let body = """
    You are a macOS computer-control assistant. Do what the user asked by calling run_command, one command at a time.

    Rules:
    - Use only these commands: agent-desktop (operates apps through accessibility), open, say, ls, pwd, date. No shell syntax (no pipes, redirects, && or ;).
    - If the request is not something these commands can do (a conversation, a question, or a thought said aloud), run no command and reply: skip: <short reason in Japanese>. A command that FAILED is not a reason to skip: read the error and fix the command.
    - To open an app: open -a "<exact app name>". The exact name is the installed app's real name (the folder name in /Applications without ".app"), NOT a nickname.
      Examples: Chrome → "Google Chrome", Edge → "Microsoft Edge", VSCode → "Visual Studio Code", Word → "Microsoft Word", Zoom → "zoom.us", Safari → "Safari".
      If you are not sure of the exact name, or open says "Unable to find application named", run `ls /Applications` (Apple's own apps: `ls /System/Applications`), pick the name that clearly matches what the user said, and run open -a "<that name>". If no installed app clearly matches, do NOT open a different app: reply failed: <the reason in Japanese>.
    - To operate an app's screen:
      1. agent-desktop snapshot -i --app "<App name>"   (lists the elements with refs such as @a1:e7)
      2. Act on exactly one element: agent-desktop click @a1:e7 | agent-desktop type @a1:e3 "text" | agent-desktop scroll @a1:e5 --direction down | agent-desktop press cmd+w
      3. Take a new snapshot to check the result before the next step.
    - Copy refs exactly as shown in the latest snapshot. Never invent a ref. If there is no ref for the target, look again or report that you could not find it.
    - Do not delete, send, buy, quit or close anything unless the user clearly asked for it.
    - Stop as soon as the request is done. Reply: done: <one short sentence in Japanese>. If you could not do it, reply: failed: <the reason in Japanese>.
    """
}

/// 依頼 → どのスキルで実行するか。
/// 1. Tiny-Jev が、有効なスキル（`default` を除く）から選ぶ。確信度が下限以上なら、そのスキル。
/// 2. 選ばれなかったら、`default` スキルがあれば、それで実行する。ただし、**操作の依頼でなければ**（会話・独り言）、実行しない。
///    取り消しにくい依頼（削除・送信・購入など）だと Tiny-Jev が見たら、実行の前に確認する。
public struct SkillResolver: Sendable {
    public struct Resolution: Sendable {
        public enum Kind: Sendable { case matched, fallback }
        public let skill: Skill
        public let kind: Kind
        /// `matched`：Tiny-Jev がそのスキルを選んだ確率。`fallback`：操作の依頼である確率。
        public let probability: Double
        /// `fallback`：取り消しにくい依頼である確率。
        public let risk: Double?
        /// 実行の前に確認する理由（確認が要らなければ `nil`）。
        public let confirmReason: String?
    }

    public enum Outcome: Sendable {
        case resolved(Resolution)
        /// 実行しない。`fallbackAvailable`：既定スキルが使える（使えなければ、当てはまるスキルがなく、実行しない）。
        case declined(reason: String, fallbackAvailable: Bool)
    }

    /// スキルが `confirm: true` のときの、確認の理由（Tiny-Jev で選んだときも、`--skill` で指定したときも、同じ文）。
    public static let confirmRequiredReason = "このスキルは、実行の前に確認が要ります"

    private let scorer: OptionScorer
    private let skills: [Skill]
    private let gate: Gate

    public init(scorer: OptionScorer, skills: [Skill], gate: Gate) {
        self.scorer = scorer
        self.skills = skills
        self.gate = gate
    }

    public func resolve(_ request: String) throws -> Outcome {
        let routed = try SkillRouter(scorer: scorer, skills: skills.filter { $0.name != DefaultSkill.name }).route(request)
        if let skill = routed.skill, routed.probability >= gate.floor {
            let reason = skill.needsConfirmation(for: request) ? skill.confirmReason(for: request) : (routed.probability < gate.execute ? "確信度が高くないので、確認します" : nil)
            return .resolved(Resolution(skill: skill, kind: .matched, probability: routed.probability, risk: nil, confirmReason: reason))
        }
        guard let fallback = skills.first(where: { $0.name == DefaultSkill.name }) else {
            return .declined(reason: "どのスキルにも当てはまらない", fallbackAvailable: false)
        }
        let actionable = try Self.actionableProbability(scorer: scorer, request: request)
        guard actionable >= DefaultSkill.actionableThreshold else {
            return .declined(reason: String(format: "操作の依頼ではない（会話・独り言）：操作の依頼である確率 %.0f%%", actionable * 100), fallbackAvailable: true)
        }
        let risk = try scorer.score(
            state: "依頼: \(request)",
            question: "この依頼は、削除・送信・購入・終了・退出など、取り消しにくい、または外へ影響する操作か",
            options: ["no", "yes"])[1]
        let reason = fallback.needsConfirmation(for: request) ? fallback.confirmReason(for: request) : (risk >= gate.destructive ? "取り消しにくい操作かもしれないので、確認します" : nil)
        return .resolved(Resolution(skill: fallback, kind: .fallback, probability: actionable, risk: risk, confirmReason: reason))
    }
}

extension SkillResolver {
    /// 発話が、パソコンやアプリを操作する依頼である確率（会話・独り言・質問・あいづちではない）。
    /// 言い方は、自作の 40 文（`corpus/gate.tsv`）で比べて選んだ：「はい／いいえ」の形は、操作の依頼を見逃した（再現 5/20）。2 つの説明から選ぶ形が、よかった。
    public static func actionableProbability(scorer: OptionScorer, request: String) throws -> Double {
        try scorer.score(
            state: "発話: \(request)",
            question: "この発話は、どちらか",
            options: ["会話・独り言・質問・あいづち", "パソコンやアプリを操作する命令"])[1]
    }
}
