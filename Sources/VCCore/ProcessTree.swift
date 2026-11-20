import Darwin
import Foundation

/// **子プロセスごと止める**。コマンドやエージェント（`bash`・`osascript` などを起こす）を止めるとき、起こした**子孫も**止める。
/// `Process.terminate()` は、同じプロセスグループの子孫までは止めるが、**自分のセッション・グループへ外れた子孫**（`detached` で起こしたもの・`setsid`）は、残って動き続ける（実測：外れた孫が、`close` のあとも、生きていた）。
/// 止め方：先に子孫の一覧を集め（親が死ぬと、孫は、親を失って、たどれなくなる）、全員に SIGTERM → 猶予のあとも生きていれば SIGKILL。**番号の使い回し**で、関係のないプロセスを止めないよう、**起動した時刻が、一覧を集めたときと同じ**ものだけに送る。
/// 対象は、**自分が起こしたプロセスの子孫だけ**（それ以外の番号に、シグナルを送らない）。
public enum ProcessTree {
    /// 番号と、起動した時刻（使い回しの見分け）。
    struct Member: Equatable {
        let pid: pid_t
        let started: UInt64
    }

    /// `pid` の子孫の番号（孫・その先も。`pid` 自身は、含まない）。
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var pending = [pid]
        while let current = pending.popLast() {
            for child in children(of: current) where child != pid && !found.contains(child) {
                found.append(child)
                pending.append(child)
            }
        }
        return found
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 512)
        let written = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        guard written > 0 else { return [] }
        return buffer.filter { $0 > 0 }   // 戻り値は、バイト数か個数（版による）：0 の余白を除いて、番号だけ取る
    }

    /// 起動した時刻（マイクロ秒）。もう、いなければ nil。
    private static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static func member(_ pid: pid_t) -> Member? { startTime(of: pid).map { Member(pid: pid, started: $0) } }

    /// 同じプロセスが、まだ生きていれば、SIGKILL を送る（別のプロセスに、番号が使い回されていたら、送らない）。
    private static func killIfStillThere(_ members: [Member]) {
        for member in members where startTime(of: member.pid) == member.started { kill(member.pid, SIGKILL) }
    }

    /// `process` と、その子孫を、止める。**待たずに戻る**：SIGTERM をすぐ送り、`grace` 秒のあとも生きているものに、SIGKILL を送る（裏で）。
    public static func terminate(_ process: Process, grace: TimeInterval = 1.0) {
        let members = signalTerm(process)
        guard !members.isEmpty else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { killIfStillThere(members) }
    }

    /// 同じことを、**待って**行う（アプリの終了時：裏の処理が、動く前に、終わってしまうため）。
    public static func terminateAndWait(_ process: Process, grace: TimeInterval = 0.3) {
        let members = signalTerm(process)
        guard !members.isEmpty else { return }
        Thread.sleep(forTimeInterval: grace)
        killIfStillThere(members)
    }

    /// 子孫の一覧を集めて（先に）、`process` と子孫に SIGTERM を送る。送った相手（SIGKILL の対象）。
    private static func signalTerm(_ process: Process) -> [Member] {
        let root = process.processIdentifier
        guard root > 0 else { return [] }
        let family = descendants(of: root) + (process.isRunning ? [root] : [])   // 集めてから、止める
        let members = family.compactMap(member)
        if process.isRunning { process.terminate() }
        for member in members where member.pid != root { kill(member.pid, SIGTERM) }
        return members
    }
}
