import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 声で頼む流れの、発話ごとの処理（スキルの選択と実行・確認・聞き取りに自信がないときの確認）。`VoiceSession` が使う。
enum VoiceHandlers {
    /// 確認の答え：パネルのボタンと、声の返事の、先に答えたほうが決まる（もう一方は、取りやめる）。
    @MainActor static func askByPanelOrVoice(confirmation: Confirmation, next: @escaping NextUtterance) async throws -> Bool {
        let panel = PanelAnswer()
        HUD.shared.answers.set { panel.resolve($0) }
        defer { HUD.shared.answers.set(nil) }
        // 決まったら、問いかけの読み上げを、すぐ止める：ボタン・キーで決めたとき、読み終わるのを待たずに、実行へ進む
        return try await ConfirmationRace.decide(panel: panel, silence: { SaySpeaker.shared.stop() }) {
            guard let answer = try await next() else { return false }
            return try confirmation.isYes(answer)
        }
    }

    /// **聞き取りに自信がないとき**の確認（聞き取りの確認）：聞こえた文と確信度を出して、実行するかを聞く。声で頼む以外（音声入力）は、確認しない。
    static func uncertainty(_ context: CommandContext, jev: TinyJev, chips: [String: String], fallbackChip: String) -> Uncertainty? {
        guard context.currentSettings().recheck ?? true else { return nil }
        let confirmation = Confirmation(scorer: jev)
        return Uncertainty(threshold: Recheck.threshold) { text, confidence, _, next, tag in
            if tag == VoiceMode.dictate { return true }
            let isChat = tag == VoiceMode.chat
            let chip = chips[tag] ?? fallbackChip
            say(tr("聞き間違いかもしれません。\(text)でよいですか"))
            let percent = Int((confidence * 100).rounded())
            var content = HUDContent(phase: .confirm, title: tr("聞き間違いかもしれません"), hint: isChat ? tr("確信度 \(percent)%。この内容で質問しますか？\(ConfirmGuide.howToAnswer)") : tr("確信度 \(percent)%。この内容で実行しますか？\(ConfirmGuide.howToAnswer)"), chip: chip, heard: text)
            content.choices = true
            HUD.shared.show(content)
            notice(tr("聞き取りに自信がありません（\(percent)%）。確認待ち：パネルの\(ConfirmGuide.howToAnswer)"))
            do {
                let yes = try await askByPanelOrVoice(confirmation: confirmation, next: next)
                if !yes { HUD.shared.show(HUDContent(phase: .info, title: tr("やめました"), chip: chip), hideAfter: 2.5) }
                return yes
            } catch { return false }
        }
    }

    /// 1 回の発話の処理：スキル（`SkillRunner`＋`HUDReporter`）。当てはまるスキルがなく、既定スキルも使えなければ、実行しない（`HUDReporter` が、そう出す）。確認の返事は、`next` で待つ。
    static func utterance(_ context: CommandContext, jev: TinyJev, chip: String) -> UtteranceHandler {
        let confirmation = Confirmation(scorer: jev)
        let speakResults = context.currentSettings().speakResults ?? false   // 結果の読み上げ（設定ウィンドウ > 音声）
        SaySpeaker.shared.prefer(context.currentSettings().voice)   // 読み上げの声（なければ、自動）
        return { utterance, token, next, _ in
            do {
                guard !utterance.isEmpty else {
                    notice(tr("聞き取れなかった"))
                    HUD.shared.show(HUDContent(phase: .failure, title: tr("聞き取れませんでした"), hint: tr("もう一度、はっきり話してください"), chip: chip), hideAfter: 2.5)
                    return
                }
                let skills = context.loadSkills()
                skills.reportProblems()
                let skillRunner = SkillRunner(selection: .resolve(skills: skills.enabled, scorer: jev, gate: context.gate), dryRun: context.options.dryRun, cancel: token, engine: context.engine, scorer: context.scorerProvider(loaded: jev))
                let reporter = HUDReporter(chip: chip, utterance: utterance, dryRun: context.options.dryRun, isSuperseded: { token.isSuperseded }, speakResults: speakResults)
                let planner = context.makePlanner(skills: skills.enabled)
                _ = try await PlanRunner(runner: skillRunner, planner: planner, dryRun: context.options.dryRun, cancel: token).run(utterance, reporter: reporter, confirm: {
                    try await Self.askByPanelOrVoice(confirmation: confirmation, next: next)
                })
            } catch {
                if token.isSuperseded { return }   // 新しい発話に、取って代わられた：何も出さない
                if token.isCancelled || error is CancellationError { VoiceUI.showCancelled(chip: chip) } else { VoiceUI.showFailure(error, chip: chip) }
            }
        }
    }
}

/// 聞き取りの確認の、決まり（設定 `recheck`。設定ウィンドウで、切り替える）。
enum Recheck {
    /// 確信度が、これ未満なら、確認する。自作の合成音声で決めた（聞き違い 11 件のうち 5 件を捕まえ、正しい 9 件は、1 件も止めなかった）。実際の声での、調整は、これから。
    static let threshold = 0.90
}
