import AppKit
import SwiftUI
import Testing
@testable import vc

/// 会話の入力欄：Return で送信・⇧Return（⌥Return）で改行。**文は、作り物**。
@Suite @MainActor struct ChatComposerFieldTests {
    @Test func returnSendsAndShiftOrOptionReturnInsertsANewLine() {
        #expect(ComposerReturn.action(shift: false, option: false) == .send)
        #expect(ComposerReturn.action(shift: true, option: false) == .newline)
        #expect(ComposerReturn.action(shift: false, option: true) == .newline)
    }

    /// 本物の `NSTextView` に、改行の命令（`insertNewline:`）を送る：修飾キーで、送信か改行かが、決まる。
    @Test func theTextViewTurnsReturnIntoSendAndShiftReturnIntoALineBreak() {
        final class Box { var text = ""; var sent = 0 }
        let box = Box()
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let field = ComposerField(text: binding, fontSize: 13, onSend: { box.sent += 1 })
        let coordinator = field.makeCoordinator()
        let view = NSTextView()
        coordinator.textView = view
        view.string = "一行目"

        coordinator.modifiers = { [.shift] }
        #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        view.insertText("二行目", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
        #expect(view.string == "一行目\n二行目" && box.sent == 0)          // ⇧Return：改行（送信しない）

        coordinator.modifiers = { [] }
        #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(box.sent == 1 && box.text == "一行目\n二行目")              // Return：複数行の全文を、送信
        #expect(!coordinator.textView(view, doCommandBy: #selector(NSResponder.moveLeft(_:))))   // ほかの命令は、標準のまま
    }

    @Test func theHeightGrowsWithTheTextUpToTheMaximumNumberOfLines() {
        let view = ComposerField.makeTextView(fontSize: 13)
        func height(_ text: String) -> CGFloat {
            view.string = text
            return ComposerField.measure(view, width: 300, fallbackFontSize: 13)!.height
        }
        let one = height("あ"), three = height("あ\nい\nう"), many = height(Array(repeating: "あ", count: 30).joined(separator: "\n"))
        #expect(three > one * 2.5 && three < one * 3.5)                    // 3 行は、1 行の約 3 倍
        #expect(many > one * 5.5 && many < one * 6.5)                      // 長くても、6 行で止まる（中で、スクロール）
        #expect(height("") == one)                                          // 空でも、1 行分（つぶれない）
        view.string = Array(repeating: "あ", count: 30).joined(separator: "\n")
        #expect(ComposerField.measure(view, width: 300, fallbackFontSize: 13)!.overflows)   // 6 行を超えたら、中でスクロール
        view.string = "あ\nい"
        #expect(!ComposerField.measure(view, width: 300, fallbackFontSize: 13)!.overflows)
    }
}
