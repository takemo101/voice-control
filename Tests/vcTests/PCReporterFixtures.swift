import TestSupport
import VCDecision
import VCPCControl

/// どの発話も「どれでもない」と選ぶ（`Planner` が、実行しない判定の `Plan` を作る）。
func rejectedPlan() throws -> Plan {
    try Planner(scorer: TargetScorer(target: nil, others: 0.001), desktop: StaticDesktop()).plan("雑談")
}

let step = Step.openApp("Notes")
