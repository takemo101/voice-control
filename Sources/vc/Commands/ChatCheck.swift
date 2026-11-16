import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 会話の「確認」の経路を、**実際のエージェント**で試す（開発用）：声の流れと同じ `ChatVoice.handle`・本物の確認のパネル・本物の会話のウィンドウ。
/// 自作のフォルダに、ファイルを作る依頼をして、確認のパネルが出るのを待ち、ボタンの答え（`AnswerRoute.deliver`）か、Esc（取りやめ）を、送る。画面の中央にウィンドウ、上にパネルが出る。
struct ChatCheckCommand: Command {
    static let info = CommandInfo(
        name: "chat-check", group: .evaluation, summary: "会話の確認パネルの経路を、実際のエージェントで試す（自作のフォルダ・自作の質問。画面にパネルとウィンドウが出る）",
        usage: ["vc chat-check [--agent agy] [--scenario yes,no,esc,hidden,run] [--folder <フォルダ>]"],
        details: ["道具は「すべて」。シナリオ：yes＝パネルで許可・no＝パネルで断る・esc＝確認を待つ間に取りやめ（Esc）・hidden＝会話のウィンドウを閉じてから許可・run＝コマンド（ls）の実行を、パネルで許可。シナリオごとに、作ったファイルの有無を出す。同じエージェントの接続で、続けて試す。"],
        options: [("--agent <名前>", "既定 agy"), ("--scenario <名前,…>", "既定 yes,no,esc,hidden"), ("--folder <フォルダ>", "作業フォルダ（既定：一時のフォルダ）")],
        examples: ["vc chat-check", "vc chat-check --scenario yes"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        var arguments = arguments
        guard let agent = ChatAgent.parse(arguments.option("--agent") ?? "agy"), agent.isExternal else { usageError("chat-check", "--agent は、外のエージェントを指定してください") }
        let scenarios = (arguments.option("--scenario") ?? "yes,no,esc,hidden").split(separator: ",").map(String.init)
        let folder = arguments.option("--folder").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("vc-chat-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let jev = context.loadJev()
        let confirmation = Confirmation(scorer: jev)
        ChatMode.shared.scorer = jev
        ChatMode.shared.configure(agent: agent, tools: .all, folder: folder)
        setvbuf(stdout, nil, _IOLBF, 0)   // 行ごとに出す（撮影のスクリプトが、PANEL の行を、すぐ見られるように）
        NSApplication.shared.setActivationPolicy(.accessory)
        HUD.shared.warmUp()
        Task { @MainActor in
            let waitForever: NextUtterance = { try await Task.sleep(for: .seconds(86_400)); return nil }
            print("作業フォルダ：\(folder.path)")
            for name in scenarios {
                let file = folder.appendingPathComponent("check-\(name).txt")
                try? FileManager.default.removeItem(at: file)
                let token = CancelToken()
                let started = Date()
                print("\n■ シナリオ \(name)")
                let task = Task { @MainActor in
                    await ChatVoice.handle(name == "run" ? "ls コマンドで、この作業フォルダの一覧を取って、結果を教えて" : "check-\(name).txt というファイルを作って、中身は hi にして", token: token, context: context, chip: "確認", speakResults: false, confirmation: confirmation, next: waitForever, cancelHook: nil)
                }
                // 確認のパネルが出る（答えを待つ）まで、待つ
                var waited = 0.0
                while !HUD.shared.answers.isWaiting, waited < 120 { try? await Task.sleep(for: .milliseconds(200)); waited += 0.2 }
                guard HUD.shared.answers.isWaiting else { print("PANEL なし（\(Int(waited)) 秒待ったが、確認のパネルが出なかった）"); task.cancel(); continue }
                print("PANEL 確認のパネルが出た（\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒）")
                try? await Task.sleep(for: .milliseconds(2500))   // 画面を撮れるように、少し見せる
                switch name {
                case "yes", "run": HUD.shared.answers.deliver(true); print("→ パネルで、許可")
                case "no": HUD.shared.answers.deliver(false); print("→ パネルで、断る")
                case "esc": token.cancel(); task.cancel(); print("→ 確認を待つ間に、取りやめ（Esc）")
                case "hidden":
                    ChatWindow.shared.hide(); print("→ 会話のウィンドウを閉じた")
                    try? await Task.sleep(for: .milliseconds(500))
                    HUD.shared.answers.deliver(true); print("→ パネルで、許可")
                default: print("知らないシナリオ"); task.cancel()
                }
                let finished = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { await task.value; return true }
                    group.addTask { try? await Task.sleep(for: .seconds(90)); return false }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                let made = FileManager.default.fileExists(atPath: file.path)
                print("結果：\(finished ? "処理は終わった" : "90 秒たっても終わらない")・ファイルを作った：\(made ? "はい" : "いいえ")・パネルの待ち：\(HUD.shared.answers.isWaiting ? "残っている" : "解けた")・待ち時間 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒")
                try? await Task.sleep(for: .milliseconds(1500))
            }
            print("\n終わり")
            exit(0)
        }
        NSApplication.shared.run()
    }
}
