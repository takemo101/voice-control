import AppKit
import Foundation
import VCCore
import VCSkill

/// 会話（`vc listen --hotkey` の会話のトリガー・`vc chat`）：**スキルを選ばずに、会話として質問できる**。古い往復は、要約して、続けられる（`ChatConversation`）。
/// 会話の記録は、**メモリだけ**（ファイル・ログに残さない）。`vc` を終えるか、「会話を終わって」と言うか、しばらく話さないと、消える。
@MainActor final class ChatMode {
    static let shared = ChatMode()
    private(set) var conversation = ChatConversation()
    /// いま使っているエージェント。`configure` で替える（替えると、会話は、新しくなる）。
    private(set) var agent = ChatAgent.apple
    /// この会話で、すでに添えた画像・文章の印（同じものは、2 度、添えない）。
    private var attached: Set<String> = []

    /// 「会話を終わる」と言ったか（言語モデルを通さず、文字で見分ける）。
    static func isEndCommand(_ utterance: String) -> Bool {
        let text = utterance.filter { !" 　、。！？!?.,".contains($0) }
        // 「会話を終わる」の言い方は、どこにあってもよい。「忘れて」は、短い発話の全体のときだけ（「忘れていた予定を…」を、終わりにしない）
        let phrases = ["会話を終わ", "会話を終了", "会話をやめ", "会話をリセット", "会話をはじめから", "新しい会話", "会話リセット", "会話終了"]
        if phrases.contains(where: text.contains) { return true }
        return ["忘れて", "全部忘れて", "すべて忘れて", "ぜんぶ忘れて"].contains(text)
    }

    /// 使うエージェントを決める（`vc listen`・`vc chat` の開始のとき）。替わったら、会話は、新しくなる（記録を、別の提供元へ、引き継がない）。
    func configure(agent: ChatAgent) {
        guard agent != self.agent else { return }
        self.agent = agent
        conversation = ChatConversation(backend: agent.makeBackend())
        attached = []
    }

    func end() async {
        await conversation.reset()
        attached = []
    }

    /// 答えの見せ方：短ければ上のパネル、長ければウィンドウ。
    static func isShort(_ answer: String) -> Bool { answer.count <= 110 && !answer.contains("\n") }

    struct Outcome { var answer: String; var notes: [String] }

    /// 1 回の質問：添付を決めて（コード）、会話に渡し、答えを返す。進み具合は `progress` で知らせる。
    func ask(_ utterance: String, engine: Engine, token: CancelToken?, progress: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        var notes: [String] = []
        var attachments: [ChatAttachments.Attachment] = []
        let wants = ChatAttachments.wants(utterance)
        if agent.isExternal && (wants.image || wants.text) {
            // 外へ出さない決まり：画像・コピーした文章は、この Mac の中のモデルにだけ渡す
            notes.append("\(agent.rawValue) には、画像・コピーした文章を渡しません（この Mac の外へ出さないため。Apple のモデルの会話では、使えます：vc chat-agent reset）")
        } else if wants.image {
            let source = ImageSource.any.resolve(for: utterance)
            switch source.materialize(for: utterance) {
            case let .success(file):
                defer { source.discard() }
                let key = "image-" + ChatAttachments.fingerprint(file)
                if attached.contains(key) { notes.append("同じ画像は、すでに会話に入っています") }
                else {
                    progress("画像を読んでいます…")
                    let digest = await Task.detached { ChatAttachments.imageAttachment(file: file, engine: engine, cancel: token) }.value
                    switch digest {
                    case let .success(attachment): attachments.append(attachment); attached.insert(attachment.key)
                    case let .failure(failure): notes.append("画像を読めませんでした（\(failure.message)）。画像なしで答えます")
                    }
                }
            case let .failure(missing): notes.append("画像がないので、画像なしで答えます（\(missing)）")
            }
        } else if wants.text {
            if let clip = TextClipboard.read(), let attachment = ChatAttachments.textAttachment(from: clip) {
                if attached.contains(attachment.key) { notes.append("同じ文章は、すでに会話に入っています") }
                else { attachments.append(attachment); attached.insert(attachment.key) }
            } else {
                notes.append("コピーした文章がないので、文章なしで答えます")
            }
        }
        progress("考えています…")
        let question = ChatAttachments.compose(question: utterance, attachments: attachments)
        let reply = try await conversation.ask(question)
        if reply.startedNew { attached = Set(attachments.map(\.key)); notes.append("しばらく話さなかったので、前の会話は終わりました") }
        if reply.compacted { notes.append("古いやり取りを、要約しました") }
        if reply.compactionFailed { notes.append("要約に失敗して、古いやり取りを忘れました") }
        return Outcome(answer: reply.text, notes: notes)
    }
}

/// コピーした文章（クリップボード）を、読むだけ（書き換えない）。
enum TextClipboard {
    static func read() -> String? { NSPasteboard.general.string(forType: .string) }
}

extension CommandContext {
    /// 会話に使うエージェント：設定（`vc chat-agent`）。なければ Apple。書き方が違えば、理由を示して終わる。
    func resolveChatAgent() -> ChatAgent {
        guard let text = currentSettings().chatAgent else { return .apple }
        guard let agent = ChatAgent.parse(text) else {
            fail("settings.json の chatAgent「\(text)」は、使えません（\(ChatAgent.allCases.map(\.rawValue).joined(separator: "・"))）。vc chat-agent で直す")
        }
        return agent
    }
}
