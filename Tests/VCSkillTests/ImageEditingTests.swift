import CoreGraphics
import Foundation
import Testing
import VCCore
@testable import VCSkill

/// `vc image` / `vc see`：画像の操作が、保存先・いまのスクリーンショット・引数の検査を守る。
@Suite struct ImageEditingTests {
    fileprivate struct Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ie-\(UUID().uuidString)")
        var store: URL { root.appendingPathComponent("store") }
        var out: URL { root.appendingPathComponent("out") }
        func editing() -> ImageEditing { ImageEditing(storeDirectory: store, outputDirectory: out, now: Date()) }
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
