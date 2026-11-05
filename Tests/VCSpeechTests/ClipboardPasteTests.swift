import Foundation
import Testing
@testable import VCSpeech

/// 文字の入力：クリップボードに書いて、⌘V を送り、元のクリップボードへ戻す。ほかのアプリが書き換えていたら、戻さない。
@MainActor @Suite struct ClipboardPasteTests {
    private final class FakePasteboard: PasteboardAccess {
        var items: [[String: Data]]
        var count = 1
        var wroteTransient = false
        init(items: [[String: Data]]) { self.items = items }
        var changeCount: Int { count }
        func snapshot() -> [[String: Data]] { items }
        func writeTransient(text: String) { items = [["public.utf8-plain-text": Data(text.utf8)]]; wroteTransient = true; count += 1 }
        func restore(_ saved: [[String: Data]]) { items = saved; count += 1 }
        var text: String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
    }

    private func make(_ board: FakePasteboard, sent: @escaping @MainActor () -> Void, trusted: Bool = true, between: @escaping @MainActor () -> Void = {}) -> ClipboardPaste {
        ClipboardPaste(pasteboard: board, sendPaste: sent, restoreDelay: 0, wait: { _ in between() }, trusted: { trusted })
    }

    /// 貼り付けの間は、入れる文字がクリップボードにあり、終わると、元の中身に戻る。
    @Test func itPastesTheTextAndRestoresTheOriginalClipboard() async throws {
        let original: [[String: Data]] = [["public.utf8-plain-text": Data("元の文".utf8)]]
        let board = FakePasteboard(items: original)
        var seenAtPaste: String?
        try await make(board, sent: { seenAtPaste = board.text }).insert("こんにちは")
        #expect(seenAtPaste == "こんにちは")
        #expect(board.items == original)
        #expect(board.wroteTransient)
    }

    /// 元のクリップボードが空なら、空に戻す（入れた文字を、残さない）。
    @Test func anEmptyClipboardStaysEmpty() async throws {
        let board = FakePasteboard(items: [])
        try await make(board, sent: {}).insert("入れる文字")
        #expect(board.items.isEmpty)
    }

    /// 待っている間に、ほかのアプリが、クリップボードを書き換えたら、戻さない（利用者の新しいコピーを、消さない）。
    @Test func itDoesNotOverwriteAClipboardThatSomeoneElseChanged() async throws {
        let board = FakePasteboard(items: [["public.utf8-plain-text": Data("元".utf8)]])
        let user: [[String: Data]] = [["public.utf8-plain-text": Data("利用者が、いまコピーした文".utf8)]]
        try await make(board, sent: {}, between: { board.items = user; board.count += 1 }).insert("入れる文字")
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
