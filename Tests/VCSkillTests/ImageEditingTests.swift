import CoreGraphics
import Foundation
import TestSupport
import Testing
import VCCore
@testable import VCSkill

/// `vc image` / `vc see`：画像の操作が、保存先・いまのスクリーンショット・引数の検査を守る。
@Suite struct ImageEditingTests {
    struct Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ie-\(UUID().uuidString)")
        var store: URL { root.appendingPathComponent("store") }
        var out: URL { root.appendingPathComponent("out") }
        /// 既定では、**クリップボードは空**（テストが、利用者の実際のクリップボードを、読まないため）。コピーした画像を使うテストは、`ImageEditingFromClipboardTests` が、差し替える。
        func editing() -> ImageEditing {
            var e = ImageEditing(storeDirectory: store, outputDirectory: out, now: Date())
            e.clipboardImage = { .failure(.clipboardEmpty) }
            e.clipboardMissing = { .clipboardEmpty }
            e.discardClipboard = {}
            return e
        }
        /// 幅 100・高さ 50 の画像を、いまのスクリーンショットにする。
        func putShot() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
            let source = root.appendingPathComponent("src.png")
            try ImageOps.write(context.makeImage()!, to: source, format: .png)
            try ScreenshotStore.replace(with: source, directory: store)
        }
        func currentSize() throws -> (width: Int, height: Int) { try ImageOps.size(of: ScreenshotStore.current(directory: store).get()) }
    }

    @Test func cropSavesANewFileAndReplacesTheCurrentShot() throws {
        let box = Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        let text = try box.editing().run(["crop", "--left", "0.5", "--width", "0.5"]).get()
        #expect(text.contains("50x50") && text.hasPrefix("saved: \(box.out.path)/shot-"))
        let files = try FileManager.default.contentsOfDirectory(atPath: box.out.path)
        #expect(files.count == 1 && files[0].hasSuffix(".png"))
        let size = try box.currentSize()
        #expect(size.width == 50 && size.height == 50)   // 続けて、加工できる
        let more = try box.editing().run(["resize", "--width", "25"]).get()
        #expect(more.contains("25x25"))
    }

    @Test func convertWritesTheRequestedFormatAndKeepsThePixels() throws {
        let box = Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        let text = try box.editing().run(["convert", "jpeg"]).get()
        #expect(text.contains(".jpg") && text.contains("100x50"))
        #expect(try ImageOps.size(of: URL(fileURLWithPath: String(text.dropFirst("saved: ".count).prefix(while: { $0 != " " })))).width == 100)
    }

    @Test func wrongArgumentsAreRefusedWithoutWritingAnything() throws {
        let box = Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        let bad: [[String]] = [[], ["blur"], ["crop", "--left", "abc"], ["crop", "--left", "0.8", "--width", "0.5"], ["crop", "--output", "/tmp/x"],
                               ["resize"], ["resize", "--width", "10", "--percent", "50"], ["resize", "--width", "100.5"], ["rotate", "45"], ["convert", "bmp"], ["convert"]]
        for arguments in bad {
            guard case let .failure(failure) = box.editing().run(arguments) else { Issue.record("拒否するはず: \(arguments)"); continue }
            #expect(failure.exitCode == 2, "\(arguments)")
        }
        #expect(!FileManager.default.fileExists(atPath: box.out.path))
        let size = try box.currentSize()
        #expect(size.width == 100)   // いまのスクリーンショットは、そのまま
    }

    @Test func withoutAShotTheCommandsExplainWhatToDo() {
        let box = Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        guard case let .failure(failure) = box.editing().run(["rotate", "90"]) else { Issue.record("失敗するはず"); return }
        #expect(failure.exitCode == 1 && failure.message.contains("スクリーンショット"))
    }

    @Test func seeNeedsExactlyOneInstruction() {
        var commands = InternalCommands(request: "", scorer: nil, memory: OptionMemory())
        commands.vision = { _, question, _, _ in .success("答え: \(question)") }
        for arguments in [["a", "b"], [" "], [String(repeating: "あ", count: InternalCommands.maxQuestion + 1)]] {
            #expect(commands.execute(["vc", "see"] + arguments).isFailure, "\(arguments.count)")
        }
        // 引数なしは、依頼の文を使う（依頼が空なら、拒否）
        #expect(commands.execute(["vc", "see"]).isFailure)
        #expect(InternalCommands.handles(["vc", "see", "x"]) && InternalCommands.handles(["vc", "image", "crop"]))
    }
}

