import AppKit
import SwiftUI
import VCCore

/// 会話の入力欄の、**Return の扱い**（純粋）：**Return で送信・⇧Return（⌥Return）で改行**。日本語の入力（変換中の Return）は、入力の仕組みが先に受けるので、ここには来ない（変換の確定で、送信されない）。
enum ComposerReturn: Equatable {
    case send, newline

    static func action(shift: Bool, option: Bool) -> ComposerReturn { (shift || option) ? .newline : .send }
}

/// 会話の入力欄：**複数行**（⇧Return で改行・Return で送信）。1 行から、**最大 `maxLines` 行**まで、文字に合わせて高くなり、それより長ければ、中でスクロールする。`NSTextView`（変換中の文字・⌘Z・文字の選択は、標準のまま）。
/// 背景・縁・余白は、呼ぶ側（`ComposerBar`）が決める。
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let onSend: () -> Void
    /// Finder でコピーしたファイルを貼り付けたとき（文字ではなく、ファイルとして添える）。
    var onPasteFiles: (([URL]) -> Void)?
    static let maxLines = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        let view = Self.makeTextView(fontSize: fontSize)
        view.delegate = context.coordinator
        view.onPasteFiles = onPasteFiles
        view.setAccessibilityLabel(tr("メッセージ"))
        scroll.documentView = view
        context.coordinator.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        (view as? ComposerTextView)?.onPasteFiles = onPasteFiles
        if view.font?.pointSize != fontSize { view.font = .systemFont(ofSize: fontSize) }
        // 同じなら、触らない（入力の途中で、カーソルや変換中の文字を、壊さない）。送信で空にしたときなど、外から変わったときだけ
        if view.string != text { view.string = text }
    }

    /// 入力欄の `NSTextView`。**TextKit 1 を、明示する**（高さの測定が、レイアウトの管理に頼るため。既定の TextKit 2 では、測れなかった）。
    static func makeTextView(fontSize: CGFloat) -> ComposerTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20), textContainer: container)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = .white
        view.insertionPointColor = .white
        return view
    }

    /// 文字に合わせた高さ（1 行〜`maxLines` 行）。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView, let measured = Self.measure(view, width: proposal.width ?? 300, fallbackFontSize: fontSize) else { return nil }
        scroll.hasVerticalScroller = measured.overflows
        return CGSize(width: proposal.width ?? 300, height: measured.height)
    }

    /// 文字の高さ（1 行〜`maxLines` 行に収める）と、`maxLines` を超えて、中でスクロールが要るか。
    static func measure(_ view: NSTextView, width: CGFloat, fallbackFontSize: CGFloat) -> (height: CGFloat, overflows: Bool)? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: view.font ?? .systemFont(ofSize: fallbackFontSize))
        let used = layout.usedRect(for: container).height
        let limit = lineHeight * CGFloat(maxLines)
        return (ceil(min(max(used, lineHeight), limit)), used > limit + 0.5)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: NSTextView?
        /// 修飾キーの読み取り（テストで、差し替える）。
        var modifiers: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            view.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = modifiers()
            switch ComposerReturn.action(shift: flags.contains(.shift), option: flags.contains(.option)) {
            case .newline:
                textView.insertNewlineIgnoringFieldEditor(nil)
            case .send:
                parent.text = textView.string
                parent.onSend()
            }
            return true
        }
    }
}

/// 入力欄の `NSTextView`：**Finder でコピーしたファイルを貼り付けたら、文字ではなく、ファイルとして添える**（それ以外の貼り付けは、標準のまま）。
final class ComposerTextView: NSTextView {
    var onPasteFiles: (([URL]) -> Void)?
    /// 貼り付けの元（テストで、差し替える）。
    var pasteboard: NSPasteboard = .general

    override func paste(_ sender: Any?) {
        let urls = Self.fileURLs(on: pasteboard)
        if !urls.isEmpty, let onPasteFiles { onPasteFiles(urls); return }
        super.paste(sender)
    }

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
