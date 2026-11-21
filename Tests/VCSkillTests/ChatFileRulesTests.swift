import Foundation
import Testing
@testable import VCSkill

/// 会話に添えるファイルの規則：秘密の拒否・上限・文字ファイルの判定・渡し方。**ファイルは、テスト用の作り物（一時フォルダ）**。
@Suite struct ChatFileRulesTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vc-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ name: String, _ data: Data, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    private let home = URL(fileURLWithPath: "/Users/someone")

    @Test func secretLikeNamesAndPlacesAreRefusedButOrdinaryFilesAreNot() {
        for path in ["/Users/someone/.ssh/config", "/Users/someone/proj/.env", "/Users/someone/proj/.env.production", "/Users/someone/.aws/credentials",
                     "/Users/someone/id_rsa", "/Users/someone/key.PEM", "/Users/someone/cert.p12", "/Users/someone/.voice-control/history.jsonl",
                     "/Users/someone/.voice-control/settings.json", "/Users/someone/Library/Keychains/login.keychain-db", "/Users/someone/.npmrc",
                     "/Users/someone/.config/gcloud/application_default_credentials.json"] {
            #expect(ChatFileRules.isSecret(URL(fileURLWithPath: path), home: home), "\(path)")
        }
        for path in ["/Users/someone/notes.md", "/Users/someone/proj/environment.txt", "/Users/someone/id_rsa.pub", "/Users/someone/docs/secretary.txt",
                     "/Users/someone/Documents/見積.pdf", "/Users/someone/proj/.envrc.example.md"] {
            #expect(!ChatFileRules.isSecret(URL(fileURLWithPath: path), home: home), "\(path)")
        }
    }

    @Test func aTextFileIsDetectedAndDeliveredByEmbeddingWhileBinaryOrBigOnesNeedTheReadTool() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let note = try write("メモ.txt", Data("これは、見本の文です。\nsecond line".utf8), in: dir)
        let binary = try write("data.bin", Data([0x89, 0x50, 0x00, 0x47, 0x0D]), in: dir)
        let big = try write("big.txt", Data(repeating: 0x61, count: Int(ChatFileRules.maxEmbedBytes) + 1), in: dir)
        guard case let .success(text) = ChatFileRules.inspect(note, home: home), case let .success(bin) = ChatFileRules.inspect(binary, home: home), case let .success(large) = ChatFileRules.inspect(big, home: home) else { Issue.record("検査に失敗"); return }
        #expect(text.isText && !bin.isText && large.isText)
        #expect(ChatFileRules.delivery(of: text, tools: .none) == .embed)                  // 小さい文字：道具が要らない
        #expect(ChatFileRules.delivery(of: bin, tools: .none) == .needsTools && ChatFileRules.delivery(of: bin, tools: .web) == .needsTools)
        #expect(ChatFileRules.delivery(of: bin, tools: .read) == .link && ChatFileRules.delivery(of: large, tools: .all) == .link)
        #expect(ChatFileRules.delivery(of: large, tools: .none) == .needsTools)             // 大きい文字：埋め込まない
        #expect(ChatFileRules.embeddedText(of: text) == "これは、見本の文です。\nsecond line" && ChatFileRules.embeddedText(of: large) == nil)
    }

    @Test func aMultibyteCharacterCutAtTheEndOfTheSampleStillCountsAsText() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        // 8192 バイトの切れ目に、3 バイトの文字（あ）が、またがる
        let data = Data(repeating: 0x61, count: 8191) + Data("あ".utf8) + Data(repeating: 0x62, count: 100)
        let url = try write("edge.txt", data, in: dir)
        guard case let .success(file) = ChatFileRules.inspect(url, home: home) else { Issue.record("検査に失敗"); return }
        #expect(file.isText)
    }

    @Test func foldersEmptyFilesAndOversizedFilesAreRefusedWithAReason() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = try write("empty.txt", Data(), in: dir)
        #expect(ChatFileRules.inspect(dir, home: home) == .failure(.notAFile(dir.lastPathComponent)))
        #expect(ChatFileRules.inspect(empty, home: home) == .failure(.empty("empty.txt")))
        #expect(ChatFileRules.inspect(dir.appendingPathComponent("missing.txt"), home: home) == .failure(.notAFile("missing.txt")))
        #expect(!Refusal_description(.tooLarge("x", ChatFileRules.maxBytes + 1)).isEmpty)
        let env = try write(".env", Data("API_KEY=sample".utf8), in: dir)
        #expect(ChatFileRules.inspect(env, home: home) == .failure(.secret(".env")))     // 作り物の中身でも、名前で断る
    }

    @Test func aSymlinkToASecretIsRefusedByItsTarget() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let secret = try write(".ssh/id_ed25519", Data("not a real key".utf8), in: dir)
        let link = dir.appendingPathComponent("harmless.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(ChatFileRules.inspect(link, home: home) == .failure(.secret("harmless.txt")))
    }

    @Test func addingSkipsDuplicatesStopsAtTheMaximumAndReportsWhatWasRefused() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try (0..<7).map { try write("f\($0).txt", Data("x\($0)".utf8), in: dir) }
        let first = ChatFileRules.add([urls[0], urls[0], urls[1]], to: [], home: home)
        #expect(first.files.count == 2 && first.refusals.isEmpty)                            // 同じファイルは、重ねない
        let more = ChatFileRules.add(Array(urls[2...]), to: first.files, home: home)
        #expect(more.files.count == ChatFileRules.maxFiles && more.refusals == [.tooMany])   // 上限で止まる
        let env = try write(".env", Data("k=v".utf8), in: dir)
        let mixed = ChatFileRules.add([env, urls[0]], to: [], home: home)
        #expect(mixed.files.map(\.name) == ["f0.txt"] && mixed.refusals == [.secret(".env")]) // 断ったものがあっても、残りは、添える
    }

    private func Refusal_description(_ refusal: ChatFileRules.Refusal) -> String { refusal.description }
}