private extension Result { var isFailure: Bool { if case .failure = self { return true } else { return false } } }

extension ImageEditingTests {
    @Test func namedPartsCropTheExpectedHalf() throws {
        let box = Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()   // 100 × 50
        for (part, size) in [("right-half", "50x50"), ("left-half", "50x50"), ("top-half", "100x25"), ("bottom-half", "100x25"), ("center", "50x25")] {
            try box.putShot()
            #expect(try box.editing().run(["crop", part]).get().contains(size), "\(part)")
        }
        #expect(box.editing().run(["crop", "middle"]).isFailure)
    }
}

extension ImageEditingTests {
    @Test func savedPathIsReadFromTheCommandOutput() {
        #expect(ImageEditing.savedPath(in: "saved: /Users/a b/Pictures/voice-control/shot-1.png (100x50, png)") == "/Users/a b/Pictures/voice-control/shot-1.png")
        #expect(ImageEditing.savedPath(in: "error: no screenshot") == nil)
        #expect(ImageEditing.savedPath(in: "saved:  (1x1, png)") == nil)
    }

    @Test func outputNamesNeverOverwriteAnExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("so-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let first = try ShotOutput.nextURL(in: dir, ext: "png", now: now)
        try Data("a".utf8).write(to: first)
        let second = try ShotOutput.nextURL(in: dir, ext: "png", now: now)
        #expect(first != second && second.lastPathComponent.hasSuffix("-2.png") && first.lastPathComponent.hasPrefix("shot-"))
        #expect(try ShotOutput.nextURL(in: dir, ext: "jpg", now: now).pathExtension == "jpg")
    }
}

extension ImageEditingTests {
    /// `vc see` の答えと `vc image` の保存先は、モデルに返す文とは別の成果物として持つ。失敗には、成果物がない。
    @Test func deliverablesAreSeparateFromTheTextForTheModel() throws {
        let box = Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        var commands = InternalCommands(request: "x", scorer: nil, memory: OptionMemory())
        commands.images = box.editing()
        commands.vision = { _, _, _, _ in .success("# 答え") }
        let saved = commands.run(["vc", "image", "rotate", "90"])
        #expect(saved.exitCode == 0 && saved.document == nil && saved.image?.path.hasPrefix(box.out.path) == true)
        let failed = commands.run(["vc", "image", "rotate", "45"])
        #expect(failed.exitCode == 2 && failed.image == nil && failed.text.hasPrefix("error: "))
        #expect(InternalCommands.name(of: ["vc", "see"]) == .see && InternalCommands.name(of: ["vc", "show"]) == nil && InternalCommands.name(of: ["ls", "find"]) == nil)
    }
}

/// `vc image` が、コピーした画像にも使える：**どちらを加工するかは、コードが決める**（`vc see` と同じ。「コピー」とあれば、コピーした画像／なければ、撮ったスクリーンショットが先）。
@Suite struct ImageEditingFromClipboardTests {
    /// 幅 40・高さ 20 の画像を、「コピーした画像」にする（撮ったスクリーンショットは、幅 100・高さ 50）。
    private func editing(_ box: ImageEditingTests.Sandbox, request: String, clipboard: Bool, discards: Collected<Bool>? = nil) throws -> ImageEditing {
        var e = box.editing()
        e.request = request
        let file = box.root.appendingPathComponent("clipboard.png")
        if clipboard {
            let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            try? FileManager.default.removeItem(at: file)   // 同じテストで、何度も作る
            try ImageOps.write(context.makeImage()!, to: file, format: .png)
            e.clipboardImage = { .success(file) }
            e.clipboardMissing = { nil }
        } else {
            e.clipboardImage = { .failure(.clipboardEmpty) }
            e.clipboardMissing = { .clipboardEmpty }
        }
        e.discardClipboard = { discards?.add(true) }
        return e
    }

