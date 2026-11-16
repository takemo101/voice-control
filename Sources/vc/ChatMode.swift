import AppKit
import Foundation
import VCCore
import VCDecision
import VCSkill

/// 会話（声の入力 の会話のトリガー・`vc chat`）：**スキルを選ばずに、会話として質問できる**。古い往復は、要約して、続けられる（`ChatConversation`）。
/// 会話の記録は、**メモリだけ**（ファイル・ログに残さない）。`vc` を終えるか、「会話を終わって」と言うか、しばらく話さないと、消える。
@MainActor final class ChatMode {
    static let shared = ChatMode()
    private(set) var conversation = ChatConversation()
    /// いま使っているエージェント。`configure` で替える（替えると、会話は、新しくなる）。
    private(set) var agent = ChatAgent.apple
    /// 設定で選んだエージェントと道具の段階（`agent` は、これが使えないとき、Apple に替わる）。
    private(set) var configured = ChatAgent.apple
    private var requestedTools = ChatToolLevel.none
    /// 外のエージェントに開けている道具の段階と、作業フォルダ。
    private(set) var tools = ChatToolLevel.none
    private(set) var folder: URL?
    /// ACP に対応したエージェントを、常駐の接続で使うか（設定 `chatAcp`）。
    private(set) var acp = true
    /// ACP のエージェントを、OS の制限（Seatbelt）つきで起動するか（設定 `chatSandbox`）。
    private(set) var sandbox = true
    /// 会話の判断（撮ったスクリーンショットを使うか・最新の情報が要るか）に使う Tiny-Jev。なければ、言葉で決める（`vc chat` の、モデルを読めないとき）。
    var scorer: OptionScorer?
    /// 撮ったスクリーンショットの、使った印（同じものを、何度も使わない）。
    private var shots = ScreenshotLedger()
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
    func configure(agent: ChatAgent, tools: ChatToolLevel = .none, folder: URL? = nil, acp: Bool = true, sandbox: Bool = true) {
        guard agent != configured || tools != requestedTools || folder != self.folder || acp != self.acp || sandbox != self.sandbox else { return }
        configured = agent
        self.acp = acp
        self.sandbox = sandbox
        requestedTools = tools
        self.agent = agent
        self.tools = agent.effective(tools)
        self.folder = folder
        conversation = ChatConversation(backend: agent.makeBackend(tools: self.tools, folder: folder, acp: acp, sandbox: sandbox))
        attached = []
        shots = ScreenshotLedger()
    }

    /// **質問のたびに**、選んだエージェントが、使えるか確かめる（CLI が、アンインストールなどで、なくなっていないか）。
    /// 使えなければ、**Apple のモデル**で答える（会話の記録は、そのまま。設定は、変えない：入れ直せば、また使える）。戻り値は、利用者に見せる断り。
    func settleAgent() async -> String? {
        if configured.isExternal, !AgentLocator.isAvailable(configured) {
            if agent != .apple {
                agent = .apple
                tools = ChatAgent.apple.effective(requestedTools)
                await conversation.replaceBackend(ChatAgent.apple.makeBackend(tools: tools, folder: folder))
            }
            return "\(configured.rawValue) が、この Mac に見つかりません（アンインストールされた？）。Apple のモデルで答えました"
        }
        if agent != configured {   // 入れ直された：選んだエージェントへ戻す
            agent = configured
            tools = configured.effective(requestedTools)
            await conversation.replaceBackend(configured.makeBackend(tools: tools, folder: folder, acp: acp, sandbox: sandbox))
        }
        return nil
    }

    func end() async {
        await conversation.reset()
        attached = []
        shots = ScreenshotLedger()
        SaySpeaker.shared.stop()
        ChatWindow.shared.clear()
    }

    /// `activities`：外のエージェントが、実際にやった操作（実行したコマンド・検索・読んだファイルなど）。道具を開けているときの、確認用。
    struct Outcome { var answer: String; var notes: [String]; var activities: [ChatActivity] = []; var startedNew = false; var imageRoute: ImageRoute? }

