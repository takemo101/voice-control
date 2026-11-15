import AppKit
import Foundation
import VCCore
import VCSkill

/// 会話（声の入力 の会話のトリガー・`vc chat`）：**スキルを選ばずに、会話として質問できる**。古い往復は、要約して、続けられる（`ChatConversation`）。
/// 会話の記録は、**メモリだけ**（ファイル・ログに残さない）。`vc` を終えるか、「会話を終わって」と言うか、しばらく話さないと、消える。
@MainActor final class ChatMode {
    static let shared = ChatMode()
    private(set) var conversation = ChatConversation()
    /// いま使っているエージェント。`configure` で替える（替えると、会話は、新しくなる）。
    private(set) var agent = ChatAgent.apple
    /// 外のエージェントに開けている道具の段階と、作業フォルダ。
    private(set) var tools = ChatToolLevel.none
    private(set) var folder: URL?
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

    /// 使うエージェントを決める（声の入力・`vc chat` の開始のとき）。替わったら、会話は、新しくなる（記録を、別の提供元へ、引き継がない）。
    func configure(agent: ChatAgent, tools: ChatToolLevel = .none, folder: URL? = nil) {
        let tools = agent.effective(tools)
        guard agent != self.agent || tools != self.tools || folder != self.folder else { return }
        self.agent = agent
        self.tools = tools
        self.folder = folder
        conversation = ChatConversation(backend: agent.makeBackend(tools: tools, folder: folder))
        attached = []
    }

    func end() async {
        await conversation.reset()
        attached = []
        SaySpeaker.shared.stop()
        ChatWindow.shared.clear()
    }

    /// 答えの見せ方：短ければ上のパネル、長ければウィンドウ。
    static func isShort(_ answer: String) -> Bool { answer.count <= 110 && !answer.contains("\n") }

    /// `activities`：外のエージェントが、実際にやった操作（実行したコマンド・検索・読んだファイルなど）。道具を開けているときの、確認用。
    struct Outcome { var answer: String; var notes: [String]; var activities: [ChatActivity] = []; var startedNew = false; var imageRoute: ImageRoute? }

    /// 質問に使った画像が、**どう扱われたか**（会話のウィンドウの、画像の札に出す）。
    enum ImageRoute: Equatable {
        /// この Mac の中で、文字にして、質問に入れた（Apple の会話）。
        case local
        /// 外のエージェント（名前）へ送った（確認して）。
        case sent(String)
        /// 送る確認を、断った。
        case declined(String)
        /// 使えなかった（理由）。
        case notUsed(String)
    }

    /// 画像を、外のエージェントへ送ってよいか、利用者に確かめる（送るたびに：画像と、送り先を見せる）。送ってよければ true。
    typealias ImageSendConfirm = @Sendable (_ image: URL, _ agent: ChatAgent) async -> Bool

