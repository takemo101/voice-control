import AppKit
import Combine
import SwiftUI
import VCCore
import VCSkill

/// 会話のウィンドウ：**1 つだけ**。質問と答えが、下へ続いていく（答えごとに、新しいウィンドウを開かない）。
/// 見た目：質問は、右の吹き出し（青〜紫のグラデーション）。答えは、左のカード（アイコンつき。Markdown を整形）。**実行した操作**は、答えの下に、種類ごとのアイコンつきで並ぶ。考えている間は、波打つ点と、いまの操作。
/// - 質問が分かった時点で、質問と「考えています…」（外のエージェントの実行中は、いまの操作）を出し、答えが来たら、同じ場所を、答えに置き換える。
/// - 記録は、**メモリだけ**（会話を終えたら・リセットしたら・しばらく話さなかったら、消える。保存しない）。
/// - 読み上げの最中は、ヘッダーに波形と「読み上げ中」、下に「読み上げを止める」を出す。Esc は、読み上げを先に止める（もう一度で、閉じる）。答えごとの「読み上げ」「コピー」もある。
/// メインスレッドで使う。
@MainActor final class ChatWindow: NSObject, NSWindowDelegate {
    static let shared = ChatWindow()

    private let state = ChatWindowState()
    private var window: DocumentWindowFrame?
    private var scaleObserver: AnyCancellable?   // 文字の大きさの変化
    private var expiry: Task<Void, Never>?

    var isVisible: Bool { window?.isVisible == true }

    /// 文字の質問を、**始める**（声の流れの組み立てで、決める：`VoiceSession`）。なければ、入力欄は出さない。考えている間に送られた質問は、ここへ来ずに、順番待ちに入る（`submitTyped`）。
    var startTyped: (@MainActor (String, [ChatFile]) -> Void)? {
        didSet {
            if startTyped == nil { state.submit = nil } else { state.submit = { [unowned self] text in self.submitTyped(text) } }
        }
    }

    /// いま考えている声の質問を、取りやめる（声の流れが持つ：`VoiceSession`）。「今すぐ送る」で、使う。
    var interruptVoiceTurn: (@MainActor () -> Void)?

    /// 順番待ちの声の質問を、声の流れの処理へ戻す（声の流れが持つ：`VoiceSession`）。
    /// 戻せなければ false（声の流れが、止まっている）。
    var injectSpoken: (@MainActor (String) -> Bool)?
    /// 戻した発話（その発話の `claimTurn` は、待たずに通す）。
    private var injectedText: String?
    /// 質問を始めようとしている（始める処理が、`begin` を呼ぶまでの間）。この間に来た質問も、順番待ちに入る。
    private var starting = false
    private var reservation = 0
    private var noticeGeneration = 0
    private var partialBuffer: [UUID: String] = [:]
    private var partialFlushScheduled = false
    /// 停止（ボタン）で、止めている最中。順番待ちは、送らずに、捨てる。
    private var stopRequested = false

    /// 声の状態（録音・認識）を、知らせる（下の案内に出す）。
    func setVoiceState(_ voice: ChatVoiceState) { state.voice = voice }

    /// 会話のキーの名前（案内に出す）。
    func setKeyHint(_ hint: String?) { state.keyHint = hint }
    var hasPending: Bool { state.entries.hasPending }
    /// 順番待ち（古い順）。
    var queued: [QueuedMessage] { state.queue.items }
    var queuedTexts: [String] { state.queue.items.map(\.text) }
    /// 会話の記録（ウィンドウの中身）。
    var transcript: [ChatEntry] { state.entries }
    /// 入力欄の文字。
    var draftText: String { state.draft }
    /// 始める予約が、質問の開始（`begin`）なしに、残り続けないための、待ち時間（これを過ぎたら、外して、次へ進む）。テストで、短くする。
    var reservationTimeout: Duration = .seconds(15)
    /// 考えている最中か（質問を始めようとしている間も含む）。
    var isBusy: Bool { state.entries.hasPending || starting }