    /// 質問に使った画像が、**どう扱われたか**（会話のウィンドウの、画像の札に出す）。
    enum ImageRoute: Equatable {
        /// この Mac の中で、文字にして、質問に入れた（Apple の会話）。
        case local
        /// 外のエージェント（名前）へ送る確認を、待っている。
        case confirming(String)
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
    func ask(_ utterance: String, engine: Engine, token: CancelToken?, attachedImage: URL? = nil, onImage: (@MainActor (URL) -> Void)? = nil, onRoute: (@MainActor (ImageRoute) -> Void)? = nil, progress: @escaping @MainActor (String) -> Void,
             confirm: ToolConfirm? = nil, confirmImage: ImageSendConfirm? = nil) async throws -> Outcome {
        var notes: [String] = []
        var attachments: [ChatAttachments.Attachment] = []
        var imageToSend: URL?
        var route: ImageRoute?
        var cleanup: [() -> Void] = []
        defer { cleanup.forEach { $0() } }   // コピーした画像の書き出しは、答えが出たあとに、消す
        let wants = ChatAttachments.wants(utterance)
        // 画像を使うか：「画面を撮る」で添えたものは、そのまま使う。撮ったスクリーンショット（ショートカット）は、**Tiny-Jev が、この質問に使うか判定する**。判定できなければ、言葉で決める
        let judge = scorer.map { scorer in { try ChatImageUse(scorer: scorer).probability(request: utterance) } }
        // 撮ったスクリーンショットは、1 度使ったら、次の質問では、判定せずに使わない（判定が外れて、どの質問にも付く、を防ぐ）
        var shotKey: String?
        if case let .success(shot) = ScreenshotStore.current() { shotKey = ChatAttachments.fingerprint(shot) }
        let plan = ChatAttachments.imagePlan(request: utterance, hasAttached: attachedImage != nil, screenshotAvailable: shotKey.map { shots.isFresh($0) } ?? false, judge: judge)
        if let shotKey {
            switch plan {
            case .screenshot, .attached: shots.markUsed(shotKey)
            case .skippedScreenshot: if shots.shouldNoteSkip(shotKey) { notes.append("撮ったスクリーンショットは、この質問には使いませんでした（使うときは、会話のウィンドウの「画面を撮る」で添えてください）") }
            default: break
            }
        }
        if plan.usesImage {
            // 画像のもと：添えてある画像、判定したスクリーンショット、なければ、言葉から（コピーした画像・撮ったスクリーンショット）
            let file: URL?
            if let attachedImage, plan == .attached { file = attachedImage } else if plan == .screenshot, case let .success(found) = ImageSource.screenshot.materialize() { file = found } else {
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
                        onRoute?(.confirming(agent.rawValue))   // 確認を待っている間は、そう出す（「送信中」に見えないように）
                        if await confirmImage(file, agent) { imageToSend = file; route = .sent(agent.rawValue) }
                        else { route = .declined(agent.rawValue) }
                    } else {
                        route = .notUsed("確認できないので、送りません")
                    }
                } else {
                    let key = "image-" + ChatAttachments.fingerprint(file)
                    if attached.contains(key) { route = .local; if plan != .attached { notes.append("同じ画像は、すでに会話に入っています") } }
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
            if agent.isExternal {
                // 外へ出さない決まり：コピーした文章は、この Mac の中のモデルにだけ渡す
                notes.append("コピーした文章は、外のエージェントには、渡しません（この Mac の外へ出さないため。Apple のモデルの会話では、使えます）")
            } else if let clip = TextClipboard.read(), let attachment = ChatAttachments.textAttachment(from: clip) {
                if attached.contains(attachment.key) { notes.append("同じ文章は、すでに会話に入っています") }
                else { attachments.append(attachment); attached.insert(attachment.key) }
            } else {
                notes.append("コピーした文章がないので、文章なしで答えます")
            }
        }
        if let route { onRoute?(route) }   // 画像の扱いは、決まった時点で、ウィンドウへ知らせる（答えが出るまで、待たせない）
        progress("考えています…")
        let question = ChatAttachments.compose(question: utterance, attachments: attachments)
        // Apple の会話で、画像・コピーした文章が、会話に入っている間は、Web の道具を外す（画面の内容が、モデルの作る検索語に混ざって、外へ出ないため）
        let webOff = !agent.isExternal && tools != .none && !attached.isEmpty
        if webOff && !attachments.isEmpty { notes.append("画像・コピーした文章を使うので、この会話では、Web 検索を使いません（画面の内容が、検索語に混ざって、外へ出ないため）") }
        let log = ActivityLog()
        let reply = try await conversation.ask(question, options: ChatCallOptions(onActivity: { activity in
            log.add(activity)
            Task { @MainActor in progress(activity.text) }
        }, confirm: confirm, image: imageToSend, allowsWeb: !webOff, needsWeb: scorer.map { scorer -> (@Sendable (String) -> Bool) in { _ in ChatWebNeed(scorer: scorer).needsWeb(utterance) } }))
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
    /// 会話に使うエージェント：設定（設定ウィンドウ > 会話）。なければ Apple。書き方が違えば、理由を示して終わる。
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
    /// 同じ番号（`id`）の操作は、置き換える（結果が、あとから届く）。番号がなければ、直前と同じものは、足さない。
    func add(_ activity: ChatActivity) {
        lock.lock(); defer { lock.unlock() }
        if let id = activity.id, let index = stored.firstIndex(where: { $0.id == id }) { stored[index] = activity; return }
        if stored.last != activity { stored.append(activity) }
    }
    var items: [ChatActivity] { lock.lock(); defer { lock.unlock() }; return stored }
}
