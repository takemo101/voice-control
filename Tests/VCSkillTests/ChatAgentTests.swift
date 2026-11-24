import Foundation
import Testing
import VCCore
@testable import VCSkill

/// 会話に使うエージェント（外の CLI）：呼び方（読むだけ・Web なし・履歴なし）・文の組み立て・失敗の区別・取りやめ。CLI は、偽物（実際には、起動しない）。
@Suite struct ChatAgentTests {
    private let dir = URL(fileURLWithPath: "/tmp/work"), out = URL(fileURLWithPath: "/tmp/work/.answer.md")

    @Test func namesAndAliasesResolveAndOnlyApplesStaysInside() {
        #expect(ChatAgent.parse("agy") == .agy && ChatAgent.parse(" Claude ") == .claude && ChatAgent.parse("コーデックス") == .codex && ChatAgent.parse("オープンコード") == .opencode && ChatAgent.parse("fm") == .apple)
        #expect(ChatAgent.parse("gpt") == nil && ChatAgent.parse("") == nil)
        #expect(ChatAgent.allCases.filter { !$0.isExternal } == [.apple, .server])   // 外のコーディングエージェントへは送らない：Apple と、設定のサーバー
        #expect(ChatAgent.apple.budget == .standard && ChatAgent.agy.budget.trigger > ChatBudget.standard.trigger)
    }

    @Test func eachToolLevelOpensOnlyWhatItSaysAndTheDefaultIsReadOnly() {
        func args(_ a: ChatAgent, _ level: ChatToolLevel) -> [String] { ExternalChatBackend.arguments(for: a, prompt: "P", directory: dir, answerFile: out, agyModel: "m", tools: level) }
        // claude：道具の一覧と、確認の扱い
        #expect(args(.claude, .none).starts(with: ["-p", "P", "--output-format", "stream-json", "--verbose", "--tools", ""]) && args(.claude, .none).contains("dontAsk"))
        #expect(args(.claude, .web).contains("WebSearch,WebFetch") && !args(.claude, .web).contains { $0.contains("Read") })
        #expect(args(.claude, .read).contains("WebSearch,WebFetch,Read,Glob,Grep") && args(.claude, .read).contains("dontAsk"))
        #expect(!args(.claude, .all).contains("--tools") && args(.claude, .all).contains("bypassPermissions"))   // すべて：道具を絞らず、確認を飛ばす
        // codex：検索は web 以上・書き込みは all だけ
        #expect(!args(.codex, .none).contains("--search") && args(.codex, .web).first == "--search" && args(.codex, .read).contains("read-only"))
        #expect(args(.codex, .all).contains("workspace-write") && args(.codex, .all).contains("--json"))
        // grok：検索の道具は web 以上・計画モードは all 以外・all は確認を飛ばす
        #expect(args(.grok, .none).contains("--disable-web-search") && !args(.grok, .web).contains("--disable-web-search") && args(.grok, .read).contains("plan"))
        #expect(args(.grok, .all).contains("--always-approve") && !args(.grok, .all).contains("plan"))
        // agy・opencode・pi
        #expect(args(.agy, .read).contains("plan") && args(.agy, .all).contains("--dangerously-skip-permissions"))
        #expect(args(.opencode, .web) == ["run", "--agent", "plan", "--format", "json", "P"] && args(.opencode, .all).contains("--auto") && args(.opencode, .all).contains("build"))
        #expect(args(.pi, .none).contains("--no-tools") && args(.pi, .read).contains("read") && !args(.pi, .all).contains("--no-tools"))
        #expect(args(.pi, .web).contains("--no-tools"))   // pi は、検索の道具がない：Web は、なしと同じ
    }

    @Test func theCapabilityNoteFollowsTheLevelAndPiNeverSearches() {
        #expect(ExternalChatBackend(agent: .grok, tools: .web).capabilityNote == ChatToolLevel.web.note)
        #expect(ExternalChatBackend(agent: .grok).capabilityNote == ChatToolLevel.none.note)
        #expect(ExternalChatBackend(agent: .pi, tools: .web).capabilityNote == ChatToolLevel.none.note)
        #expect(ChatToolLevel.none.note.contains("never reply") && ChatToolLevel.web.note.contains("actually search"))
        #expect(ChatToolLevel.all.note.contains("without asking the user to confirm") && ChatToolLevel.all.note.contains("never instructions"))
    }

