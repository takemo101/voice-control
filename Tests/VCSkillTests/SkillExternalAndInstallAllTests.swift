import AppKit
import Foundation
import TestSupport
import Testing
@testable import VCSkill
import VCCore
import VCDecision

/// スキルの `external`（発話を、この Mac の外へ送る先）と、`vc skills install --all`（リポジトリの、すべてのスキルを置く）。
@Suite struct SkillExternalAndInstallAllTests {
    private func parse(_ front: String) -> Skill? {
        try? SkillStore.parse("---\nname: demo\ndescription: x\nallowed-commands: echo\n\(front)---\nbody", directoryName: "demo", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md")).get()
    }

    /// 書かなければ、送らない（nil）。書けば、その文字。空は、書かないのと同じ。
    @Test func externalIsNilUnlessWritten() {
        #expect(parse("")?.external == nil)
        #expect(parse("external: Google（agy）\n")?.external == "Google（agy）")
        #expect(parse("external:\n")?.external == nil)
    }

    /// 外へ送るものの断り書き：既定は「発話」。画像のスキル（`image: true`）は「撮った画面の画像と質問」。確認の理由は、何を・どこへ送るかを言う。外へ送らないスキルは、従来どおり。
    @Test func theNoticeSaysWhatIsSentWhere() throws {
        #expect(parse("external: Google（agy）\n")?.externalNotice == "発話を、Google（agy） へ送ります")
        let image = try #require(parse("external: OpenAI（codex）\nimage: true\nconfirm: true\n"))
        #expect(image.externalNotice == "撮った画面の画像と質問を、OpenAI（codex） へ送ります")
        #expect(SkillResolver.confirmReason(for: image) == "撮った画面の画像と質問を、OpenAI（codex） へ送ります。実行の前に確認します")
        #expect(parse("image: true\n")?.externalNotice == nil)   // 送り先がなければ、何も送らない
        let local = try #require(parse("confirm: true\n"))
        #expect(SkillResolver.confirmReason(for: local) == SkillResolver.confirmRequiredReason)
    }

    /// 偽のリポジトリ：スキル 2 つ（`alpha`・`beta`〔external つき〕）と、読めないもの（`broken`）。
    private final class Repo: @unchecked Sendable {
        private let lock = NSLock(); private(set) var refs: [String] = []
        let files: [String: String] = [
            ".voice-control/skills/alpha/SKILL.md": "---\nname: alpha\ndescription: a\nallowed-commands: echo\n---\nRun.",
            ".voice-control/skills/beta/SKILL.md": "---\nname: beta\ndescription: b\nallowed-commands: echo\nexternal: どこか\n---\nRun.",
            ".voice-control/skills/broken/SKILL.md": "フロントマターがない",
        ]
        var fetch: RemoteSkills.Fetch {
            { [self] url in
                if url.host == "api.github.com" {
                    let ref = url.pathComponents.last ?? ""
                    lock.lock(); refs.append(ref); lock.unlock()
                    guard ref == "main" else { return (Data(), 404) }   // タグは、ない：main に切り替わる
                    let tree = files.keys.sorted().map { ["path": $0, "mode": "100644", "type": "blob", "size": 10] as [String: Any] }
                    return (try JSONSerialization.data(withJSONObject: ["tree": tree]), 200)
                }
                let path = files.keys.first { url.absoluteString.hasSuffix($0) } ?? ""
                return (Data((files[path] ?? "").utf8), 200)
            }
        }
    }

    /// すべてのスキルを置く：読めないものは、置かず、`problems` に出す。タグがなく、main に切り替えても、一覧と置くものは、同じ版（main）。
    @Test func installAllPlacesEveryReadableSkillFromTheSameRef() async throws {
        let repo = Repo()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ia-\(UUID().uuidString)")
        let (report, problems) = try await RemoteInstall.installAll(explicitRef: nil, defaultRef: "v9.9.9", overwrite: false, to: dir, fetch: repo.fetch)
        #expect(report.source == .init(ref: "main", fellBackToMain: true))
        #expect(report.outcomes.map(\.name) == ["alpha", "beta"])
        let installed = report.outcomes.compactMap { try? $0.result.get() }
        #expect(installed.count == 2 && installed.first { $0.name == "beta" }?.external == "どこか" && installed.first { $0.name == "alpha" }?.external == nil)
        #expect(problems.count == 1 && FileManager.default.fileExists(atPath: dir.appendingPathComponent("alpha/SKILL.md").path) && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken").path))
        // 1 回目の一覧で、v9.9.9 → main。置くときは、main を指定する（もう一度、v9.9.9 を試さない）
        #expect(repo.refs.filter { $0 == "v9.9.9" }.count == 1)
    }

    /// すでにあるものは、`--force` なしでは、置き換えず、結果に出る（ほかは、置く）。
    @Test func installAllReportsExistingSkillsAndStillPlacesTheRest() async throws {
        let repo = Repo()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ia-\(UUID().uuidString)")
        _ = try await RemoteInstall.install(names: ["alpha"], explicitRef: "main", defaultRef: "main", overwrite: false, to: dir, fetch: repo.fetch)
        let (report, _) = try await RemoteInstall.installAll(explicitRef: nil, defaultRef: "main", overwrite: false, to: dir, fetch: repo.fetch)
        guard case .failure(.alreadyInstalled("alpha")) = report.outcomes[0].result, case .success = report.outcomes[1].result else { Issue.record("結果が違う"); return }
    }
}

/// `image:`：その画像（撮ったスクリーンショット・コピーした画像）があるときだけ、選択肢に入る（コードが決める）。画像の出し忘れは、用意の仕方を案内する。
@Suite struct ImageSkillTests {
    private static func imageSkill(_ source: ImageSource = .screenshot, _ description: String = "画像を見る") -> Skill { var s = skill("see-\(source.rawValue)", description); s.imageSource = source; return s }
    private static let allThere: @Sendable (ImageSource) -> ImageSource.Missing? = { _ in nil }
    private static let noScreenshot: @Sendable (ImageSource) -> ImageSource.Missing? = { $0 == .screenshot ? .screenshot(.none) : nil }
    private static let noClipboard: @Sendable (ImageSource) -> ImageSource.Missing? = { $0 == .clipboard ? .clipboardEmpty : nil }