    private override init() {
        super.init()
        // 会話の答えの読み上げだけに、反応する（スキルの結果・確認の問いかけの読み上げには、反応しない）
        SaySpeaker.shared.observe(.conversation) { [weak self] speaking in
            self?.state.speaking = speaking
            if !speaking { self?.state.speakingEntry = nil }
        }
        state.speaking = SaySpeaker.shared.isSpeaking(.conversation)
        state.addFiles = { [unowned self] urls in addFiles(urls) }
        state.removeFile = { [unowned self] id in removeFile(id) }
        state.pickFiles = { [unowned self] in pickFiles() }
        state.sendNow = { [unowned self] id in sendNow(id) }
        state.removeQueued = { [unowned self] id in removeQueued(id) }
        state.stopTurn = { [unowned self] in stopCurrent() }
    }

    // MARK: 記録の更新

    /// 質問が分かった：質問と「考えています…」を出す。`agent`：使っているエージェントの名前。`warning`：外へ送るときの断り（ヘッダーの橙の札）。`tools`：開けている道具（札）。
    /// 戻り値の `id` で、この往復を指す（答え・中断・失敗の知らせを、この往復だけに、届けるため）。
    @discardableResult
    func begin(question: String, agent: String, warning: String?, tools: String?, files: [ChatFile] = [], cancel: (() -> Void)? = nil) -> UUID {
        starting = false
        state.agent = agent
        state.warning = warning
        state.tools = tools
        var entry = ChatEntry(question: question)
        entry.cancel = cancel
        entry.fileNames = files.map { "\($0.name)（\($0.sizeText)）" }   // どのファイルを、添えた質問か、分かるように
        entry.image = state.image.map { EntryImage(thumbnail: $0.thumbnail) }   // 添えてある画像を、質問に付ける（どの画像についての質問か、分かるように）
        state.entries.begin(entry)
        state.scrollToken += 1
        return entry.id
    }

    /// 実行中の様子（外のエージェントの、いまの操作など）。
    func setStatus(_ id: UUID, _ text: String) { state.entries.setStatus(id, text) }