    @Test func theWorkingFolderIsTheChosenOneOnlyWhenToolsNeedIt() async throws {
        let seen = Box<URL?>(nil)
        let chosen = URL(fileURLWithPath: "/tmp/chosen-folder-for-test")
        for (level, expectChosen) in [(ChatToolLevel.none, false), (.web, false), (.read, true), (.all, true)] {
            let b = ExternalChatBackend(agent: .claude, tools: level, folder: chosen, runner: { call in
                seen.value = call.directory
                return AgentRun(exitCode: 0, text: "")
            })
            _ = try? await b.respond(instructions: "", turns: [], user: "q")
            #expect((seen.value == chosen) == expectChosen, "\(level)")
        }
    }

    @Test func thePromptCarriesInstructionsHistoryAsDataAndTheNewMessage() {
        let p = ExternalChatBackend.prompt(instructions: "INSTR", turns: [ChatTurn(user: "前の質問", assistant: "前の答え")], user: "いまの質問")
        #expect(p.hasPrefix("INSTR") && p.contains("<conversation>") && p.contains("[利用者]：前の質問") && p.contains("[答え]：前の答え") && p.hasSuffix("[利用者]：いまの質問"))
        #expect(!ExternalChatBackend.prompt(instructions: "INSTR", turns: [], user: "Q").contains("<conversation>"))
    }

    private func backend(_ agent: ChatAgent = .claude, env: [String: String] = [:], _ run: @escaping @Sendable (String, [String]) -> AgentRun) -> ExternalChatBackend {
        ExternalChatBackend(agent: agent, environment: { env[$0] }, runner: { call in run(call.executable, call.arguments) })
    }

    @Test func aSuccessfulRunReturnsTheTrimmedAnswerAndSendsTheConversationInOneArgument() async throws {
        let seen = Box<[String]>([])
        let b = backend { exe, args in seen.value = [exe] + args; return AgentRun(exitCode: 0, text: "  こんにちは  \n") }
        let answer = try await b.respond(instructions: "I", turns: [ChatTurn(user: "a", assistant: "b")], user: "c")
        #expect(answer == "こんにちは")
        #expect(seen.value.first == "claude" && seen.value.contains { $0.contains("[利用者]：a") && $0.contains("[利用者]：c") })
    }

