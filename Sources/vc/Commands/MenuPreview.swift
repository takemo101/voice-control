import AppKit
import Foundation
import VCCore

/// `vc menu-preview`：メニューバーのメニューを、**自作の状態**で開いて見せる（見た目の確認用。開発用）。直近の入力は、作り物の文を入れる（履歴・設定は、触らない）。
struct MenuPreviewCommand: Command {
    static let info = CommandInfo(
        name: "menu-preview", group: .evaluation, summary: "メニューバーのメニューを、自作の状態で開いて見せる（見た目の確認用）",
        usage: ["vc menu-preview [--state <listening|starting|stopped>] [--seconds <秒>] [--submenu]"],
        details: ["メニューバーに、一時的に、項目を出して、メニューを開く（--seconds のあと、終わる）。撮るときは、メニューのウィンドウだけを、ウィンドウ番号で撮る。"],
        options: [("--state <状態>", "聞いている（既定）・準備中・止まっている"), ("--seconds <秒>", "開いている長さ（既定 15）"), ("--submenu", "「音声入力（マイク）」の中身を開く")],
        examples: ["vc menu-preview --state stopped"])

    @MainActor func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        let seconds = arguments.option("--seconds").flatMap(Double.init) ?? 15
        let submenu = arguments.flag("--submenu")
        let state: AppRuntime.State
        switch arguments.option("--state") ?? "listening" {
        case "starting": state = .starting
        case "stopped": state = .stopped(reason: "マイクの許可がありません（設定 > 一般）")
        default: state = .listening(hint: "Shift：声で頼む ・ ⌥：会話")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        RecentDictations.shared.add("明日の会議は午後4時からです。")
        RecentDictations.shared.add("資料は、事前に送ってください。")
        let menu = StatusMenu(runtime: AppRuntime.shared)
        menu.previewState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { submenu ? menu.openDictationForPreview() : menu.openForPreview() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        NSApplication.shared.run()
    }
}