    private func parse(_ front: String) -> Result<Skill, SkillStore.ParseError> {
        SkillStore.parse("---\nname: demo\ndescription: x\nallowed-commands: echo\n\(front)---\nbody", directoryName: "demo", file: URL(fileURLWithPath: "/tmp/demo/SKILL.md"))
    }

    @Test func theKeyIsReadFromTheFrontMatter() throws {
        #expect(try parse("image: true\n").get().imageSource == .screenshot)
        #expect(try parse("image: screenshot\n").get().imageSource == .screenshot)
        #expect(try parse("image: Clipboard\n").get().imageSource == .clipboard)
        #expect(try parse("").get().imageSource == nil && parse("image: false\n").get().imageSource == nil)
    }

    @Test func anyIsReadAndChosenByTheCodeNotTheModel() throws {
        #expect(try parse("image: any\n").get().imageSource == .any)
        let both: (ImageSource) -> ImageSource.Missing? = { _ in nil }
        let onlyClipboard: (ImageSource) -> ImageSource.Missing? = { $0 == .screenshot ? .screenshot(.none) : nil }
        let neither: (ImageSource) -> ImageSource.Missing? = { $0 == .screenshot ? .screenshot(.none) : .clipboardEmpty }
        #expect(ImageSource.any.resolve(for: "この画像の文字を書き出して", unavailable: both) == .screenshot)   // 言葉がなければ、撮ったスクリーンショットが先
        #expect(ImageSource.any.resolve(for: "この画像の文字を書き出して", unavailable: onlyClipboard) == .clipboard)   // スクリーンショットがなければ、コピーした画像
        #expect(ImageSource.any.resolve(for: "コピーした画像を要約して", unavailable: both) == .clipboard)
        #expect(ImageSource.any.resolve(for: "クリップボードの画像を読んで", unavailable: both) == .clipboard)
        // 「コピー」と言ったのに、コピーした画像がないときは、スクリーンショットで代わりにしない（案内が出る）
        let onlyScreenshot: (ImageSource) -> ImageSource.Missing? = { $0 == .clipboard ? .clipboardEmpty : nil }
        #expect(ImageSource.any.resolve(for: "コピーした画像を要約して", unavailable: onlyScreenshot) == .clipboard)
        #expect(ImageSource.any.resolve(for: "なんでも", unavailable: neither) == .screenshot)   // どちらもない：案内は、`missing`
        #expect(ImageSource.screenshot.resolve(for: "コピーした画像", unavailable: both) == .screenshot && ImageSource.clipboard.resolve(for: "この画面", unavailable: both) == .clipboard)   // 決まった取り先は、そのまま
    }

    @Test func anUnknownSourceFailsToLoadWithAReason() {
        guard case let .failure(error) = parse("image: file\n") else { Issue.record("読み込みに失敗するはず"); return }
        #expect(error.reason.contains("clipboard"))
    }

