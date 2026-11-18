import Testing
@testable import VCSkill

/// 添付の規則：**コピーした文章は、外のエージェントへ渡さない**・同じものは重ねない・画像・文章がある間は、Apple の会話で Web を外す。
@Suite struct ChatAttachmentRulesTests {
    @Test func endCommandsAreRecognizedByWordsNotByTheModel() {
        for text in ["会話を終わって", "会話を終了して", "新しい会話", "新しい会話にして", "会話をリセット", "会話を、終わって。", "もう会話をやめて", "忘れて", "全部忘れて", "会話終了"] {
            #expect(ChatEndCommand.matches(text), "\(text)")
        }
        for text in ["会話の続きだけど", "東京の人口は？", "忘れ物をしないコツは？", "終わりの挨拶を考えて", "忘れていた予定を整理して", ""] {
            #expect(!ChatEndCommand.matches(text), "\(text)")
        }
    }

    private let clip = ChatAttachments.Attachment(label: "コピーした文章", body: "本文", key: "text-1")

    @Test func aCopiedTextIsNeverHandedToAnExternalAgent() {
        // 外のエージェントには、クリップボードに文章があっても、渡さない（この Mac の外へ出さない決まり）
        #expect(ChatAttachments.textPlan(agentIsExternal: true, clipboard: clip, attached: []) == .withheldFromExternal)
        #expect(ChatAttachments.textPlan(agentIsExternal: true, clipboard: nil, attached: []) == .withheldFromExternal)
        // Apple の会話：添える・なければ、なし・同じものは、重ねない
        #expect(ChatAttachments.textPlan(agentIsExternal: false, clipboard: clip, attached: []) == .attach(clip))
        #expect(ChatAttachments.textPlan(agentIsExternal: false, clipboard: nil, attached: []) == .noText)
        #expect(ChatAttachments.textPlan(agentIsExternal: false, clipboard: clip, attached: ["text-1"]) == .alreadyInConversation)
    }

    @Test func webIsTurnedOffOnlyForAnAppleConversationThatHoldsScreenOrCopiedContent() {
        #expect(ChatAttachments.suppressesWeb(agentIsExternal: false, tools: .web, conversationHasAttachments: true))
        #expect(ChatAttachments.suppressesWeb(agentIsExternal: false, tools: .all, conversationHasAttachments: true))
        #expect(!ChatAttachments.suppressesWeb(agentIsExternal: false, tools: .web, conversationHasAttachments: false))
        #expect(!ChatAttachments.suppressesWeb(agentIsExternal: false, tools: .none, conversationHasAttachments: true))   // 道具がなければ、外す物がない
        #expect(!ChatAttachments.suppressesWeb(agentIsExternal: true, tools: .web, conversationHasAttachments: true))    // 外のエージェントは、画像・文章を、会話に入れない
    }
}
