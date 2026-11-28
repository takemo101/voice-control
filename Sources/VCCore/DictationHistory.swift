import Foundation

/// 音声入力の**履歴**の 1 件（入力した文字と、時刻）。
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    /// 文字の出どころ：`others`＝システム音声の文字起こし（F80。相手の音声）・`me`＝同じ文字起こしの、自分のマイク（設定 `transcribeMic`）。音声入力（キーを押して話す）の履歴は、なし（nil）。
    public enum Source: String, Codable, Sendable { case others, me }

    public let id: UUID
    public let date: Date
    public let text: String
    /// 文字の出どころ（音声入力は、nil。古い履歴にも、ない）。
    public let source: Source?
    /// 整理（F79）する前の、元の文字（整理しなかった・整理が通らなかったときは、nil）。
    public let raw: String?
    public init(id: UUID = UUID(), date: Date, text: String, source: Source? = nil, raw: String? = nil) { self.id = id; self.date = date; self.text = text; self.source = source; self.raw = raw }
}

/// 音声入力の履歴の、ファイル（`~/.voice-control/history.jsonl`：1 行に 1 件の JSON）。**設定 `history` がオンのときだけ、書く**（既定オフ）。
/// - **自分だけが読める**（ファイル 0600・フォルダ 0700）。残すのは、**入力した文字と時刻だけ**（アプリの名前・画面の内容・音声は、残さない）。
/// - **古いものは、消える**（残す日数：設定 `historyDays`。既定 7）。件数にも上限がある（`maxEntries`）。
/// - 利用者が、1 件ずつ・すべて、消せる。壊れた行は、読み飛ばす（ほかの履歴を、巻き込まない）。
/// `@unchecked Sendable` の理由：ファイルの読み書きは、すべて `lock` の下。
public final class DictationHistory: @unchecked Sendable {
    public static let maxEntries = 2000
    public static let defaultDays = 7
    public static let dayRange = 1...365

    private let file: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(file: URL = VoiceControlHome.historyFile, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file; self.now = now
    }

    /// 残す日数（設定の値を、範囲に収める）。
    public static func days(setting: Int?) -> Int { min(max(setting ?? defaultDays, dayRange.lowerBound), dayRange.upperBound) }

    /// 新しい順の、すべて（`query` があれば、文字に含むものだけ。大文字・小文字は区別しない）。
    public func entries(matching query: String? = nil) -> [HistoryEntry] {
        lock.withLock {
            let all = load().sorted { $0.date > $1.date }
            guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
            return all.filter { $0.text.range(of: query.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// 1 件、足す。足すときに、古いもの（`days` 日より前）と、上限を超えたものを、消す。
    @discardableResult
    public func append(_ text: String, days: Int, source: HistoryEntry.Source? = nil, raw: String? = nil, date: Date? = nil) throws -> HistoryEntry {
        let entry = HistoryEntry(date: date ?? now(), text: text, source: source, raw: raw)
        try lock.withLock {
            var all = load()
            all.append(entry)
            try save(pruned(all, days: days))
        }
        return entry
    }

    /// 古いものを、消す（履歴を開いたとき・日数を縮めたとき）。
    public func prune(days: Int) throws {
        try lock.withLock { try save(pruned(load(), days: days)) }
    }

    public func delete(id: UUID) throws {
        try lock.withLock { try save(load().filter { $0.id != id }) }
    }

    /// すべて消す（ファイルごと）。
    public func clear() throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: 中身

    private func pruned(_ entries: [HistoryEntry], days: Int) -> [HistoryEntry] {
        let limit = now().addingTimeInterval(-Double(Self.days(setting: days)) * 86_400)
        let kept = entries.filter { $0.date >= limit }.sorted { $0.date < $1.date }
        return kept.count > Self.maxEntries ? Array(kept.suffix(Self.maxEntries)) : kept
    }

    private func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }   // try?: ファイルがなければ、履歴は、空
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0)) }   // try?: 壊れた行は、読み飛ばす
    }

    private func save(_ entries: [HistoryEntry]) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for entry in entries { data.append(try encoder.encode(entry)); data.append(UInt8(ascii: "\n")) }
        // 自分だけが読める：権限を決めてから、置き換える（途中で、ほかの人に読める時間を、作らない）
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw HistoryError.cannotWrite }
        if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) } else { try FileManager.default.moveItem(at: temporary, to: file) }
    }

    public enum HistoryError: Error, CustomStringConvertible {
        case cannotWrite
        public var description: String { tr("履歴を書けません") }
    }
}

/// **直近の入力**（メモリだけ。履歴がオフでも、持つ：直前の入力の貼り直し・直近の入力のコピーに使う）。アプリを終えると、消える。
/// `@unchecked Sendable` の理由：`items` は、すべて `lock` の下。
public final class RecentDictations: @unchecked Sendable {
    public static let shared = RecentDictations()
    public static let capacity = 5
    private let lock = NSLock()
    private var items: [String] = []

    public init() {}

    /// 新しい順。
    public var recent: [String] { lock.withLock { items } }
    public var last: String? { lock.withLock { items.first } }

    public func add(_ text: String) {
        guard !text.isEmpty else { return }
        lock.withLock {
            items.removeAll { $0 == text }
            items.insert(text, at: 0)
            if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        }
    }

    public func clear() { lock.withLock { items.removeAll() } }
}
