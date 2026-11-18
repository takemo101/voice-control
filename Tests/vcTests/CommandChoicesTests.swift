import Testing
import VCCore
import VCSkill
@testable import vc

/// 設定の書き間違いは、メニューバーのアプリを終わらせず、**起動の問題（直せるページつき）**として返る。
@Suite struct CommandChoicesTests {
    private func context(engine: String? = nil, stt: String? = nil) -> CommandContext {
        var arguments = Arguments([engine.map { ["--engine", $0] } ?? [], stt.map { ["--stt", $0] } ?? []].flatMap { $0 })
        return CommandContext(options: CommonOptions(consuming: &arguments))
    }

    @Test func aMisspeltEngineInSettingsIsAProblemThatPointsToTheModelsPage() {
        var settings = Settings(); settings.engine = "ollama"   // `ollama:<モデル>` の形でない
        #expect(throws: StartupProblem.self) { try context().resolveEngine(settings: settings) }
        do { _ = try context().resolveEngine(settings: settings) } catch let problem as StartupProblem { #expect(problem.page == .models && problem.description.hasPrefix("settings.json の engine")) } catch { Issue.record("\(error)") }
        // 引数の `--engine` の書き間違いは、設定のページでは、直せない
        do { _ = try context(engine: "ollama").resolveEngine(settings: Settings()) } catch let problem as StartupProblem { #expect(problem.page == nil) } catch { Issue.record("\(error)") }
        #expect((try? context().resolveEngine(settings: Settings())) == .apple)
    }

    @Test func aMisspeltSpeechModelOrChatAgentIsAProblemToo() {
        var settings = Settings(); settings.stt = "no-such-model"
        do { _ = try context().resolveSpeechChoice(settings: settings) } catch let problem as StartupProblem { #expect(problem.page == .models) } catch { Issue.record("\(error)") }
        var agent = Settings(); agent.chatAgent = "no-such-agent"
        do { _ = try context().resolveChatAgent(settings: agent) } catch let problem as StartupProblem { #expect(problem.page == .chat && problem.description.contains("no-such-agent")) } catch { Issue.record("\(error)") }
        #expect((try? context().resolveChatAgent(settings: Settings())) == .apple)
    }

    @Test func aMisspeltKeyIsAProblemThatPointsToTheKeysPage() throws {
        for set in [{ (s: inout Settings) in s.hotkey = "no-such-key" }, { (s: inout Settings) in s.chatHotkey = "no-such-key" }, { (s: inout Settings) in s.dictateHotkey = "no-such-key" }, { (s: inout Settings) in s.shotHotkey = "no-such-key" }] {
            var settings = Settings(); set(&settings)
            do { _ = try context().resolveKeys(settings: settings); Issue.record("書き間違いが、通った") } catch let problem as StartupProblem { #expect(problem.page == .keys) } catch { Issue.record("\(error)") }
        }
        let ok = try context().resolveKeys(settings: Settings())   // 何も設定しなければ、既定のトリガーだけ
        #expect(ok.listen.source == "既定" && ok.dictate == nil && ok.chat == nil && ok.shot == nil)
    }
}

