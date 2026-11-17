import CryptoKit
import Foundation
import VCCore

/// 更新の、取得と検証（通信・ディスクイメージ・署名の確認）。入れ替えは `UpdateSwap`。
/// **利用者のデータは、送らない**：GitHub の公開情報（最新の Release）と、その添付（dmg・SHA-256）を、取りに行くだけ（`User-Agent` に、アプリの名前と版）。
/// **隔離の印（quarantine）は、付かない**：ブラウザではなく、このアプリが取るので、Gatekeeper の「開けません」の警告が、更新では出ない（初回の導入だけは、従来どおり）。
enum UpdatePipeline {
    /// 署名の識別（bundle ID と、指定要件）。新しい版が、いまの版と、**同じアプリ**であることの確認に使う（許可〔マイク・アクセシビリティ〕が、同じ要件に結びつく）。
    struct Identity: Equatable {
        let bundleID: String
        let requirement: String
    }

    enum Failure: Error, CustomStringConvertible {
        case network(String)
        case badResponse(Int)
        case release(ReleaseFeed.Problem)
        case checksumMissing
        case checksumMismatch
        case mount(String)
        case content(String)
        case signature(String)
        case notSameApp(String)

        var description: String {
            switch self {
            case let .network(why): return "通信できませんでした（\(why)）"
            case let .badResponse(code): return "GitHub が、エラーを返しました（\(code)）"
            case let .release(problem): return problem.description
            case .checksumMissing: return "SHA-256 の照合用の値を、読めませんでした"
            case .checksumMismatch: return "ダウンロードしたファイルの SHA-256 が、一致しません。入れません"
            case let .mount(why): return "ディスクイメージを開けませんでした（\(why)）"
            case let .content(why): return "配布物の中身が、想定と違います（\(why)）"
            case let .signature(why): return "署名の検査に通りませんでした（\(why)）"
            case let .notSameApp(why): return "いまのアプリと、同じアプリではありません（\(why)）。入れません"
            }
        }
    }

    // MARK: 最新の版を調べる

    static func latest(session: URLSession = .shared, currentVersion: String = AppInfo.version) async throws -> ReleaseInfo {
        var request = URLRequest(url: ReleaseFeed.latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("voice-control/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw Failure.network("応答がありません") }
        guard http.statusCode == 200 else { throw Failure.badResponse(http.statusCode) }
        guard data.count <= 2_000_000 else { throw Failure.release(.notRelease) }
        switch ReleaseFeed.parse(data) {
        case let .success(info): return info
        case let .failure(problem): throw Failure.release(problem)
        }
    }

    // MARK: 取得・照合・検証・置き場

    /// 新しい版を、`stagedPath`（入れ替え先と同じフォルダの中）に、置く。**ここでは、いまのアプリは、触らない**。
    /// 順に：SHA-256 の値を取る → dmg を取る → SHA-256 を照合 → ディスクイメージを開く → アプリを写す → 閉じる → 署名・bundle ID・版・指定要件を確かめる。どれかが違えば、置かずに、理由を投げる。
    static func prepare(_ release: ReleaseInfo, current: Identity, stagedPath: String, session: URLSession = .shared, progress: @escaping @Sendable (Double) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("voice-control-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let expected = try await expectedHash(for: release, session: session)
        let dmg = work.appendingPathComponent(release.dmgName)
        try await download(release.dmgURL, to: dmg, session: session, progress: progress)
        guard try sha256(of: dmg) == expected else { throw Failure.checksumMismatch }

        let mountPoint = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let attach = await run("hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-mountpoint", mountPoint.path, dmg.path], timeout: 120)
        guard attach.exitCode == 0 else { throw Failure.mount(attach.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        defer { _ = ProcessRunner.run(executable: "hdiutil", arguments: ["detach", "-force", mountPoint.path], mergeStderr: true, timeout: 60) }

        let source = mountPoint.appendingPathComponent("VoiceControl.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.content("VoiceControl.app がありません") }
        try? FileManager.default.removeItem(atPath: stagedPath)
        let copy = await run("ditto", [source.path, stagedPath], timeout: 120)
        guard copy.exitCode == 0 else { throw Failure.content("写せませんでした：\(copy.text)") }
        do { try await verify(stagedPath, release: release, current: current) } catch { try? FileManager.default.removeItem(atPath: stagedPath); throw error }
        _ = ProcessRunner.run(executable: "xattr", arguments: ["-cr", stagedPath], mergeStderr: true, timeout: 30)   // 隔離などの印を、残さない
    }

    /// 置いた新しい版が、いまのアプリと同じアプリで、想定の版で、署名が整っているか。
    static func verify(_ appPath: String, release: ReleaseInfo, current: Identity) async throws {
        guard let info = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") else { throw Failure.content("Info.plist を読めません") }
        guard FileManager.default.isExecutableFile(atPath: appPath + "/Contents/MacOS/vc") else { throw Failure.content("実行ファイルがありません") }
        guard info["CFBundleIdentifier"] as? String == current.bundleID else { throw Failure.notSameApp("bundle ID が違います") }
        guard let shown = info["CFBundleShortVersionString"] as? String, AppVersion(shown) == release.version else { throw Failure.content("版が、タグ（\(release.tag)）と違います") }
        let check = await run("codesign", ["--verify", "--deep", "--strict", appPath], timeout: 60)
        guard check.exitCode == 0 else { throw Failure.signature(check.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let requirement = await requirement(of: appPath) else { throw Failure.signature("指定要件を読めません") }
        guard requirement == current.requirement else { throw Failure.notSameApp("署名の指定要件が違います") }
    }

    /// 署名の識別（いま動いているアプリのもの。`.app` でなければ、nil）。
    static func identity(ofAppAt appPath: String) async -> Identity? {
        guard let info = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist"), let id = info["CFBundleIdentifier"] as? String, let requirement = await requirement(of: appPath) else { return nil }
        return Identity(bundleID: id, requirement: requirement)
    }

    /// `designated => …` の行（`codesign -d -r-`。出力は、標準エラー）。
    static func requirement(of appPath: String) async -> String? {
        let result = await run("codesign", ["-d", "-r-", appPath], timeout: 30)
        return result.text.split(whereSeparator: \.isNewline).map(String.init).first { $0.hasPrefix("designated =>") }
    }

    // MARK: 部品

    private static func expectedHash(for release: ReleaseInfo, session: URLSession) async throws -> String {
        var request = URLRequest(url: release.checksumURL, timeoutInterval: 30)
        request.setValue("voice-control/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.network(error.localizedDescription) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_096, let hash = ChecksumFile.expectedHash(in: String(decoding: data, as: UTF8.self), for: release.dmgName) else { throw Failure.checksumMissing }
        return hash
    }

    private static func download(_ url: URL, to file: URL, session: URLSession, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("voice-control/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let delegate = ProgressDelegate(progress)
        let (temporary, response): (URL, URLResponse)
        do { (temporary, response) = try await session.download(for: request, delegate: delegate) } catch { throw Failure.network(error.localizedDescription) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    /// 進み具合を、受け取る（ダウンロード中）。
    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    /// ファイルの SHA-256（16 進・小文字）。1 MiB ずつ読む。
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 外のコマンド（ブロックするので、別のスレッドで）。
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        await Task.detached { ProcessRunner.run(executable: executable, arguments: arguments, mergeStderr: true, timeout: timeout) }.value
    }
}
