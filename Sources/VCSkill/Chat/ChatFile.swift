import Foundation
import VCCore

/// 会話に添える**ファイル**（ドラッグ＆ドロップ・ファイルを選ぶ・Finder でコピーして貼り付け）。外のエージェントにだけ渡せる（**中身が、この Mac の外へ出る**：送るたびに、確認する）。
public struct ChatFile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public var name: String { url.lastPathComponent }
    public let size: Int64
    /// 文字のファイル（UTF-8 で読めて、制御文字の 0 を含まない）か。
    public let isText: Bool

    public init(id: UUID = UUID(), url: URL, size: Int64, isText: Bool) { self.id = id; self.url = url; self.size = size; self.isText = isText }

    /// 画面に出す大きさ（「12 KB」）。
    public var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

/// ファイルを添えるときの**規則**（純粋に近い：ファイルの読み取りだけ。画面・外へ出す処理を持たない）。**外のエージェントへ渡す前の、コードの歯止め**：言語モデルに任せない。
/// - **秘密のファイルは、断る**（鍵・`.env`・`.ssh`・キーチェーン・このアプリのデータなど）。完全な保証ではない（名前と場所で見る）：中身までは、調べない。**送るたびの確認**が、最後の歯止め。
/// - 件数・大きさに上限。フォルダ・パッケージは、対象外。
/// - 渡し方：**小さい文字ファイルは、内容を埋め込む**（道具が要らない）。それ以外は、作業フォルダへコピーして**リンクで渡す**（エージェントが、読む道具で読む：道具が「＋読む」以上のときだけ）。
public enum ChatFileRules {
    public static let maxFiles = 5
    /// 1 件の上限（リンクで渡すもの）。
    public static let maxBytes: Int64 = 25_000_000
    /// 内容を埋め込む上限（文字ファイル）。
    public static let maxEmbedBytes: Int64 = 100_000

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case notAFile(String)
        case empty(String)
        case secret(String)
        case tooLarge(String, Int64)
        case unreadable(String)
        case tooMany

        public var description: String {
            switch self {
            case let .notAFile(name): return tr("「\(name)」は、ファイルではありません（フォルダ・アプリは、添えられません）")
            case let .empty(name): return tr("「\(name)」は、空です")
            case let .secret(name): return tr("「\(name)」は、鍵・認証情報・このアプリのデータの可能性があるので、添えられません")
            case let .tooLarge(name, size): return tr("「\(name)」は、大きすぎます（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))。上限は \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file))）")
            case let .unreadable(name): return tr("「\(name)」を、読めません")
            case .tooMany: return tr("添えられるファイルは、\(maxFiles) 件までです")
            }
        }
    }

    /// 渡し方：内容を埋め込む・作業フォルダへコピーしてリンク・（道具が足りず）渡せない。
    public enum Delivery: Equatable, Sendable { case embed, link, needsTools }

    public static func delivery(of file: ChatFile, tools: ChatToolLevel) -> Delivery {
        if file.isText, file.size <= maxEmbedBytes { return .embed }
        return tools.usesFolder ? .link : .needsTools
    }

    // MARK: 検査

    /// 添えてよいファイルか（`url` は、ファイルの URL）。シンボリックリンクは、実体を見る。
    public static func inspect(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result<ChatFile, Refusal> {
        let resolved = url.resolvingSymlinksInPath()
        let name = url.lastPathComponent
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .fileSizeKey]), values.isRegularFile == true, values.isPackage != true else { return .failure(.notAFile(name)) }
        if isSecret(url, home: home) || isSecret(resolved, home: home) { return .failure(.secret(name)) }
        let size = Int64(values.fileSize ?? 0)
        if size == 0 { return .failure(.empty(name)) }
        if size > maxBytes { return .failure(.tooLarge(name, size)) }
        guard let isText = looksLikeText(resolved) else { return .failure(.unreadable(name)) }
        return .success(ChatFile(url: resolved, size: size, isText: isText))
    }

    /// 添えられるものを、現在の一覧に足す（同じファイルは、重ねない。上限まで）。足せたものと、断った理由。
    public static func add(_ urls: [URL], to current: [ChatFile], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (files: [ChatFile], refusals: [Refusal]) {
        var files = current
        var refusals: [Refusal] = []
        for url in urls where url.isFileURL {
            if files.contains(where: { $0.url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path }) { continue }
            if files.count >= maxFiles { refusals.append(.tooMany); break }
            switch inspect(url, home: home) {
            case let .success(file): files.append(file)
            case let .failure(refusal): refusals.append(refusal)
            }
        }
        return (files, refusals)
    }

    // MARK: 秘密の判定（名前と場所）

    private static let secretFolders: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".docker", ".voice-control", "keychains", ".password-store", ".config/gcloud", ".azure"]
    private static let secretNames: Set<String> = [".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", "credentials", "credentials.json", "secrets.json", "service-account.json", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "known_hosts", "authorized_keys"]
    private static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keychain", "keychain-db", "kdbx", "ppk", "p8", "jks", "keystore"]

    /// 名前・場所が、鍵・認証情報・このアプリのデータらしいか。
    public static func isSecret(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        let components = path.split(separator: "/").map(String.init)
        let name = components.last ?? ""
        if secretNames.contains(name) || name == ".env" || name.hasPrefix(".env.") { return true }
        if name.hasPrefix("id_") && !name.hasSuffix(".pub") { return true }
        if let dot = name.lastIndex(of: "."), secretExtensions.contains(String(name[name.index(after: dot)...])) { return true }
        let folders = Set(components.dropLast())
        if !secretFolders.filter({ !$0.contains("/") }).isDisjoint(with: folders) { return true }
        if path.contains("/.config/gcloud/") || path.contains("/library/cookies/") { return true }
        return false
    }

    // MARK: 文字ファイルの判定

    /// 先頭の 8 KB で、文字ファイルか見る（0 を含まず、UTF-8 で読める）。読めなければ nil。
    static func looksLikeText(_ url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192) else { return nil }
        if head.contains(0) { return false }
        // 8 KB の切れ目で、文字の途中が切れていても、読める（末尾の 3 バイトまで、落として試す）
        for drop in 0...3 where head.count > drop {
            if String(data: head.dropLast(drop), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// 埋め込む内容（文字ファイル）。読めなければ nil。
    public static func embeddedText(of file: ChatFile) -> String? {
        guard file.isText, file.size <= maxEmbedBytes, let data = try? Data(contentsOf: file.url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 会話の記録（要約・履歴）に残す短い印：中身は、入れない。
    public static func memo(_ files: [ChatFile]) -> String { files.map { "\($0.name)（\($0.sizeText)）" }.joined(separator: "、") }
}