    @Test func saysCopyAndTheCopiedImageIsEdited() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        let discards = Collected<Bool>()
        let text = try editing(box, request: "コピーした画像の右半分を切り抜いて", clipboard: true, discards: discards).run(["crop", "right-half"]).get()
        #expect(text.contains("20x20"))   // 40×20 の右半分（撮ったスクリーンショット 100×50 なら、50x50）
        #expect(discards.values.count == 1)   // 書き出しは、使い終わったら、消す
        let size = try box.currentSize()
        #expect(size.width == 20 && size.height == 20)   // 結果が、いまの画像になる：続けて、加工できる
    }

    @Test func withoutTheWordCopyTheScreenshotComesFirst() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        let discards = Collected<Bool>()
        let text = try editing(box, request: "右半分を切り抜いて", clipboard: true, discards: discards).run(["crop", "right-half"]).get()
        #expect(text.contains("50x50") && discards.values.isEmpty)
    }

    @Test func withoutAScreenshotTheCopiedImageIsUsed() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try FileManager.default.createDirectory(at: box.root, withIntermediateDirectories: true)
        let text = try editing(box, request: "右半分を切り抜いて", clipboard: true).run(["crop", "right-half"]).get()
        #expect(text.contains("20x20"))
    }

    /// 「コピー」と言ったのに、コピーした画像がないときは、スクリーンショットで、代わりにしない（案内が出る）。
    @Test func saysCopyButNothingIsCopiedIsReportedNotSubstituted() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        guard case let .failure(failure) = try editing(box, request: "コピーした画像を回転して", clipboard: false).run(["rotate", "90"]) else { Issue.record("失敗するはず"); return }
        #expect(failure.message.contains("クリップボードに画像がありません"))
        #expect(try box.currentSize().width == 100)   // スクリーンショットは、そのまま
    }

    /// `--from`：取り先を、はっきり指定する（依頼の文に、「コピー」があっても、なくても、指定が勝つ）。
    @Test func fromOverridesTheWordsInTheRequest() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        let copied = try editing(box, request: "右半分を切り抜いて", clipboard: true).run(["--from", "clipboard", "crop", "right-half"]).get()
        #expect(copied.contains("20x20"))   // 「コピー」と言っていなくても、コピーした画像
        try box.putShot()
        let shot = try editing(box, request: "コピーした画像の右半分を切り抜いて", clipboard: true).run(["crop", "right-half", "--from", "screenshot"]).get()
        #expect(shot.contains("50x50"))   // 「コピー」と言っても、スクリーンショット（位置は、どこでもよい）
    }

    @Test func fromRefusesUnknownSourcesAndMissingValues() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        for arguments in [["--from", "file", "crop", "right-half"], ["--from", "any", "crop", "right-half"], ["crop", "right-half", "--from"]] {
            guard case let .failure(failure) = try editing(box, request: "x", clipboard: true).run(arguments) else { Issue.record("\(arguments) は、失敗するはず"); return }
            #expect(failure.exitCode == 2 && failure.message.contains("--from"))
        }
        #expect(try box.currentSize().width == 100)   // 何も加工しない
    }

    /// `--from clipboard` で、コピーした画像がないときは、スクリーンショットで、代わりにしない。
    @Test func fromClipboardWithNothingCopiedIsReported() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        guard case let .failure(failure) = try editing(box, request: "x", clipboard: false).run(["--from", "clipboard", "rotate", "90"]) else { Issue.record("失敗するはず"); return }
        #expect(failure.message.contains("クリップボードに画像がありません"))
    }

    /// 続けての加工：同じ実行の中の 2 つ目は、**1 つ目の結果**を使う（「コピー」と言っていても、元のコピーした画像に、戻らない）。
    @Test func aSecondCommandInTheSameRunBuildsOnTheFirstResult() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try FileManager.default.createDirectory(at: box.root, withIntermediateDirectories: true)
        let e = try editing(box, request: "コピーした画像の右半分を切り抜いて、さらに右半分に", clipboard: true)
        #expect(try e.run(["crop", "right-half"]).get().contains("20x20"))   // 40×20 の右半分
        #expect(try e.run(["crop", "right-half"]).get().contains("10x20"))   // その結果（20×20）の右半分：元の 40×20 に、戻らない
        // 実行が違えば（新しい ImageEditing）、また、コピーした画像から
        #expect(try editing(box, request: "コピーした画像の右半分を切り抜いて", clipboard: true).run(["crop", "right-half"]).get().contains("20x20"))
    }

    @Test func fromStillWinsOverTheWorkingImage() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        let e = try editing(box, request: "x", clipboard: true)
        #expect(try e.run(["--from", "clipboard", "crop", "right-half"]).get().contains("20x20"))   // 加工中の画像：20×20
        try box.putShot()   // スクリーンショットを、100×50 に戻す
        #expect(try e.run(["--from", "screenshot", "crop", "right-half"]).get().contains("50x50"))   // 加工中の画像（20×20 → 10x20）ではなく、スクリーンショット
    }

    @Test func squareCropsTheShorterSideAroundTheCenter() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()   // 100×50
        let text = try editing(box, request: "真四角にくり抜いて", clipboard: false).run(["crop", "square"]).get()
        #expect(text.contains("50x50"))
    }

    @Test func neitherImageGivesAHint() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        guard case let .failure(failure) = try editing(box, request: "回転して", clipboard: false).run(["rotate", "90"]) else { Issue.record("失敗するはず"); return }
        #expect(failure.exitCode == 1 && !failure.message.isEmpty)
    }
}

