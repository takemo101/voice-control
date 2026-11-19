import Foundation
import VCCore

/// 更新の候補（GitHub Releases の最新版）：版・変更点のページ・dmg と SHA-256 の場所。
struct ReleaseInfo: Equatable {
    let version: AppVersion
    let tag: String
    /// 変更点のページ（利用者が、ブラウザで開く）。
    let pageURL: URL
    let dmgName: String
    let dmgURL: URL
    let checksumURL: URL
}

/// GitHub の `releases/latest`（JSON）を、更新の候補にする（**純粋**）。外から来る値（JSON・URL）は、ここで一度だけ検査する：
/// - 下書き・先行版は、候補にしない。タグが版として読めなければ、候補にしない。
/// - dmg は、`vc-<版>-macos-arm64.dmg` と、その `.sha256`（どちらも要る）。
/// - **取得先は、このリポジトリの Release の添付だけ**（`https://github.com/takemo101/voice-control/releases/download/…`）。ほかの場所は、断る。
enum ReleaseFeed {
    static let repository = "takemo101/voice-control"
    static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    enum Problem: Error, Equatable, CustomStringConvertible {
        case notRelease
        case draftOrPrerelease
        case badTag(String)
        case missingAsset(String)
        case foreignURL(String)

        var description: String {
            switch self {
            case .notRelease: return tr("更新の情報を読めませんでした")
            case .draftOrPrerelease: return tr("最新の公開版が、見つかりません")
            case let .badTag(tag): return tr("版を読めません（\(tag)）")
            case let .missingAsset(name): return tr("配布物が、見つかりません（\(name)）")
            case let .foreignURL(url): return tr("取得先が、このリポジトリの Release ではありません（\(url)）")
            }
        }
    }

    static func parse(_ data: Data) -> Result<ReleaseInfo, Problem> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = object["tag_name"] as? String else { return .failure(.notRelease) }
        if (object["draft"] as? Bool) == true || (object["prerelease"] as? Bool) == true { return .failure(.draftOrPrerelease) }
        guard let version = AppVersion(tag) else { return .failure(.badTag(tag)) }
        let dmgName = "vc-\(version)-macos-arm64.dmg"
        let assets = (object["assets"] as? [[String: Any]]) ?? []
        func url(of name: String) -> Result<URL, Problem> {
            guard let text = assets.first(where: { ($0["name"] as? String) == name })?["browser_download_url"] as? String else { return .failure(.missingAsset(name)) }
            guard let url = URL(string: text), isTrusted(url) else { return .failure(.foreignURL(text)) }
            return .success(url)
        }
        switch (url(of: dmgName), url(of: dmgName + ".sha256")) {
        case let (.success(dmg), .success(checksum)):
            let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repository)/releases")!
            return .success(ReleaseInfo(version: version, tag: tag, pageURL: page, dmgName: dmgName, dmgURL: dmg, checksumURL: checksum))
        case let (.failure(problem), _), let (_, .failure(problem)):
            return .failure(problem)
        }
    }

    /// このリポジトリの Release の添付か（https・github.com・パスの頭）。
    static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil
            && url.path.hasPrefix("/\(repository)/releases/download/") && !url.path.contains("..")
    }

    /// 更新の確認の間隔（秒）：起動時と、動いている間は、1 日ごと。
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// いま確認してよいか（前回から間隔が空いたか。前回がなければ、確認する）。
    static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= checkInterval
    }
}

/// `shasum -a 256` の形式（`<64 桁の 16 進>  <ファイル名>`）のファイルから、そのファイルの SHA-256 を取り出す（**純粋**）。
enum ChecksumFile {
    static func expectedHash(in text: String, for filename: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename else { continue }
            let hash = fields[0].lowercased()
            if hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) { return hash }
        }
        return nil
    }
}
