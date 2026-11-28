import AppKit
import Foundation
import VCCore

/// `vc transcript-preview`：文字起こしのウィンドウを、**自作の音**（`say`）で、動かして見せる（見た目・動作の確認用。開発用。履歴は、設定どおり：テストでは、一時の `VC_HOME` を使う）。
struct TranscriptPreviewCommand: Command {
    static let info = CommandInfo(
        name: "transcript-preview", group: .evaluation, summary: "文字起こしのウィンドウを、自作の音（say）で動かして見せる（見た目・動作の確認用）",
        usage: ["vc transcript-preview [--say <文>] [--seconds <秒>] [--demo [--summary]]"],
        details: ["本物の文字起こしのウィンドウを出し、すぐ開始して、--say の文を鳴らす（自分の音で試す）。--seconds のあと、止めて、終わる。画面収録の許可が、まだなら、OS の確認が出る。"],
        options: [("--say <文>", "鳴らす文"), ("--seconds <秒>", "動かす長さ（既定 20）"), ("--demo", "取り込まず、作り物の文を並べて、パネルの見た目だけを見る"), ("--summary", "（--demo と）要約の面を開く")],
        examples: ["vc transcript-preview --say \"今日はいい天気ですね。明日の会議は午後4時からです。\""])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let spoken = arguments.option("--say")
        let seconds = arguments.option("--seconds").flatMap(Double.init) ?? 20
        NSApplication.shared.setActivationPolicy(.accessory)
        TranscriptWindow.shared.show()
        if arguments.flag("--demo") {
            let base = Date().addingTimeInterval(-900)
            func entry(_ seconds: Double, _ text: String, me: Bool = false, raw: String? = nil) -> TranscriptLog.Entry { .init(id: UUID(), date: base.addingTimeInterval(seconds), speaker: me ? .me : .others, start: seconds, end: seconds + 4, text: text, raw: raw) }
            TranscriptWindow.shared.session.seed(TranscriptLog(entries: [
                entry(0, "それでは、来週のリリースについて、確認します。"),
                entry(7, "テストは、水曜日までに終わる予定です。"),
                entry(12, "ただ、一つだけ、気になる点があります。"),
                entry(20, "はい、お願いします。", me: true),
                entry(26, "テストの結果は、いつ共有できますか。", me: true),
                entry(420, "明日の会議は午後4時からです。", raw: "えーと明日の会議はあの午後4時からです"),
                entry(431, "資料は、事前に送ってください。"),
                entry(440, "質問があれば、チャットに書いてください。"),
            ], tentative: [.others: "それから、来週の予定も", .me: "了解です"], meetingStart: base), summaries: [
                MeetingSummary(date: Date(), scope: .all, text: "### 要点\n- 来週のリリースの確認。**テストは水曜まで**に終わる予定。\n\n### 決まったこと\n- 資料は、事前に送る。\n  - 担当は、自分。\n\n### 確認事項\n- テスト結果を、いつ共有できるか。\n\n| 項目 | 日程 |\n|---|---|\n| リリース | 3 日 |\n| テスト | 水曜まで |"),
                MeetingSummary(date: Date(), scope: .focus("日程"), text: "- テストは水曜まで\n- 会議は午後 4 時から"),
            ])
            if arguments.flag("--summary") { TranscriptWindow.shared.openSummaryTabForPreview() }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
            NSApplication.shared.run()
            return
        }
        // 画面のループの中で動かす（ここは、ループを回す前：ここで、`await` する仕事は、ループが回るまで、進まない）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                _ = Task { @MainActor in
                    TranscriptWindow.shared.toggleFromShortcut()   // ショートカットと、同じ道（上のパネル・真ん中のチャットのパネル）
                    while !TranscriptWindow.shared.session.isActive { try? await Task.sleep(for: .milliseconds(100)) }
                    if let spoken {
                        let say = Process()
                        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                        say.arguments = ["-v", "Kyoko", spoken]
                        try? say.run()   // try?: 鳴らせなくても、確認は、続ける
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                _ = Task { @MainActor in
                    await TranscriptWindow.shared.session.stop()
                    // 止めたあとの後始末（要約・保存）が、終わるまで待つ（確認用）
                    for _ in 0..<600 { if case .working = TranscriptWindow.shared.session.wrapUp { try? await Task.sleep(for: .milliseconds(100)) } else { break } }
                    let session = TranscriptWindow.shared.session
                    print("  後始末：\(session.wrapUp)・要約：\(session.summaries.map { $0.text.count })・要約の状態：\(session.summaryState)")
                    exit(0)
                }
            }
        }
        NSApplication.shared.run()
    }
}