/// `vc image remove-background`（F51。実験）：主役を残して背景を透明にする。Vision は CI の VM では動かない（`RunEnvironment.isCI`）。
@Suite struct RemoveBackgroundTests {
    private static let stock = URL(fileURLWithPath: "/Library/User Pictures/Animals/Penguin.heic")   // macOS に入っている、写真（個人のものではない）

    @Test func takesNoArguments() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()
        guard case let .failure(failure) = box.editing().run(["remove-background", "--all"]) else { Issue.record("引数があるときは、失敗するはず"); return }
        #expect(failure.exitCode == 2)
    }

    @Test(.disabled(if: RunEnvironment.isCI, "\(RunEnvironment.platformMediaReason)"))
    func aPictureWithoutASubjectIsReportedNotSavedAsIs() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try box.putShot()   // 無地の黄色：主役がない
        guard case let .failure(failure) = box.editing().run(["remove-background"]) else { Issue.record("主役がないときは、失敗するはず"); return }
        #expect(failure.exitCode == 1 && failure.message.contains("主役"))
        #expect(!FileManager.default.fileExists(atPath: box.out.path) || ((try? FileManager.default.contentsOfDirectory(atPath: box.out.path)) ?? []).isEmpty)   // 何も保存しない
    }

    @Test(.disabled(if: RunEnvironment.isCI, "\(RunEnvironment.platformMediaReason)"), .enabled(if: FileManager.default.fileExists(atPath: Self.stock.path), "macOS の標準の画像がない"))
    func theBackgroundBecomesTransparentAndTheSubjectStays() throws {
        let image = try ImageOps.load(Self.stock)
        let cut = try BackgroundRemoval.remove(from: image)
        #expect(cut.width == image.width && cut.height == image.height)
        #expect(cut.alphaInfo != .none && cut.alphaInfo != .noneSkipFirst && cut.alphaInfo != .noneSkipLast)
        // 角（背景）は透明・中心（主役）は不透明
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cut, in: CGRect(x: -x, y: -(cut.height - 1 - y), width: cut.width, height: cut.height))
            return pixel[3]
        }
        #expect(alpha(2, 2) == 0 && alpha(cut.width / 2, cut.height / 2) == 255)
    }

    /// コマンドとして：標準の画像を、いまのスクリーンショットにして、背景を消す → PNG（透明つき）で保存され、続けて加工できる。
    @Test(.disabled(if: RunEnvironment.isCI, "\(RunEnvironment.platformMediaReason)"), .enabled(if: FileManager.default.fileExists(atPath: Self.stock.path), "macOS の標準の画像がない"))
    func theCommandSavesATransparentPNGAndKeepsTheResultAsTheCurrentShot() throws {
        let box = ImageEditingTests.Sandbox(); defer { try? FileManager.default.removeItem(at: box.root) }
        try FileManager.default.createDirectory(at: box.root, withIntermediateDirectories: true)
        let source = box.root.appendingPathComponent("stock.png")
        try ImageOps.write(try ImageOps.load(Self.stock), to: source, format: .png)
        try ScreenshotStore.replace(with: source, directory: box.store)
        let text = try box.editing().run(["remove-background"]).get()
        #expect(text.hasPrefix("saved: \(box.out.path)/shot-") && text.hasSuffix(", png)"))
        let saved = try FileManager.default.contentsOfDirectory(atPath: box.out.path)
        #expect(saved.count == 1 && saved[0].hasSuffix(".png"))
        let result = try ImageOps.load(box.out.appendingPathComponent(saved[0]))
        #expect(result.alphaInfo != .none && result.alphaInfo != .noneSkipLast && result.alphaInfo != .noneSkipFirst)
        let size = try box.currentSize()
        #expect(size.width == result.width && size.height == result.height)   // 続けて、加工できる
    }
}
