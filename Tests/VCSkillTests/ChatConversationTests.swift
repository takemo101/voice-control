import Foundation
import Testing
@testable import VCSkill

/// 会話（セッション）と、compaction（古い往復の要約）。**答えを作る側は、偽物**（モデルを使わない）：要約の計画・前の要約を渡した更新・失敗時・実際の超過・しばらく話さないと終わる、を確かめる。
@Suite struct ChatConversationTests {
    /// 偽の答える側：答えは「答え：<発言の先頭>」・要約の依頼には、「要約N」を返す（呼ばれ方を、覚える）。
    private final class FakeBackend: ChatBackend, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(instructions: String, turns: [ChatTurn], user: String)] = []
        var summaryFailures = 0
        var overflowOnce = false
        var summaryLength = 20
        private(set) var summaries = 0

        func respond(instructions: String, turns: [ChatTurn], user: String) async throws -> String {
            lock.lock()
            calls.append((instructions, turns, user))
            let isSummary = instructions == ChatConversation.summaryInstructions
            if isSummary {
                if summaryFailures > 0 { summaryFailures -= 1; lock.unlock(); throw ConversationError.failed("要約の失敗") }
                summaries += 1
                let n = summaries, length = summaryLength
                lock.unlock()
                return "要約\(n)" + String(repeating: "あ", count: max(0, length - 3))
            }
            if overflowOnce { overflowOnce = false; lock.unlock(); throw ConversationError.contextOverflow }
            lock.unlock()
            return "答え：" + String(user.prefix(8))
        }

        var chatCalls: [(instructions: String, turns: [ChatTurn], user: String)] { lock.lock(); defer { lock.unlock() }; return calls.filter { $0.instructions != ChatConversation.summaryInstructions } }
        var summaryCalls: [(instructions: String, turns: [ChatTurn], user: String)] { lock.lock(); defer { lock.unlock() }; return calls.filter { $0.instructions == ChatConversation.summaryInstructions } }
    }

    private func long(_ n: Int) -> String { String(repeating: "あ", count: n) }
    private let small = ChatBudget(trigger: 700, keepRecent: 300, summaryMaxCharacters: 200)

    // MARK: 計画（純粋）

    @Test func noCompactionWhileItFits() {
        let turns = [ChatTurn(user: "こんにちは", assistant: "こんにちは")]
        #expect(ChatCompaction.plan(turns: turns, fixedTokens: 100, incoming: 20, budget: .standard) == nil)
        #expect(ChatCompaction.plan(turns: [], fixedTokens: 100, incoming: 9999, budget: .standard) == nil)   // 往復がなければ、要約するものがない
    }

    @Test func theNewestTurnsAreKeptUpToTheBudgetAndAtLeastOneIsSummarized() {
        let turns = (1...6).map { _ in ChatTurn(user: long(100), assistant: long(100)) }   // 1 往復 ≒ 176 トークン
        let cut = ChatCompaction.plan(turns: turns, fixedTokens: 200, incoming: 50, budget: ChatBudget(trigger: 900, keepRecent: 400, summaryMaxCharacters: 200))
        // 新しいほうから 3 往復（約 528）で、keepRecent に届く → 先頭の 3 往復を要約
        #expect(cut == 3)
        let two = [ChatTurn(user: long(2000), assistant: long(2000)), ChatTurn(user: long(2000), assistant: long(2000))]
        #expect(ChatCompaction.plan(turns: two, fixedTokens: 0, incoming: 0, budget: .standard) == 1)   // 大きな往復が 2 つ：最新の 1 往復は、残す
    }

    @Test func tokenEstimateIsConservativeForJapanese() {
        #expect(ChatTokens.estimate(long(100)) == 80)
        #expect(ChatTokens.estimate(String(repeating: "a", count: 100)) == 35)
    }

    @Test func serializeLabelsTheSpeakersAndClipsLongMessages() {
        let text = ChatCompaction.serialize([ChatTurn(user: "質問", assistant: long(30))], maxCharactersPerMessage: 10)
        #expect(text.contains("[利用者]：質問") && text.contains("[答え]：") && text.contains("…（以下略）"))
    }

    @Test func statementsAreTheUsersOwnFactsNotQuestionsOrRequests() {
        #expect(ChatCompaction.statements(in: "はじめまして。私の名前はミカです。今月の予算は5万円です。") == ["私の名前はミカです", "今月の予算は5万円です"])
        #expect(ChatCompaction.statements(in: "来週の火曜日の15時に、歯医者の予約があります。") == ["来週の火曜日の15時に、歯医者の予約があります"])
        for text in ["富士山の高さは、どのくらいですか？", "春に咲く花を 3 つ挙げて。", "友達に送るメッセージを教えてください。", "運動を続ける方法は？", "短い俳句を作ってほしいです。", "【添付：コピーした文章】\n本文です。\n【添付ここまで】\n\n質問：要約して"] {
            #expect(ChatCompaction.statements(in: text).isEmpty, "\(text)")
        }
    }

    @Test func mergeDedupesAndDropsTheOldestOverTheCap() {
        #expect(ChatCompaction.merge(notes: ["あああああああ"], adding: ["あああああああ", "いいいいいいい"], maxCharacters: 100) == ["あああああああ", "いいいいいいい"])
        #expect(ChatCompaction.merge(notes: ["あああああああ", "いいいいいいい"], adding: ["ううううううう"], maxCharacters: 15) == ["いいいいいいい", "ううううううう"])
        #expect(ChatCompaction.merge(notes: [], adding: [String(repeating: "あ", count: 50)], maxCharacters: 10).count == 1)   // 1 件は、必ず残る
    }

    // MARK: 会話

    @Test func laterQuestionsSeeEarlierTurns() async throws {
        let backend = FakeBackend()
        let chat = ChatConversation(backend: backend, budget: .standard)
        _ = try await chat.ask("私の名前はミカです")
        let second = try await chat.ask("私の名前は？")
        #expect(second.text.hasPrefix("答え："))
        let calls = backend.chatCalls
        #expect(calls[0].turns.isEmpty && calls[1].turns == [ChatTurn(user: "私の名前はミカです", assistant: "答え：私の名前はミカで")])
        #expect(calls[1].instructions == ChatConversation.instructions)
        let count = await chat.turnCount
        #expect(count == 2)
    }

    @Test func whenTheConversationGrowsOldTurnsBecomeASummaryThatIsPassedAlong() async throws {
        let backend = FakeBackend()
        let chat = ChatConversation(backend: backend, budget: small)
        var compacted = 0
        for i in 1...10 {
            let reply = try await chat.ask("質問\(i)：" + long(60))
            if reply.compacted { compacted += 1 }
        }
        #expect(compacted >= 1)
        let summary = try #require(await chat.currentSummary)
        #expect(summary.hasPrefix("要約"))
        // 要約は、指示に入って渡る（以降の質問で）・古い往復は、もう渡らない
        let last = try #require(backend.chatCalls.last)
        #expect(last.instructions.contains(summary) && last.instructions.hasPrefix(ChatConversation.instructions))
        #expect(!last.turns.contains { $0.user.hasPrefix("質問1：") })
        // 要約で、記録は小さく保たれる（見積もりの上限の近く）
        let tokens = ChatTokens.estimate(last.instructions) + last.turns.reduce(0) { $0 + ChatTokens.estimate($1) }
        #expect(tokens <= small.trigger + 300)
    }

    @Test func theSecondSummaryUpdatesThePreviousOne() async throws {
        let backend = FakeBackend()
        let chat = ChatConversation(backend: backend, budget: small)
        for i in 1...16 { _ = try await chat.ask("質問\\(i)：" + long(60)) }
        let calls = backend.summaryCalls
        #expect(calls.count >= 2)
        #expect(!calls[0].user.contains("<previous-summary>"))
        #expect(calls[1].user.contains("<previous-summary>") && calls[1].user.contains("要約1"))   // 前の要約を渡して、更新させる
        let stats = await chat.stats
        #expect(stats.compactions == calls.count)
    }

    @Test func aFailedSummaryNeverStopsTheConversation() async throws {
        let backend = FakeBackend()
        backend.summaryFailures = 99
        let chat = ChatConversation(backend: backend, budget: small)
        var failed = 0
        for i in 1...10 { if try await chat.ask("質問\\(i)：" + long(60)).compactionFailed { failed += 1 } }
        let summary = await chat.currentSummary, count = await chat.turnCount
        #expect(failed >= 1)                                     // 失敗が、知らされる
        #expect(summary == nil)                                   // 不完全な要約は、保存しない
        #expect(count < 10)                                       // 古い往復は、要約なしで、落とされる（会話は、続いた）
        #expect(backend.chatCalls.count == 10)
    }

    @Test func theUsersFactsSurviveCompactionVerbatimEvenWhenTheSummaryFails() async throws {
        let backend = FakeBackend()
        backend.summaryFailures = 99
        let chat = ChatConversation(backend: backend, budget: small)
        _ = try await chat.ask("私の名前はミカです。予算は5万円です。")
        for i in 1...12 { _ = try await chat.ask("質問\\(i)：" + long(60)) }
        let notes = await chat.currentNotes
        #expect(notes == ["私の名前はミカです", "予算は5万円です"])
        let last = try #require(backend.chatCalls.last)
        #expect(last.instructions.contains("- 私の名前はミカです") && last.instructions.contains("- 予算は5万円です"))
        #expect(!last.turns.contains { $0.user.hasPrefix("私の名前は") })    // 原文は、往復としては、もう渡らない
    }

    @Test func aRealOverflowIsRecoveredByCompactingOnceAndRetrying() async throws {
        let backend = FakeBackend()
        let chat = ChatConversation(backend: backend, budget: .standard)   // 見積もりでは、要約不要
        for i in 1...4 { _ = try await chat.ask("質問\\(i)") }
        backend.overflowOnce = true
        let reply = try await chat.ask("質問5")
        let summary = await chat.currentSummary, count = await chat.turnCount
        #expect(reply.compacted && reply.text.hasPrefix("答え："))
        #expect(summary != nil && count < 5)
    }

    @Test func anOverflowWithNothingToCompactIsReported() async {
        let backend = FakeBackend()
        backend.overflowOnce = true
        let chat = ChatConversation(backend: backend, budget: .standard)
        await #expect(throws: ConversationError.contextOverflow) { try await chat.ask("最初の質問") }
    }

    @Test func tooLongASummaryIsShortenedAndFinallyCut() async throws {
        let backend = FakeBackend()
        backend.summaryLength = 1000
        let chat = ChatConversation(backend: backend, budget: small)
        for i in 1...10 { _ = try await chat.ask("質問\\(i)：" + long(60)) }
        let summary = try #require(await chat.currentSummary)
        #expect(summary.count <= small.summaryMaxCharacters * 3 / 2 + 1)
        #expect(backend.summaryCalls.contains { $0.user.contains("長すぎました") })
    }

    @Test func staleConversationsEndAfterTheIdleLimitAndResetForgetsEverything() async throws {
        let backend = FakeBackend()
        let clock = Clock()
        let chat = ChatConversation(backend: backend, budget: .standard, idleLimit: 300, now: { clock.now })
        _ = try await chat.ask("私の名前はミカです")
        clock.advance(120)
        #expect(try await chat.ask("続き").startedNew == false)
        clock.advance(301)
        let after = try await chat.ask("私の名前は？")
        #expect(after.startedNew)
        #expect(backend.chatCalls.last?.turns.isEmpty == true)    // 前の会話は、渡らない
        await chat.reset()
        let count = await chat.turnCount, summary = await chat.currentSummary, has = await chat.hasConversation
        #expect(count == 0 && summary == nil && !has)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
    }
}