    /// 1 回の質問：添付を決めて（コード）、会話に渡し、答えを返す。進み具合は `progress` で知らせる。
    /// - `attachedImage`：会話のウィンドウに、添えてある画像（「この画面」と言わなくても、使う）。
    /// - `confirmImage`：**外のエージェントへ画像を送る前の確認**（なければ、送らない）。Apple の会話は、画像を、この Mac の中で文字にするので、確認は要らない。
    func ask(_ utterance: String, engine: Engine, token: CancelToken?, attachedImage: URL? = nil, onImage: (@MainActor (URL) -> Void)? = nil, progress: @escaping @MainActor (String) -> Void,
             confirm: ToolConfirm? = nil, confirmImage: ImageSendConfirm? = nil) async throws -> Outcome {
        var notes: [String] = []
        var attachments: [ChatAttachments.Attachment] = []
        var imageToSend: URL?
        var route: ImageRoute?
        var cleanup: [() -> Void] = []
        defer { cleanup.forEach { $0() } }   // コピーした画像の書き出しは、答えが出たあとに、消す
        let wants = ChatAttachments.wants(utterance)
        let outside = agent.isExternal || tools != .none   // 画像・文章が、外へ出うる
        let wantsImage = wants.image || attachedImage != nil
        if wantsImage {
            // 画像のもと：添えてある画像、なければ、言葉から（撮ったスクリーンショット／コピーした画像）
            let file: URL?
            if let attachedImage { file = attachedImage } else {
                let source = ImageSource.any.resolve(for: utterance)
                switch source.materialize(for: utterance) {
                case let .success(found): file = found; cleanup.append { source.discard() }
                case let .failure(missing): file = nil; route = .notUsed("画像がありません"); notes.append("画像がないので、画像なしで答えます（\(missing)）")
                }
            }
            if let file {
                onImage?(file)   // 質問に使う画像を、ウィンドウに出す（言葉で頼んだ画像も、添えたように見せる）
                if agent.isExternal {
                    // 外へ出る：**送るたびに確認する**（画像と送り先を見せる）。確認できなければ（端末など）、送らない
                    if let confirmImage {
                        if await confirmImage(file, agent) { imageToSend = file; route = .sent(agent.rawValue) }
                        else { route = .declined(agent.rawValue) }
                    } else {
                        route = .notUsed("確認できないので、送りません")
                    }
                } else if tools != .none {
                    route = .notUsed("Web 検索の道具を開けている間は、渡しません")
                } else {
                    let key = "image-" + ChatAttachments.fingerprint(file)
                    if attached.contains(key) { route = .local; if wants.image { notes.append("同じ画像は、すでに会話に入っています") } }
                    else {
                        progress("画像を読んでいます…")
                        let digest = await Task.detached { ChatAttachments.imageAttachment(file: file, engine: engine, cancel: token) }.value
                        switch digest {
                        case let .success(attachment): attachments.append(attachment); attached.insert(attachment.key); route = .local
                        case let .failure(failure): route = .notUsed("読めませんでした"); notes.append("画像を読めませんでした（\(failure.message)）。画像なしで答えます")
                        }
                    }
                }
            }
        } else if wants.text {
            if outside {
                // 外へ出さない決まり：コピーした文章は、この Mac の中のモデルにだけ渡す
                notes.append("コピーした文章は、道具（Web 検索）・外のエージェントには、渡しません（この Mac の外へ出さないため。Apple のモデルの会話で、道具なしなら、使えます）")
            } else if let clip = TextClipboard.read(), let attachment = ChatAttachments.textAttachment(from: clip) {
                if attached.contains(attachment.key) { notes.append("同じ文章は、すでに会話に入っています") }
                else { attachments.append(attachment); attached.insert(attachment.key) }
            } else {
                notes.append("コピーした文章がないので、文章なしで答えます")
            }
        }
        progress("考えています…")
        let question = ChatAttachments.compose(question: utterance, attachments: attachments)
        let log = ActivityLog()
        let reply = try await conversation.ask(question, options: ChatCallOptions(onActivity: { activity in
            log.add(activity)
            Task { @MainActor in progress(activity.text) }
        }, confirm: confirm, image: imageToSend))
        if reply.startedNew { attached = Set(attachments.map(\.key)); notes.append("しばらく話さなかったので、前の会話は終わりました") }
        if reply.compacted { notes.append("古いやり取りを、要約しました") }
        if reply.compactionFailed { notes.append("要約に失敗して、古いやり取りを忘れました") }
        return Outcome(answer: reply.text, notes: notes, activities: log.items, startedNew: reply.startedNew, imageRoute: route)
    }
}

/// コピーした文章（クリップボード）を、読むだけ（書き換えない）。
enum TextClipboard {
    static func read() -> String? { NSPasteboard.general.string(forType: .string) }
}

extension CommandContext {
    /// 会話に使うエージェント：設定（設定ウィンドウ > モデル）。なければ Apple。書き方が違えば、理由を示して終わる。
    func resolveChatAgent() -> ChatAgent {
        guard let text = currentSettings().chatAgent else { return .apple }
        guard let agent = ChatAgent.parse(text) else {
            fail("settings.json の chatAgent「\(text)」は、使えません（\(ChatAgent.allCases.map(\.rawValue).joined(separator: "・"))）。設定ウィンドウ > モデル で直す")
        }
        return agent
    }
}

/// 実行した操作の記録（その会話の 1 回分。メモリだけ）。
final class ActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ChatActivity] = []
    func add(_ activity: ChatActivity) { lock.lock(); if stored.last != activity { stored.append(activity) }; lock.unlock() }
    var items: [ChatActivity] { lock.lock(); defer { lock.unlock() }; return stored }
}
