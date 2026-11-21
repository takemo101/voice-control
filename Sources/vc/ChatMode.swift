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
    /// 設定で選んだ会話の設定（`agent` は、これが使えないとき、Apple に替わる）。
    private(set) var setup = ChatSetup(agent: .apple)
    /// いま答えているエージェントと、そのエージェントに開けている道具の段階。
    private(set) var agent = ChatAgent.apple
    private(set) var tools = ChatToolLevel.none
    private var needsRebuild = false
    /// 次の `configure` で、同じ設定でも、答える側を作り直す（アダプターを入れた・消したあと：会話は、新しくなる）。
    func invalidate() { needsRebuild = true }
    var folder: URL? { setup.folder }
    /// 自動モード（設定 `chatAuto`）。
    var auto: Bool { setup.auto }
    /// 会話の判断（撮ったスクリーンショットを使うか・最新の情報が要るか）に使う Tiny-Jev。なければ、言葉で決める（`vc chat` の、モデルを読めないとき）。
    var scorer: OptionScorer?
    /// 撮ったスクリーンショットの、使った印（同じものを、何度も使わない）。
    private var shots = ScreenshotLedger()
    /// この会話で、すでに添えた画像・文章の印（同じものは、2 度、添えない）。
    private var attached: Set<String> = []

    /// 使うエージェントを決める（声の入力・`vc chat` の開始のとき）。替わったら、会話は、新しくなる（記録を、別の提供元へ、引き継がない）。
    func configure(_ new: ChatSetup) {
        guard needsRebuild || new != setup else { return }
        needsRebuild = false
        setup = new
        conversation = ChatConversation(backend: rebuildBackend(for: new.agent))
        attached = []
        shots = ScreenshotLedger()
    }

    /// **質問のたびに**、選んだエージェントが、使えるか確かめる（CLI が、アンインストールなどで、なくなっていないか）。
    /// 使えなければ、**Apple のモデル**で答える（会話の記録は、そのまま。設定は、変えない：入れ直せば、また使える）。戻り値は、利用者に見せる断り
    func settleAgent() async -> String? {
        let chosen = setup.agent
        if chosen.isExternal, !AgentLocator.isAvailable(chosen) {
            if agent != .apple { await conversation.replaceBackend(rebuildBackend(for: .apple)) }
            return tr("\(chosen.rawValue) が、この Mac に見つかりません（アンインストールされた？）。Apple のモデルで答えました")
        }
        if agent != chosen { await conversation.replaceBackend(rebuildBackend(for: chosen)) }   // 入れ直された：選んだエージェントへ戻す
        return nil
    }

    /// `runner` で答える側を作る（`agent`・`tools` を、それに合わせる）。**設定の渡し方は、ここ 1 か所**。
    private func rebuildBackend(for runner: ChatAgent) -> ChatBackend {
        agent = runner
        tools = runner.effective(setup.tools)
        return runner.makeBackend(tools: tools, folder: setup.folder, acp: setup.acp, sandbox: setup.sandbox, model: setup.model, auto: setup.auto)
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
             onText: (@Sendable (String) -> Void)? = nil, confirm: ToolConfirm? = nil, confirmImage: ImageSendConfirm? = nil) async throws -> Outcome {
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
            case .skippedScreenshot: if shots.shouldNoteSkip(shotKey) { notes.append(tr("撮ったスクリーンショットは、この質問には使いませんでした（使うときは、会話のウィンドウの「画面を撮る」で添えてください）")) }
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
                case let .failure(missing): file = nil; route = .notUsed(tr("画像がありません")); notes.append(tr("画像がないので、画像なしで答えます（\(missing)）"))
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
                        route = .notUsed(tr("確認できないので、送りません"))
                    }
                } else {
                    let key = "image-" + ChatAttachments.fingerprint(file)
                    if attached.contains(key) { route = .local; if plan != .attached { notes.append(tr("同じ画像は、すでに会話に入っています")) } }
                    else {
                        progress(tr("画像を読んでいます…"))
                        let digest = await Task.detached { ChatAttachments.imageAttachment(file: file, engine: engine, cancel: token) }.value
                        switch digest {
                        case let .success(attachment): attachments.append(attachment); attached.insert(attachment.key); route = .local
                        case let .failure(failure): route = .notUsed(tr("読めませんでした")); notes.append(tr("画像を読めませんでした（\(failure.message)）。画像なしで答えます"))
                        }
                    }
                }
            }
        } else if wants.text {
            let clipboard = agent.isExternal ? nil : TextClipboard.read().flatMap(ChatAttachments.textAttachment(from:))   // 外のエージェントには渡さないので、読まない
            switch ChatAttachments.textPlan(agentIsExternal: agent.isExternal, clipboard: clipboard, attached: attached) {
            case .withheldFromExternal: notes.append(tr("コピーした文章は、外のエージェントには、渡しません（この Mac の外へ出さないため。Apple のモデルの会話では、使えます）"))
            case .noText: notes.append(tr("コピーした文章がないので、文章なしで答えます"))
            case .alreadyInConversation: notes.append(tr("同じ文章は、すでに会話に入っています"))
            case let .attach(attachment): attachments.append(attachment); attached.insert(attachment.key)
            }
        }
        if let route { onRoute?(route) }   // 画像の扱いは、決まった時点で、ウィンドウへ知らせる（答えが出るまで、待たせない）
        progress(tr("考えています…"))
        let question = ChatAttachments.compose(question: utterance, attachments: attachments)
        // Apple の会話で、画像・コピーした文章が、会話に入っている間は、Web の道具を外す（画面の内容が、モデルの作る検索語に混ざって、外へ出ないため）
        let webOff = ChatAttachments.suppressesWeb(agentIsExternal: agent.isExternal, tools: tools, conversationHasAttachments: !attached.isEmpty)
        if webOff && !attachments.isEmpty { notes.append(tr("画像・コピーした文章を使うので、この会話では、Web 検索を使いません（画面の内容が、検索語に混ざって、外へ出ないため）")) }
        let log = ActivityLog()
        let reply = try await conversation.ask(question, options: ChatCallOptions(onActivity: { activity in
            log.add(activity)
            Task { @MainActor in progress(activity.text) }
        }, onText: onText, confirm: confirm, image: imageToSend, allowsWeb: !webOff, needsWeb: scorer.map { scorer -> (@Sendable (String) -> Bool) in { _ in ChatWebNeed(scorer: scorer).needsWeb(utterance) } },
            judgeCommand: auto ? scorer.map { scorer -> CommandJudge in { command in await Task.detached { CommandSafetyJudge(scorer: scorer).isHarmless(command) }.value } } : nil))
        if reply.startedNew { attached = Set(attachments.map(\.key)); notes.append(tr("しばらく話さなかったので、前の会話は終わりました")) }
        if reply.compacted { notes.append(tr("古いやり取りを、要約しました")) }
        if reply.compactionFailed { notes.append(tr("要約に失敗して、古いやり取りを忘れました")) }
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
        if let choices { return choices.chatAgent }
        do { return try resolveChatAgent(settings: currentSettings()) } catch { fail("\(error)") }
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