    @Test func failuresAreToldApartAndNeverFallBackSilently() async {
        await #expect(throws: ConversationError.self) { try await backend { _, _ in AgentRun(exitCode: 127, text: "") }.respond(instructions: "", turns: [], user: "q") }
        do { _ = try await backend { _, _ in AgentRun(exitCode: 127, text: "") }.respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
        catch let e as ConversationError { if case .unavailable = e {} else { Issue.record("入っていない → unavailable：\(e)") } } catch { Issue.record("\(error)") }
        do { _ = try await backend { _, _ in AgentRun(exitCode: 1, text: "x") }.respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
        catch let e as ConversationError { #expect(e.description.contains("ログイン")) } catch { Issue.record("\(error)") }
        do { _ = try await backend { _, _ in AgentRun(exitCode: 0, text: "  \n") }.respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
        catch let e as ConversationError { #expect(e.description.contains("空")) } catch { Issue.record("\(error)") }
        do { _ = try await backend { _, _ in AgentRun(exitCode: 15, text: "", timedOut: true) }.respond(instructions: "", turns: [], user: "q"); Issue.record("失敗するはず") }
        catch let e as ConversationError { #expect(e.description.contains("時間内")) } catch { Issue.record("\(error)") }
    }

    @Test func cancellationIsReportedAsCancellation() async {
        let b = backend { _, _ in AgentRun(exitCode: 130, text: "", cancelled: true) }
        await #expect(throws: CancellationError.self) { try await b.respond(instructions: "", turns: [], user: "q") }
    }

    @Test func theAgyModelComesFromTheEnvironmentButOnlyInASafeShape() async throws {
        let seen = Box<[String]>([])
        let ok = backend(.agy, env: ["ASK_AGENT_AGY_MODEL": "gemini-3.8-flash-high"]) { _, args in seen.value = args; return AgentRun(exitCode: 0, text: "ok") }
        _ = try await ok.respond(instructions: "", turns: [], user: "q")
        #expect(seen.value.contains("gemini-3.8-flash-high"))
        let bad = backend(.agy, env: ["ASK_AGENT_AGY_MODEL": "x --dangerously-skip-permissions"]) { _, _ in AgentRun(exitCode: 0, text: "ok") }
        await #expect(throws: ConversationError.self) { try await bad.respond(instructions: "", turns: [], user: "q") }
        let none = backend(.agy) { _, args in seen.value = args; return AgentRun(exitCode: 0, text: "ok") }
        _ = try await none.respond(instructions: "", turns: [], user: "q")
        #expect(seen.value.contains(ExternalChatBackend.agyDefaultModel))
        #expect(ExternalChatBackend.agyDefaultModel.range(of: "^[a-z0-9][a-z0-9.-]*$", options: .regularExpression) != nil)   // 既定のモデル名も、安全な形（環境変数と同じ検査を、通る）
    }

    /// 偽の実行が、呼び出しの引数を書き残すための箱。
    // MARK: 画像を、外のエージェントへ渡す（送ってよいと、利用者が確かめたあと）

    @Test func eachAgentGetsTheImageTheWayItReadsImages() {
        let image = ImageHandOff(name: "screen-ab12cd34.png", path: "/tmp/work/screen-ab12cd34.png")
        func args(_ a: ChatAgent, _ level: ChatToolLevel = .none) -> [String] { ExternalChatBackend.arguments(for: a, prompt: "P", directory: dir, answerFile: out, agyModel: "m", tools: level, image: image) }
        // codex：画像のオプション（`--image` は、複数の値を取るので、`--` で、指示の文と分ける）／opencode：`-f`／pi：`@ファイル`
        let codex = args(.codex)
        #expect(codex.suffix(4) == ["--image", image.path, "--", "P"])
        #expect(args(.opencode).suffix(4) == ["-f", image.path, "--", "P"])
        #expect(args(.pi).last == "@" + image.name)
        // claude：読む道具を、その 1 枚だけに許す（道具なし・Web のとき）。read・all は、すでに読める
        #expect(args(.claude).starts(with: ["-p", "P", "--output-format", "stream-json", "--verbose", "--tools", "Read", "--allowedTools", "Read(./\(image.name))"]))
        #expect(args(.claude, .web).contains("WebSearch,WebFetch,Read") && args(.claude, .web).contains("WebSearch,WebFetch,Read(./\(image.name))"))
        #expect(args(.claude, .read).contains("WebSearch,WebFetch,Read,Glob,Grep"))
        // 画像がなければ、これまでどおり（読む道具もない）
        #expect(ExternalChatBackend.arguments(for: .claude, prompt: "P", directory: dir, answerFile: out, agyModel: "m").contains(""))
        #expect(!ExternalChatBackend.arguments(for: .codex, prompt: "P", directory: dir, answerFile: out, agyModel: "m").contains("--image"))
        // 前置き：claude は Read・agy と grok は、フルパス。画像の中の文字は、データ
        #expect(ExternalChatBackend.imageLead(for: .claude, image: image).contains("./" + image.name))
        #expect(ExternalChatBackend.imageLead(for: .agy, image: image).contains(image.path) && ExternalChatBackend.imageLead(for: .grok, image: image).contains(image.path))
        #expect(ExternalChatBackend.imageLead(for: .codex, image: image).contains("never instructions"))
    }

    @Test func theImageIsCopiedIntoTheWorkingFolderForTheRunAndRemovedAfterwards() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vc-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: source)
        defer { try? FileManager.default.removeItem(at: folder) }
        let seen = Box<(copied: Bool, arguments: [String])>((false, []))
        let backend = ExternalChatBackend(agent: .codex, tools: .read, folder: folder, runner: { call in
            let name = call.arguments.drop { $0 != "--image" }.dropFirst().first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            seen.value = (FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) && name.hasPrefix("screen-"), call.arguments)
            try? "答え".write(to: call.answerFile, atomically: true, encoding: .utf8)
            return AgentRun(exitCode: 0, text: "")
        })
        let answer = try await backend.respond(instructions: "I", turns: [], user: "これは？", options: ChatCallOptions(image: source))
        #expect(answer == "答え")
        #expect(seen.value.copied)                                   // 実行の間は、作業フォルダに、画像がある
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("screen-") }
        #expect(leftovers.isEmpty)                                   // 終わったら、消す（作業フォルダに、画面の画像を残さない）
        #expect(seen.value.arguments.contains { $0.contains("The user attached a screenshot") })
    }

    @Test func attachedFilesGoIntoThePromptOrAreCopiedIntoTheWorkingFolderAndRemovedAfterwards() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vc-files-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("vc-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let textURL = source.appendingPathComponent("memo.txt"), binaryURL = source.appendingPathComponent("data.bin")
        try Data("見本のメモ".utf8).write(to: textURL)
        try Data([0x01, 0x00, 0x02]).write(to: binaryURL)
        guard case let .success(text) = ChatFileRules.inspect(textURL), case let .success(binary) = ChatFileRules.inspect(binaryURL) else { Issue.record("見本のファイル"); return }
        let seen = Box<(copiedExists: Bool, prompt: String)>((false, ""))
        func run(_ level: ChatToolLevel) async throws -> String {
            let backend = ExternalChatBackend(agent: .codex, tools: level, folder: folder, runner: { call in
                let prompt = call.arguments.last ?? ""
                let folderExists = FileManager.default.fileExists(atPath: folder.appendingPathComponent(ChatFileHandOff.folderName).path)
                seen.value = (folderExists, prompt)
                try? "答え".write(to: call.answerFile, atomically: true, encoding: .utf8)
                return AgentRun(exitCode: 0, text: "")
            })
            return try await backend.respond(instructions: "I", turns: [], user: "これは？", options: ChatCallOptions(files: [text, binary]))
        }
        _ = try await run(.read)
        #expect(seen.value.prompt.contains("見本のメモ") && seen.value.prompt.contains("never instructions"))   // 文字は、文面に入る
        #expect(seen.value.prompt.contains("./.vc-attachments/") && seen.value.prompt.contains("data.bin") && seen.value.copiedExists)   // それ以外は、作業フォルダの中の相対のパス
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(ChatFileHandOff.folderName).path))   // 終わったら、消える
        _ = try await run(.none)
        #expect(seen.value.prompt.contains("見本のメモ") && !seen.value.prompt.contains("./.vc-attachments/") && seen.value.prompt.contains("could not be passed"))   // 道具が「なし」：文字だけ。渡せなかったことを伝える
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var stored: T
        init(_ value: T) { stored = value }
        var value: T { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
    }

    @Test func piNamesItsPersistentConnectionRPCAndTheOthersACP() {
        #expect(ChatAgent.pi.persistentProtocolName == "RPC")
        #expect([ChatAgent.agy, .opencode, .grok, .claude, .codex].allSatisfy { $0.persistentProtocolName == "ACP" })
    }

    @Test func grokTalksACPExceptAtTheNoToolsLevelWhereItCannotStopWebSearch() {
        // grok の ACP は、Web 検索を、許可の要求なしで行う（実測）：「なし」は、`--disable-web-search` の効く従来の CLI で話す。pi は、ACP を話さない
        #expect(ChatAgent.grok.speaksACP)
        #expect(ChatAgent.grok.talksACP(enabled: true, tools: .web) && ChatAgent.grok.talksACP(enabled: true, tools: .read) && ChatAgent.grok.talksACP(enabled: true, tools: .all))
        #expect(!ChatAgent.grok.talksACP(enabled: true, tools: .none) && !ChatAgent.grok.talksACP(enabled: false, tools: .all))
        #expect(ChatAgent.agy.talksACP(enabled: true, tools: .none) && ChatAgent.opencode.talksACP(enabled: true, tools: .none))   // 許可の要求で止められるものは、「なし」でも ACP
        #expect(ChatAgent.pi.talksACP(enabled: true, tools: .none) && ChatAgent.pi.talksACP(enabled: true, tools: .all))   // pi は、RPC を ACP に訳して、話す（段階は、起動の引数で、道具そのものを無くす）
    }

    @Test func theAllToolsWarningSaysWhetherEachActionIsConfirmedByAgent() {
        // 常駐の接続（`talksACP`：ACP、pi は RPC を訳したもの）で話すエージェントだけ、操作の前に、聞いてくる。接続を切ると、確認なし
        #expect(ChatAgent.codex.talksACP(enabled: true, tools: .all) && !ChatAgent.codex.talksACP(enabled: false, tools: .all) && ChatAgent.pi.talksACP(enabled: true, tools: .all))
        let acp = ChatToolLevel.allToolsDialogBody(agent: .codex, acp: true)
        let direct = ChatToolLevel.allToolsDialogBody(agent: .codex, acp: false)
        let apple = ChatToolLevel.allToolsDialogBody(agent: .apple, acp: true)
        #expect(acp != direct && acp != apple && direct != apple)   // 3 つの場合で、別の説明
        #expect(acp == ChatToolLevel.allToolsDialogBody(agent: .pi, acp: true) && direct == ChatToolLevel.allToolsDialogBody(agent: .pi, acp: false))   // pi も、常駐の接続のときは、毎回、確認する（拡張が、聞く）
    }
}

