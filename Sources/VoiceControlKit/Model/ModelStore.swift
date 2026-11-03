import CryptoKit
import Foundation

/// 取得するモデルのファイル 1 つ（大きさと SHA-256 は、版を固定した値）。
public struct ModelFile: Sendable, Equatable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
    public init(name: String, bytes: Int64, sha256: String) { self.name = name; self.bytes = bytes; self.sha256 = sha256 }
}

/// 取得するモデル：どこから（版を固定した URL）、どのファイルを、どこへ。
public struct ModelSpec: Sendable, Equatable {
    public let name: String
    public let baseURL: URL
    public let files: [ModelFile]
    public init(name: String, baseURL: URL, files: [ModelFile]) { self.name = name; self.baseURL = baseURL; self.files = files }

    /// Tiny-Jev 0.6B。値は meeting-analyzer の `DecisionModelCatalog` と同じ（Hugging Face `lostargon/Tiny-Jev`・版 `62449fb`）。
    public static let tinyJev06 = ModelSpec(
        name: "tiny-jev-0.6b",
        baseURL: URL(string: "https://huggingface.co/lostargon/Tiny-Jev/resolve/62449fb3272d68fb8c8fe8a33082566643a76d0b")!,
        files: [
            ModelFile(name: "tokenizer.json", bytes: 11_422_832, sha256: "e3fccc77adda606e2a461ffd17ca5a55a5a75ac40a5aa0a91c5307fb31b1efac"),
            ModelFile(name: "model.safetensors", bytes: 1_191_594_564, sha256: "513411b17cb0eca54839ca3948b4353e7f65710723ffcde8d13e3cb04328633e"),
        ]
    )
}

public enum ModelStoreError: Error, CustomStringConvertible {
    case http(Int, String)
    case checksumMismatch(String)
    public var description: String {
        switch self {
        case let .http(status, file): return "\(file) の取得に失敗しました（HTTP \(status)）"
        case let .checksumMismatch(file): return "\(file) の SHA-256 が一致しません（壊れているか、版が違います。もう一度 vc model download）"
        }
    }
}

public struct DownloadProgress: Sendable {
    public let file: String
    public let received: Int64
    public let total: Int64
}

/// モデルの置き場所（`~/.voice-control/models/<name>`）・状態の確認・取得。
public enum ModelStore {
    public static func defaultDirectory(for spec: ModelSpec = .tinyJev06) -> URL {
        VoiceControlHome.root.appendingPathComponent("models").appendingPathComponent(spec.name)
    }

    public enum FileState: Equatable, Sendable { case missing, wrongSize(Int64), present }

    /// ファイルの有無と大きさ（SHA-256 は計算しない。速い確認）。
    public static func state(of file: ModelFile, in directory: URL) -> FileState {
        let path = directory.appendingPathComponent(file.name).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path), let size = attrs[.size] as? Int64 else { return .missing }
        return size == file.bytes ? .present : .wrongSize(size)
    }

    public static func isInstalled(_ spec: ModelSpec = .tinyJev06, in directory: URL) -> Bool {
        spec.files.allSatisfy { state(of: $0, in: directory) == .present }
    }

    /// SHA-256（8 MB ずつ読む。大きなファイルでも、メモリを使い切らない）。
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 取得済みで、SHA-256 まで一致するか。
    public static func verify(_ file: ModelFile, in directory: URL) -> Bool {
        guard state(of: file, in: directory) == .present else { return false }
        return (try? sha256(of: directory.appendingPathComponent(file.name))) == file.sha256
    }

    /// 取得する。一致するファイルは、飛ばす。途中のファイル（`.part`）があれば、続きから（サーバーが対応しなければ、最初から）。
    /// 通信の失敗は、続きから 5 回まで再試行する。最後に SHA-256 を検証して、合うものだけを正式な名前にする。
    public static func download(_ spec: ModelSpec = .tinyJev06, to directory: URL, force: Bool = false,
                                progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in spec.files {
            let final = directory.appendingPathComponent(file.name)
            if !force, verify(file, in: directory) {
                progress(DownloadProgress(file: file.name, received: file.bytes, total: file.bytes))
                continue
            }
            let part = directory.appendingPathComponent(file.name + ".part")
            if force { try? FileManager.default.removeItem(at: part) }
            var freshRetry = false
            while true {
                try await downloadWithRetry(url: spec.baseURL.appendingPathComponent(file.name), part: part, file: file, progress: progress)
                if (try? sha256(of: part)) == file.sha256 { break }
                try? FileManager.default.removeItem(at: part)
                // 続きから取った結果が壊れていたら、最初から 1 回だけやり直す。
                if freshRetry { throw ModelStoreError.checksumMismatch(file.name) }
                freshRetry = true
            }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
        }
    }

    private static func downloadWithRetry(url: URL, part: URL, file: ModelFile, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        var attempt = 0
        while true {
            do {
                let offset = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
                if offset == file.bytes { return }  // 前回、取り終えていた（検証は、呼び出し側）
                if offset > file.bytes { try? FileManager.default.removeItem(at: part) }
                try await ChunkDownload(url: url, part: part, name: file.name, expected: file.bytes, progress: progress).run()
                return
            } catch let error as ModelStoreError {
                throw error
            } catch {
                attempt += 1
                if attempt >= 5 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }
}

/// 1 ファイルを、`.part` に追記しながら取る（Range で続きから）。
private final class ChunkDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let part: URL
    private let name: String
    private let expected: Int64
    private let progress: @Sendable (DownloadProgress) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReported: Int64 = 0

    init(url: URL, part: URL, name: String, expected: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.url = url; self.part = part; self.name = name; self.expected = expected; self.progress = progress
    }

    func run() async throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let h = try FileHandle(forWritingTo: part)
        handle = h
        let offset = try h.seekToEnd()
        received = Int64(offset)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel(); try? h.close() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 206: break
            case 200: restartFromZero()  // 続きからに対応しない：最初から取り直す
            case 416: restartFromZero(); failure = URLError(.resourceUnavailable); completionHandler(.cancel); return  // 続きの位置が合わない：捨てて、再試行
            default: failure = ModelStoreError.http(http.statusCode, name); completionHandler(.cancel); return
            }
        } else {
            restartFromZero()  // file:// など
        }
        completionHandler(.allow)
    }

    private func restartFromZero() {
        try? handle?.truncate(atOffset: 0)
        try? handle?.seek(toOffset: 0)
        received = 0
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { failure = error; dataTask.cancel(); return }
        received += Int64(data.count)
        if received - lastReported >= 1 << 20 || received >= expected {
            lastReported = received
            progress(DownloadProgress(file: name, received: received, total: expected))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = failure ?? error
        if let result { continuation?.resume(throwing: result) } else {
            progress(DownloadProgress(file: name, received: received, total: expected))
            continuation?.resume()
        }
        continuation = nil
    }
}