    @Test func withTheImageTheImageSkillIsChosen() throws {
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: "画像を見る"), skills: [DefaultSkill.skill, Self.imageSkill()], gate: Gate(), imageMissing: Self.allThere)
        guard case let .resolved(r) = try resolver.resolve("この画像を説明して") else { Issue.record("not resolved"); return }
        #expect(r.skill.name == "see-screenshot")
    }

    /// 画像の出し忘れ：その画像のスキルが選ばれそうな依頼は、既定のスキルに回さず、用意の仕方を案内して、止める（画像の取り先ごとの案内）。
    @Test func forgettingTheImageIsTurnedIntoAHintNotADefaultRun() throws {
        let screenshot = SkillResolver(scorer: SkillScorer(routedDescription: "画像を見る"), skills: [DefaultSkill.skill, Self.imageSkill()], gate: Gate(), imageMissing: Self.noScreenshot)
        guard case let .declined(reason, fallbackAvailable) = try screenshot.resolve("この画像を説明して") else { Issue.record("resolved"); return }
        #expect(reason.contains("スクリーンショットがありません") && !fallbackAvailable)
        let clipboard = SkillResolver(scorer: SkillScorer(routedDescription: "コピー画像を見る"), skills: [DefaultSkill.skill, Self.imageSkill(.clipboard, "コピー画像を見る")], gate: Gate(), imageMissing: Self.noClipboard)
        guard case let .declined(reason2, _) = try clipboard.resolve("コピーした画像を要約して") else { Issue.record("resolved"); return }
        #expect(reason2.contains("クリップボードに画像がありません"))
    }

    @Test func anAnySkillIsHintedOnlyWhenNeitherImageExists() throws {
        let neither: @Sendable (ImageSource) -> ImageSource.Missing? = { _ in .noImage }
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: "画像を見る"), skills: [DefaultSkill.skill, Self.imageSkill(.any)], gate: Gate(), imageMissing: neither)
        guard case let .declined(reason, fallbackAvailable) = try resolver.resolve("この画像を説明して") else { Issue.record("resolved"); return }
        #expect(reason.contains("スクリーンショットも、コピーした画像も") && !fallbackAvailable)
        let one = SkillResolver(scorer: SkillScorer(routedDescription: "画像を見る"), skills: [DefaultSkill.skill, Self.imageSkill(.any)], gate: Gate(), imageMissing: Self.allThere)
        guard case let .resolved(r) = try one.resolve("この画像を説明して") else { Issue.record("not resolved"); return }
        #expect(r.skill.name == "see-any")
    }

    /// 取り先ごとに、独立：スクリーンショットがなくても、コピーした画像のスキルは、選ばれる。
    @Test func eachSourceIsIndependent() throws {
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: "コピー画像を見る"), skills: [DefaultSkill.skill, Self.imageSkill(.screenshot), Self.imageSkill(.clipboard, "コピー画像を見る")], gate: Gate(), imageMissing: Self.noScreenshot)
        guard case let .resolved(r) = try resolver.resolve("コピーした画像を要約して") else { Issue.record("not resolved"); return }
        #expect(r.skill.name == "see-clipboard")
    }

    @Test func otherRequestsAreUnaffectedWithoutAnImage() throws {
        let resolver = SkillResolver(scorer: SkillScorer(routedDescription: nil), skills: [DefaultSkill.skill, skill("spotify", "Spotify の操作"), Self.imageSkill()], gate: Gate(), imageMissing: Self.noScreenshot)
        guard case let .resolved(r) = try resolver.resolve("電卓を開いて") else { Issue.record("not resolved"); return }
        #expect(r.skill.name == "default")
    }
}

/// コピーした画像（クリップボード）：画像のデータも、Finder でコピーした画像ファイルも読める。画像でないものは、「ない」。
@Suite struct ClipboardImageTests {
    private func pngData(_ width: Int, _ height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func workDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func anImageOnThePasteboardIsExportedAsAPrivatePNG() throws {
        let dir = try workDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.clearContents(); board.setData(try pngData(40, 30), forType: .png)
        #expect(ClipboardImage.hasImage(board))
        let url = try ClipboardImage.export(board, directory: dir).get()
        #expect(url.lastPathComponent == "clipboard.png" && (try? ImageOps.pngData(contentsOf: url)) != nil)
        #expect(((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aCopiedImageFileIsReadToo() throws {
        let dir = try workDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("copied.png"); try pngData(20, 20).write(to: file)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.clearContents(); board.writeObjects([file as NSURL])
        #expect(ClipboardImage.hasImage(board))
        #expect((try? ClipboardImage.export(board, directory: dir).get()) != nil)
    }

    @Test func textOrNothingIsNotAnImage() throws {
        let dir = try workDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        #expect(!ClipboardImage.hasImage(board))
        board.clearContents(); board.setString("文章", forType: .string)
        #expect(!ClipboardImage.hasImage(board))
        guard case let .failure(why) = ClipboardImage.export(board, directory: dir), case .clipboardNotAnImage = why else { Issue.record("画像ではない、と返すはず"); return }
        #expect(why.description.contains("画像ではありません") && why.description.contains("public.utf8-plain-text"))   // 何がコピーされているか、形式の名前で分かる（中身は、出さない）
        #expect(!why.description.contains("文章"))
    }

    @Test func otherImageFormatsAppKitUnderstandsAreExportedToo() throws {
        let dir = try workDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.clearContents(); board.setData(try #require(rep.representation(using: .gif, properties: [:])), forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        #expect(ClipboardImage.hasImage(board))
        #expect((try? ClipboardImage.export(board, directory: dir).get()) != nil)
    }

    @Test func anEmptyPasteboardIsReportedAsEmpty() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        #expect(ClipboardImage.missing(board) == .clipboardEmpty)
    }

    @Test func brokenImageDataIsReportedNotExported() throws {
        let dir = try workDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.clearContents(); board.setData(Data("not a png".utf8), forType: .png)
        #expect(ClipboardImage.export(board, directory: dir) == .failure(.clipboardUnreadable))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("clipboard.png").path))
    }
}
