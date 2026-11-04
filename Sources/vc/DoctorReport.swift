import Foundation

/// `vc doctor` の 1 項目：使える環境か。`fail` は、スキルの実行に**必須**なものが使えない。`warn` は、任意の機能（ホットキー・声の入力など）に
/// 要るものが、まだ使えない。直す手順（`fix`）は、`ok` 以外のときだけ付く。
struct DoctorCheck {
    enum State { case ok, warn, fail }
    let name: String
    let state: State
    let detail: String
    let fix: String?

    static func ok(_ name: String, _ detail: String) -> DoctorCheck { DoctorCheck(name: name, state: .ok, detail: detail, fix: nil) }
    static func warn(_ name: String, _ detail: String, fix: String) -> DoctorCheck { DoctorCheck(name: name, state: .warn, detail: detail, fix: fix) }
    static func fail(_ name: String, _ detail: String, fix: String) -> DoctorCheck { DoctorCheck(name: name, state: .fail, detail: detail, fix: fix) }
}

/// `vc doctor` の結果。表示の整形と、終了コードの判断（必須が 1 つでも使えなければ、失敗）だけを持つ（確認そのものは、コマンドが行う）。
struct DoctorReport {
    let checks: [DoctorCheck]

    var failures: [DoctorCheck] { checks.filter { $0.state == .fail } }
    var warnings: [DoctorCheck] { checks.filter { $0.state == .warn } }
    /// 必須の項目が、使えない。警告（任意の機能）だけなら、失敗にしない。
    var hasFailure: Bool { !failures.isEmpty }

    /// 表示（行ごと）。使えない項目の下に、直す手順を添える。
    func lines() -> [String] {
        let width = (checks.map { displayWidth($0.name) }.max() ?? 0) + 2
        var out: [String] = []
        for c in checks {
            let mark: String
            switch c.state {
            case .ok: mark = Style.green("✓")
            case .warn: mark = Style.yellow("!")
            case .fail: mark = Style.red("✗")
            }
            out.append("  \(mark) " + pad(c.name, to: width) + c.detail)
            if let fix = c.fix { out.append("      " + Style.dim("→ " + fix)) }
        }
        out.append("")
        if hasFailure {
            out.append(Style.red("✗") + " スキルの実行に必要なものが、\(failures.count) 件、使えません。上の手順で直してから、もう一度 vc doctor")
        } else if warnings.isEmpty {
            out.append(Style.green("✓") + " すべて使えます")
        } else {
            out.append(Style.green("✓") + " スキルの実行（vc run）は使えます。" + Style.yellow("! \(warnings.count) 件") + "は、任意の機能（ホットキー・声の入力など）に要るものです")
        }
        return out
    }
}