    /// 答えの続きの文字が、届いた：考えている間に、少しずつ、見せる。**描き直しは、少しまとめて**（0.12 秒）：届くたびに、会話全体を描き直さない。
    func appendPartial(_ id: UUID, _ text: String) {
        partialBuffer[id, default: ""] += text
        guard !partialFlushScheduled else { return }
        partialFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))   // try?: 取りやめられても、描き直しが、なくなるだけ
            self?.flushPartial()
        }
    }

    private func flushPartial() {
        partialFlushScheduled = false
        for (id, text) in partialBuffer { state.entries.appendPartial(id, text) }
        partialBuffer = [:]
    }

    /// 利用者が、いま、話している（録音中・文字にしている）。この間は、答えを、読み上げない（マイクが、声を拾う）。
    var isUserSpeaking: Bool { state.voice != .idle }

    /// この往復の答えを、読んでいる最中にする（読み上げの「止める」ボタンを、この答えに出す）。
    func markSpeaking(_ id: UUID) { state.speakingEntry = id }

    /// 質問に使う画像が分かった（言葉で頼んだ画像など）：その質問に、画像を付ける（添えてある画像は、`begin` で付いている）。
    func attachImage(_ id: UUID, file: URL) {
        guard let thumbnail = HUDImage.load(file, sendsOut: false)?.thumbnail else { return }
        state.entries.attach(id, image: EntryImage(thumbnail: thumbnail))
    }

    /// 画像の扱いが決まった（確認待ち・送った・断った）：答えを待たずに、札を替える。
    func setImageRoute(_ id: UUID, _ route: ChatMode.ImageRoute) { state.entries.setRoute(id, route) }

    /// 答えが来た。`startedNew`：しばらく話さなかったので、前の会話は、終わった（古い記録を消す）。
    func finish(_ id: UUID, answer: String, activities: [ChatActivity], notes: [String], startedNew: Bool, imageRoute: ChatMode.ImageRoute? = nil) {
        partialBuffer[id] = nil
        state.entries.finish(id, answer: answer, rendered: Self.render(answer), activities: activities, notes: notes, route: imageRoute, startedNew: startedNew)
        state.scrollToken += 1
        turnEnded(dropsQueue: false)
    }

    /// 中断・取りやめた：質問を、理由つきで残す（会話の記録には、入らない）。
    /// `dropsQueue`：利用者の取りやめ（Esc・停止）：順番待ちも、送らずに捨てる。新しい質問に取って代わられたときは、false。
    func stop(_ id: UUID, reason: String, dropsQueue: Bool = false) {
        let requested = stopRequested
        partialBuffer[id] = nil
        state.entries.stop(id, reason: requested ? tr("取りやめました（停止）") : reason)
        turnEnded(dropsQueue: dropsQueue || requested)
    }

    /// 答えを作れなかった：質問を、理由つきで残す。
    func fail(_ id: UUID, message: String) {
        partialBuffer[id] = nil
        state.entries.fail(id, message: message)
        turnEnded(dropsQueue: false)
    }

    /// 記録を、すべて消す（会話の終了・リセット）。添えた画像も、外す。
    func clear() {
        state.files = []; state.fileNotice = nil
        cancelCurrent()   // 考えている質問が、裏で動き続けないように（新しい会話に、前の答えが、混ざらない）
        state.entries = []
        dropQueue(reason: nil)
        starting = false
        injectedText = nil
        stopRequested = false
        detachImage()
    }

    // MARK: 順番待ち（考えている間に送った質問）

    // MARK: 添えるファイル（ドラッグ＆ドロップ・ファイルを選ぶ・貼り付け）

    /// ファイルを添える（外のエージェントへ渡す：送る前に、確認する）。断ったものは、理由を、しばらく出す。
    func addFiles(_ urls: [URL]) {
        let result = ChatFileRules.add(urls, to: state.files)
        state.files = result.files
        showFileNotice(result.refusals.map(\.description))
    }

    func removeFile(_ id: UUID) { state.files.removeAll { $0.id == id } }

    /// 添えてあるファイルを、取り出す（質問が、始まるとき。取り出したら、札は、空になる：次の質問へは、付けない）。
    func takeFiles() -> [ChatFile] {
        defer { state.files = [] }
        return state.files
    }

    var attachedFiles: [ChatFile] { state.files }
    var fileNoticeText: String? { state.fileNotice }

    private func showFileNotice(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        state.fileNotice = Array(Set(lines)).sorted().joined(separator: "\n")
        noticeGeneration += 1
        let mine = noticeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(7))   // try?: 取りやめられても、断りの表示が、残るだけ
            if let self, self.noticeGeneration == mine { self.state.fileNotice = nil }
        }
    }

    /// 「ファイルを選ぶ」：選んだファイルを、添える。
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = tr("会話に添えるファイル")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.addFiles(panel.urls) }
        }
    }

    /// 入力欄から、文字の質問が来た：考えていなければ、すぐ始める。考えている間は、順番待ちに入れる。
    func submitTyped(_ text: String) {
        let files = takeFiles()   // 添えたファイルは、この質問のものになる（入力欄の上の札は、空になる）
        if isBusy || !state.queue.isEmpty {
            state.queue.enqueue(text, source: .typed, files: files)
            state.scrollToken += 1
            dispatchNext()   // 考えていなければ（取りこぼし）、ここで動かす
        } else {
            reserveStart()
            startTyped?(text, files)
        }
    }

    /// 始める予約をする（`begin` が呼ばれるまで、ほかの質問を割り込ませない）。**予約が、残り続けない**ように、一定時間（`reservationTimeout`。15 秒）で、質問が始まっていなければ、外す（始める処理が、途中で消えたとき：設定の反映での作り直しなど）。
    private func reserveStart() {
        starting = true
        reservation += 1
        let mine = reservation
        Task { @MainActor [weak self] in
            guard let timeout = self?.reservationTimeout else { return }
            try? await Task.sleep(for: timeout)   // try?: 取りやめられても、予約の見張りが、なくなるだけ
            guard let self, self.starting, self.reservation == mine, !self.state.entries.hasPending else { return }
            self.starting = false
            self.injectedText = nil
            self.dispatchNext()
        }
    }

    /// 声の質問が、先に認識できた（考えている間に、続けて話した）：順番待ちに入れる。考えていなければ、すぐ、声の流れへ戻す。
    func enqueueSpoken(_ text: String) {
        state.queue.enqueue(text, source: .voice)
        state.scrollToken += 1
        dispatchNext()
    }

    /// 声の質問（声の流れが、文字にした）：すぐ始められれば true（始める予約を、持つ）。考えている間は、順番待ちに入れて false（**待たずに、すぐ戻る**：声の流れを、塞がない。順番が来たら、声の流れへ戻す）。順番が来て戻した発話は、予約が済んでいるので、true。
    func claimTurn(_ text: String) -> Bool {
        if let injected = injectedText, injected == text { injectedText = nil; return true }
        if !isBusy && state.queue.isEmpty { reserveStart(); return true }
        state.queue.enqueue(text, source: .voice)
        state.scrollToken += 1
        return false
    }

    /// 戻した発話が、質問にならずに終わる（「会話を終わりにして」など）：予約を外す。戻した発話でなければ、何もしない。
    func dropInjection(_ text: String) {
        guard injectedText == text else { return }
        injectedText = nil
        releaseStart()
    }

    /// 質問を始められなかった（取りやめ）：始める予約を、外す。
    func releaseStart() {
        starting = false
        dispatchNext()
    }

    /// 次の順番を、始める（考えていないときだけ）。
    private func dispatchNext() {
        guard !isBusy, let batch = state.queue.takeNext() else { return }
        reserveStart()
        switch batch.source {
        case .typed: startTyped?(batch.text, batch.files)
        case .voice:
            injectedText = batch.text
            if let injectSpoken, injectSpoken(batch.text) {   // 声の質問：声の流れの処理（確認の返事・読み上げ）へ戻す
                // 戻した：その処理が、`claimTurn` で、受け取る
            } else {
                injectedText = nil
                starting = false   // 戻す先がない：始められない（記録に、残して、次の順番へ進む）
                state.entries.addStopped(question: batch.text, reason: tr("送られませんでした（声の流れが止まっています）"))
                dispatchNext()
            }
        }
    }

    /// 1 往復が、終わった（答え・取りやめ・失敗）。
    private func turnEnded(dropsQueue: Bool) {
        stopRequested = false
        if dropsQueue { dropQueue(reason: tr("送られませんでした（停止）")) } else { dispatchNext() }
    }

    /// 順番待ちを、すべて捨てる。`reason`：あれば、質問を、理由つきで、記録に残す。
    private func dropQueue(reason: String?) {
        for item in state.queue.removeAll() {
            if let reason { state.entries.addStopped(question: item.text, reason: reason) }
        }
    }

    /// 順番待ちの 1 件を、取り下げる（文字なら、入力欄が空のとき、戻す）。
    func removeQueued(_ id: UUID) {
        guard let item = state.queue.remove(id) else { return }
        if state.draft.isEmpty { state.draft = item.text }   // 声の質問も、文字にして、入力欄へ戻す（直して、送り直せる）
        if !item.files.isEmpty { state.files = Array((state.files + item.files.filter { f in !state.files.contains { $0.id == f.id } }).prefix(ChatFileRules.maxFiles)) }   // 添えたファイルも、戻す
    }

    /// 「今すぐ送る」：いまの質問を止めて、この 1 件を先に始める（残りは、そのあと）。
    func sendNow(_ id: UUID) {
        guard state.queue.items.contains(where: { $0.id == id }) else { return }
        state.queue.moveToFront(id)
        if isBusy { cancelCurrent() } else { dispatchNext() }
    }

    /// 停止：いまの質問を止める。順番待ちは、送らない。
    func stopCurrent() {
        guard state.entries.hasPending else { return }
        SaySpeaker.shared.stop()   // 読み上げの最中なら、それも止める
        stopRequested = true
        cancelCurrent()
    }

    /// **声の「止めて」**：考えている質問を止め、順番待ちを捨てる（停止ボタン・Esc と同じ）。止めるものが、あったか。
    @discardableResult
    func stopAll() -> Bool {
        let hadWork = isBusy || !state.queue.isEmpty
        if state.entries.hasPending { stopCurrent() } else { dropQueue(reason: tr("送られませんでした（停止）")) }
        return hadWork
    }

    /// いま考えている質問を、取りやめる（文字の質問は、自分の取りやめ。声の質問は、声の流れの取りやめ）。
    private func cancelCurrent() {
        guard let current = state.entries.last(where: { $0.isPending }) else { return }
        if let cancel = current.cancel { cancel() } else { interruptVoiceTurn?() }
    }

    // MARK: 画像の添付（「画面を撮る」）

    /// 質問に使う、添えてある画像（撮ってから 180 秒以内）。なければ nil。
    var attachedImageFile: URL? {
        guard state.image != nil else { return nil }
        guard case let .success(file) = ScreenshotStore.current() else { detachImage(); return nil }
        return file
    }

    /// 範囲を選んで撮り、会話に添える（このウィンドウは、撮るあいだ、隠す）。撮った画像は、`ScreenshotStore`（180 秒で古くなる・自分だけが読める）。
    func attachScreenshot() async {
        guard !state.capturing else { return }
        state.capturing = true
        defer { state.capturing = false }
        window?.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(250))   // ウィンドウが消えるのを待つ（撮る画面に、写らないように）
        let outcome = await ScreenCapture.captureForVoice()
        show(activate: true)
        switch outcome {
        case .captured:
            guard case let .success(file) = ScreenshotStore.current(), let thumbnail = HUDImage.load(file, sendsOut: false)?.thumbnail else { return }
            let image = AttachedImage(thumbnail: thumbnail, takenAt: Date())
            state.image = image
            expiry?.cancel()
            // 古くなったら、外す（使えない画像を、添えたままにしない）
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ScreenshotStore.timeToLive))
                guard !Task.isCancelled, self?.state.image?.id == image.id else { return }
                self?.detachImage()
            }
        case .cancelled: break
        case let .failed(reason):
            HUD.shared.show(HUDContent(phase: .failure, title: tr("画面を撮れませんでした"), hint: reason), hideAfter: 5)
        }
    }

    /// 添えた画像を外す（撮った画像も、消す）。
    func detachImage() {
        expiry?.cancel()
        expiry = nil
        guard state.image != nil else { return }
        state.image = nil
        ScreenshotStore.clear()
    }

    // MARK: 表示

    /// 出す。`activate`：前に出して、アプリを前面にする（出ているときの更新では、奪わない）。
    func show(activate: Bool) {
        let window = makeWindowIfNeeded()
        if !window.isVisible {
            window.alphaValue = 0
            window.setFrame(ScreenPlacement.windowFrame(size: window.frame.size, minSize: window.minSize, in: ScreenPlacement.currentVisibleFrame()), display: false)
            // 利用者の操作を、邪魔しない：自動で出すとき（`activate` なし）は、キーを奪わない
            if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 1
            }
            if activate { NSApplication.shared.activate(ignoringOtherApps: true) }
        } else {
            window.orderFrontRegardless()
        }
        // 初めて出すとき、中身の配置を、先に済ませる（キーでないウィンドウで、最初の描画が、遅れて、空に見えないように）
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        state.scrollToken += 1
    }

    /// いちばん新しい答えを、読み上げる（会話の答えとして：読んでいる間、この答えに、「止める」が出る）。
    func speakLatest(_ chunks: [String]) {
        state.speakingEntry = state.entries.last?.id
        SaySpeaker.shared.say(chunks: chunks, channel: .conversation)
    }

    func hide() { window?.orderOut(nil) }

    func windowWillClose(_ notification: Notification) {}

    /// 見た目の確認用（`vc settings-preview --chat`）：見本の会話を入れて、画面の外に置いたウィンドウを返す（利用者の画面には、出ない）。
    /// 見た目の確認用：**ウィンドウを作る前に**、質問と答えを記録しておいて、そのあと、ウィンドウを出す（パネルが出ていない間に会話して、あとから開く流れ）。
    func previewLateWindow() -> NSWindow {
        let id = begin(question: "ウィンドウがないときの質問", agent: "Apple のモデル", warning: nil, tools: nil)   // l10n-skip: preview sample
        finish(id, answer: "答えは、ウィンドウを作る前に、届きました。**これが見えれば、よい**です。", activities: [], notes: [], startedNew: false)   // l10n-skip: preview sample
        let window = makeWindowIfNeeded()
        state.solid = true
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// 見本の画像（絵だけ。見た目の確認用）。
    private static func sampleThumbnail() -> NSImage {
        return NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1), NSColor(red: 0.5, green: 0.3, blue: 0.7, alpha: 1)])?.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 54, width: 90, height: 12), xRadius: 4, yRadius: 4).fill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 34, width: 120, height: 8), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    /// 見た目の確認用（`vc chat-preview`）：本物のウィンドウに、見本の状態（添えた画像・読み上げの札）を、決める。
    func previewState(attachedImage: Bool? = nil, speaking: Bool? = nil, header: (agent: String, warning: String?, tools: String?)? = nil, draft: String? = nil, sampleFiles: Bool = false) {
        if let draft { state.draft = draft }
        if sampleFiles { state.files = [ChatFile(url: URL(fileURLWithPath: "/tmp/見本-議事録.md"), size: 4_300, isText: true), ChatFile(url: URL(fileURLWithPath: "/tmp/見本-資料.pdf"), size: 1_800_000, isText: false)] }   // l10n-skip: preview sample
        if let attachedImage { state.image = attachedImage ? AttachedImage(thumbnail: Self.sampleThumbnail(), takenAt: Date().addingTimeInterval(-20)) : nil }
        if let speaking { state.speaking = speaking; state.speakingEntry = speaking ? state.entries.last?.id : nil }
        if let header { state.agent = header.agent; state.warning = header.warning; state.tools = header.tools }
    }

    func previewWindow(pendingOnly: Bool = false) -> NSWindow {
        let window = makeWindowIfNeeded()
        state.agent = "Claude Code"
        state.warning = "この Mac の外へ送信"   // l10n-skip: preview sample
        state.tools = "すべて"   // l10n-skip: preview sample
        func entry(_ question: String, answer: String?, status: String? = nil, activities: [ChatActivity] = [], notes: [String] = []) -> ChatEntry {
            var e = ChatEntry(question: question)
            e.status = status
            e.answer = answer
            e.outcome = answer == nil ? .pending : .answered
            e.rendered = answer.map { Self.render($0) }
            e.activities = activities
            e.notes = notes
            return e
        }
        state.entries = [
            entry("このフォルダのファイルを、一覧にして", answer: "## 見つけたファイル\n\nフォルダには、次の 2 つがあります。\n\n| 名前 | 内容 |\n|---|---|\n| **note.txt** | メモ（16 バイト） |\n| **memo.txt** | 「確認済み」 |\n\n1. `memo.txt` は、さっき作りました\n2. 詳しくは [公式の説明](https://example.com/doc) を見てください\n\n> 書き込みは、作業フォルダの中だけです。\n\n```sh\nls -la\n```", activities: [ChatActivity(.run, "ls -la", output: .init(text: "total 16\n-rw-r--r--  1 user  staff  16 Nov 17 09:00 note.txt\n-rw-r--r--  1 user  staff  24 Nov 17 09:01 memo.txt")), ChatActivity(.write, "memo.txt", output: .init(text: "--- memo.txt\n 買い物\n-牛乳\n+牛乳（2 本）\n+パン\n 卵", isDiff: true))]),   // l10n-skip: preview sample
            entry("東京の明日の天気は？", answer: "明日の東京は、**晴れ時々くもり**で、最高気温は 24 度の予報です。降水確率は午前 10%、午後 30% で、夕方から風が少し強くなります。傘は、念のため、持っていくと安心です。気温の変化が大きいので、薄手の上着があると、朝晩の移動が楽になります。", notes: ["しばらく話さなかったので、前の会話は終わりました"]),   // l10n-skip: preview sample
            entry("ギフティのニュースを、調べて", answer: nil, status: nil),   // l10n-skip: preview sample
            entry("もう少し詳しく教えて", answer: nil, status: ChatActivity.search("東京 天気 明日").text),   // l10n-skip: preview sample
        ]
        let sample = Self.sampleThumbnail()
        state.image = AttachedImage(thumbnail: sample, takenAt: Date().addingTimeInterval(-40))
        state.entries[0].image = EntryImage(thumbnail: sample, route: .sent("claude"))
        state.entries[1].image = EntryImage(thumbnail: sample, route: .local)
        state.entries[2].outcome = .stopped("新しい質問を優先しました")   // l10n-skip: preview sample
        state.keyHint = "右 ⌥（ropt）"   // l10n-skip: preview sample
        state.submit = { _ in }
        if pendingOnly {   // 考えている最中：順番待ちも、見本で出す
            state.entries[state.entries.count - 1].partial = "明日の東京は、晴れ時々くもりの予報です。\n最高気温は 24 度、降水確率は午前 10%・午後 30% です。夕方から、風が"   // l10n-skip: preview sample（答えが、少しずつ届いている途中）
            state.queue.enqueue("もう少し詳しく教えて", source: .typed)   // l10n-skip: preview sample
            state.queue.enqueue("それと、明後日の天気も", source: .voice)   // l10n-skip: preview sample
        }
        if pendingOnly { state.entries = Array(state.entries.suffix(2)); state.image = nil; state.speaking = false } else { state.speaking = true; state.speakingEntry = state.entries.first?.id }
        state.solid = true
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindowIfNeeded() -> DocumentWindowFrame {
        if let window { return window }
        let window = DocumentWindowFrame(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 420, height: 380)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]   // Space（デスクトップ）を移動しても、ついてくる（どの Space でも、同じ位置に出る）
        window.onEscape = {
            guard SaySpeaker.shared.isSpeaking(.conversation) else { return false }
            SaySpeaker.shared.stop()
            return true
        }
        let root = ChatView(
            state: state,
            stopSpeaking: { SaySpeaker.shared.stop() },
            speak: { [unowned self] entry in
                SaySpeaker.shared.stop()
                state.speakingEntry = entry.id
                SaySpeaker.shared.say(chunks: SpokenText.chunks(from: entry.answer ?? ""), channel: .conversation)
            },
            reset: { AppActions.resetConversation() },
            attach: { Task { @MainActor in await ChatWindow.shared.attachScreenshot() } },
            detach: { ChatWindow.shared.detachImage() },
            copyAll: { [unowned self] in copyAll() },
            close: { [unowned window] in window.close() })
        window.contentView = NSHostingView(rootView: root.userScaled().environment(\.colorScheme, .dark))
        scaleObserver = UIScale.shared.$size.dropFirst().sink { [weak self] _ in MainActor.assumeIsolated { self?.rerenderAnswers() } }
        self.window = window
        return window
    }

    /// 文字の大きさが変わった：整形済みの答えを、新しい大きさで、組み直す。
    private func rerenderAnswers() {
        for index in state.entries.indices {
            if let answer = state.entries[index].answer { state.entries[index].rendered = Self.render(answer) }
        }
    }

    /// 答えを整形する（終わりの、空の行は、除く：カードの下に、余白ができるため）。
    private static func render(_ markdown: String) -> NSAttributedString {
        let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer.render(markdown, imageBase: ChatMode.shared.folder ?? ExternalChatBackend.defaultFolder))
        while rendered.length > 0, rendered.string.last == "\n" { rendered.deleteCharacters(in: NSRange(location: rendered.length - 1, length: 1)) }
        return rendered
    }

    private func copyAll() {
        let text = state.entries.map { entry in
            tr("あなた：\(entry.question)") + "\n\n" + (entry.answer ?? "") + (entry.activities.isEmpty ? "" : "\n\n" + tr("実行した操作：") + "\n" + entry.activities.map { "- \($0.text)" }.joined(separator: "\n"))
        }.joined(separator: "\n\n---\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.state.copied = false }
    }
}

