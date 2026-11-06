import Foundation
import Testing
@testable import VCSpeech

/// 文字の入力：クリップボードに書いて、⌘V を送り、**貼り付け先が読んだのを確かめて**、元のクリップボードへ戻す。
/// 読まれなければ、一度だけ送り直し、それでも読まれなければ、入力できなかったと返す。ほかのアプリが書き換えていたら、戻さない。
@MainActor @Suite struct ClipboardPasteTests {
    private final class FakePasteboard: PasteboardAccess {
        var items: [[String: Data]]
        var count = 1
        var wroteTransient = false
        var textWasRead = false
        init(items: [[String: Data]]) { self.items = items }
        var changeCount: Int { count }
        func snapshot() -> [[String: Data]] { items }
        func writeTransient(text: String) { items = [["public.utf8-plain-text": Data(text.utf8)]]; wroteTransient = true; textWasRead = false; count += 1 }
        func writePlain(text: String) { items = [["public.utf8-plain-text": Data(text.utf8)]]; count += 1 }
        func restore(_ saved: [[String: Data]]) { items = saved; count += 1 }
        var text: String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
        /// 貼り付け先が、文字を読んだ。
        func read() { textWasRead = true }
    }

    private func make(_ board: FakePasteboard, sent: @escaping @MainActor () -> Void, trusted: Bool = true, between: @escaping @MainActor () -> Void = {}) -> ClipboardPaste {
        ClipboardPaste(pasteboard: board, sendPaste: sent, wait: { _ in between() }, trusted: { trusted })
    }

    /// 貼り付けの間は、入れる文字がクリップボードにあり、読まれたあとで、元の中身に戻る。
    @Test func itPastesTheTextAndRestoresTheOriginalClipboard() async throws {
        let original: [[String: Data]] = [["public.utf8-plain-text": Data("元の文".utf8)]]
        let board = FakePasteboard(items: original)
        var seenAtPaste: String?
        let outcome = try await make(board, sent: { seenAtPaste = board.text; board.read() }).insert("こんにちは")
        #expect(outcome == .inserted)
        #expect(seenAtPaste == "こんにちは")
        #expect(board.items == original)
        #expect(board.wroteTransient)
    }

    /// 元のクリップボードが空なら、空に戻す（入れた文字を、残さない）。
    @Test func anEmptyClipboardStaysEmpty() async throws {
        let board = FakePasteboard(items: [])
        try await make(board, sent: { board.read() }).insert("入れる文字")
        #expect(board.items.isEmpty)
    }

    /// 読まれたあとに、ほかのアプリが、クリップボードを書き換えたら、戻さない（利用者の新しいコピーを、消さない）。
    @Test func itDoesNotOverwriteAClipboardThatSomeoneElseChanged() async throws {
        let board = FakePasteboard(items: [["public.utf8-plain-text": Data("元".utf8)]])
        let user: [[String: Data]] = [["public.utf8-plain-text": Data("利用者が、いまコピーした文".utf8)]]
        let outcome = try await make(board, sent: { board.read() }, between: { board.items = user; board.count += 1 }).insert("入れる文字")
        #expect(outcome == .inserted)
        #expect(board.items == user)
    }

    /// 1 回目の ⌘V が、受け付けられなくても（読まれない）、送り直せば入る。送り直すのは、1 回だけ。
    @Test func aDroppedPasteIsSentAgainOnce() async throws {
        let original: [[String: Data]] = [["public.utf8-plain-text": Data("元".utf8)]]
        let board = FakePasteboard(items: original)
        var sends = 0
        let outcome = try await make(board, sent: { sends += 1; if sends == 2 { board.read() } }).insert("入れる文字")
        #expect(outcome == .inserted)
        #expect(sends == 2)
        #expect(board.items == original)
    }

    /// 何度送っても読まれなければ、入力できなかったと返し（成功に見せない）、文字を、クリップボードに残す（元には戻さない）。
    @Test func aPasteThatIsNeverReadIsReportedAndTheTextIsKept() async throws {
        let board = FakePasteboard(items: [["public.utf8-plain-text": Data("元".utf8)]])
        var sends = 0
        let outcome = try await make(board, sent: { sends += 1 }).insert("入れる文字")
        #expect(outcome == .notReceived(keptOnClipboard: true))
        #expect(sends == 2)
        #expect(board.text == "入れる文字")
    }

    /// 貼り付け先が遅く（待ち時間の内で）読むなら、送り直さない（二重に入れない）。戻すのは、読まれたあと。
    @Test func aSlowPasteTargetIsWaitedForNotPastedTwice() async throws {
        let original: [[String: Data]] = [["public.utf8-plain-text": Data("元".utf8)]]
        let board = FakePasteboard(items: original)
        var sends = 0
        var ticks = 0
        var restoredBeforeRead = false
        let outcome = try await make(board, sent: { sends += 1 }, between: {
            ticks += 1
            if board.textWasRead == false && board.items == original { restoredBeforeRead = true }
            if ticks == 12 { board.read() }
        }).insert("入れる文字")
        #expect(outcome == .inserted)
        #expect(sends == 1)
        #expect(!restoredBeforeRead)
        #expect(board.items == original)
    }

    /// 待つ間に、利用者が、別のものをコピーしたら、送り直さず、その中身を、そのままにする（文字は、残せない）。
    @Test func aCopyDuringTheWaitStopsTheRetryAndIsLeftAlone() async throws {
        let board = FakePasteboard(items: [["public.utf8-plain-text": Data("元".utf8)]])
        let user: [[String: Data]] = [["public.utf8-plain-text": Data("利用者のコピー".utf8)]]
        var sends = 0
        let outcome = try await make(board, sent: { sends += 1 }, between: { board.items = user; board.count += 1 }).insert("入れる文字")
        #expect(outcome == .notReceived(keptOnClipboard: false))
        #expect(sends == 1)
        #expect(board.items == user)
    }

    /// 許可がなければ、クリップボードに触らず、⌘V も送らずに、投げる。
    @Test func withoutPermissionItTouchesNothing() async {
        let original: [[String: Data]] = [["public.utf8-plain-text": Data("元".utf8)]]
        let board = FakePasteboard(items: original)
        var sentKey = false
        await #expect(throws: ClipboardPaste.Failure.notTrusted) { try await make(board, sent: { sentKey = true }, trusted: false).insert("入れる文字") }
        #expect(board.items == original && !sentKey && !board.wroteTransient)
    }

    /// 空の文字は、何もしない。
    @Test func emptyTextDoesNothing() async throws {
        let board = FakePasteboard(items: [])
        var sentKey = false
        try await make(board, sent: { sentKey = true }).insert("")
        #expect(!sentKey && !board.wroteTransient)
    }
}