/// 会話の設定（どのエージェントを・どの道具で・どの作業フォルダで・どう動かすか）。`ChatMode.configure` に、まとめて渡す：読み出しの場所が散らない。
struct ChatSetup: Equatable {
    var agent: ChatAgent
    /// 利用者が選んだ道具の段階（エージェントが開けられる範囲は、`ChatAgent.effective`）。
    var tools = ChatToolLevel.none
    var folder: URL?
    /// 常駐の接続（ACP）で話すか（設定 `chatAcp`）。
    var acp = true
    /// OS の制限つきで動かすか（設定 `chatSandbox`）。
    var sandbox = true
    /// 利用者が選んだモデル（設定 `chatModels`。ACP で話すエージェントだけ）。
    var model: String?
    /// 自動モード（設定 `chatAuto`）。
    var auto = false
}

extension CommandContext {
    /// 設定（設定ウィンドウ > 会話）から、会話の設定を作る。**設定は、1 回だけ読む**。`vc chat` の引数は、呼ぶ側が、上書きする。
    func chatSetup(agent: ChatAgent) -> ChatSetup {
        let settings = currentSettings()
        let (tools, folder) = resolveChatTools()
        return ChatSetup(agent: agent, tools: tools, folder: folder, acp: settings.chatAcp ?? true, sandbox: settings.chatSandbox ?? true,
                         model: settings.chatModels?[agent.rawValue], auto: settings.chatAuto ?? false)
    }
}