// MARK: 状態

/// 会話に添えた画像。
struct AttachedImage: Identifiable {
    let id = UUID()
    let thumbnail: NSImage
    let takenAt: Date
    /// これを過ぎると、使えない（`ScreenshotStore.timeToLive`）。
    var expiresAt: Date { takenAt.addingTimeInterval(ScreenshotStore.timeToLive) }
}

/// 会話のキーの、いまの状態。
enum ChatVoiceState: Equatable {
    case idle
    /// キーを押している間、聞いている。
    case listening
    /// 離した：文字にしている。
    case recognizing
}

/// 画面の状態。SwiftUI の `@State` は、この環境（コマンドラインツールだけ）では、マクロのプラグインがなく使えないので、参照型にする。
@MainActor final class ChatWindowState: ObservableObject {
    @Published var entries: [ChatEntry] = []
    /// 声の状態（会話のキーの録音・認識）。ウィンドウの下の案内に出す。
    @Published var voice = ChatVoiceState.idle
    /// 会話のキーの名前（案内用。なければ、キーなし）。
    @Published var keyHint: String?
    /// 入力欄の文字。
    @Published var draft = ""
    /// 会話の答えを、読んでいるか（スキルの結果などの読み上げは、含まない）。
    @Published var speaking = false
    /// 読んでいる答え（その答えにだけ、「止める」を出す）。
    @Published var speakingEntry: UUID?
    @Published var copied = false
    @Published var agent = ""
    @Published var warning: String?
    @Published var tools: String?
    /// 増えると、いちばん新しい往復の頭へ、スクロールする。
    @Published var scrollToken = 0
    /// 記録を、上へ戻って読んでいる（最新から離れている）：「最新へ」のボタンを出す。`ChatScroll` で判断する。
    @Published var awayFromBottom = false
    /// 会話に添えるファイル（次の質問に付く）。
    @Published var files: [ChatFile] = []
    /// ファイルを断った理由（しばらく出す）。
    @Published var fileNotice: String?
    /// ファイルを、ウィンドウの上へ、ドラッグしている最中。
    @Published var dropTargeted = false
    var addFiles: (@MainActor ([URL]) -> Void)?
    var removeFile: (@MainActor (UUID) -> Void)?
    var pickFiles: (@MainActor () -> Void)?
    /// 会話に添えてある画像（撮ってから 180 秒だけ、使える）。
    @Published var image: AttachedImage?
    /// 範囲を選んでいる間。
    @Published var capturing = false
    /// 順番待ち（考えている間に送った質問）。
    @Published var queue = ChatQueue()
    /// 入力欄から質問を送る（`ChatWindow` が決める：考えていなければ始め、考えている間は順番待ちへ）。
    var submit: (@MainActor (String) -> Void)?
    /// 順番待ちの「今すぐ送る」・「取り下げ」・考えている質問の「停止」。
    var sendNow: (@MainActor (UUID) -> Void)?
    var removeQueued: (@MainActor (UUID) -> Void)?
    var stopTurn: (@MainActor () -> Void)?
    /// 画像に描く確認用：ガラスの代わりに、暗い面を敷く。
    @Published var solid = false
}
