import Foundation
import VCCore

/// 「会話を終わる」の言い方（言語モデルを通さず、文字で見分ける）。
public enum ChatEndCommand {
    public static func matches(_ utterance: String) -> Bool {
        let text = utterance.filter { !" 　、。！？!?.,".contains($0) }
        // 「会話を終わる」の言い方は、どこにあってもよい。「忘れて」は、短い発話の全体のときだけ（「忘れていた予定を…」を、終わりにしない）
        if AppLanguage.allChatEndPhrases.contains(where: text.contains) { return true }
        return AppLanguage.allChatForgetPhrases.contains(text)   // 言い方は、言語ごと：`LanguageProfile`
    }
}

/// 添付（画像・文章）の、**外へ出さない・会話に重ねない**規則（**純粋**。クリップボードの読み取り・ファイル・確認は、呼ぶ側 `ChatMode` が行う）。
extension ChatAttachments {
    /// コピーした文章を、どうするか。
    public enum TextPlan: Equatable, Sendable {
        /// 外のエージェントには、渡さない（**この Mac の外へ出さない決まり**。Apple のモデルの会話だけ、使える）。
        case withheldFromExternal
        /// コピーした文章がない（または、空）。
        case noText
        /// すでに会話に入っている（2 度、添えない）。
        case alreadyInConversation
        case attach(Attachment)
    }

    /// - `clipboard`：コピーした文章を、添付にしたもの（`textAttachment(from:)`）。**外のエージェントのときは、呼ぶ側が、読まなくてよい**（渡さないので）。
    /// - `attached`：すでに会話に添えたものの印。
    public static func textPlan(agentIsExternal: Bool, clipboard: Attachment?, attached: Set<String>) -> TextPlan {
        if agentIsExternal { return .withheldFromExternal }
        guard let clipboard else { return .noText }
        return attached.contains(clipboard.key) ? .alreadyInConversation : .attach(clipboard)
    }

    /// 会話の途中で、Web の道具を外すか。**Apple の会話で、画像・コピーした文章が、会話に入っている間**：画面の内容が、モデルの作る検索語に混ざって、外へ出ないため。
    public static func suppressesWeb(agentIsExternal: Bool, tools: ChatToolLevel, conversationHasAttachments: Bool) -> Bool {
        !agentIsExternal && tools != .none && conversationHasAttachments
    }
}
