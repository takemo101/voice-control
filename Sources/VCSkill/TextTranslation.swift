import AppKit
import Foundation
import NaturalLanguage
import Translation

/// コピーした文章の、オンデバイス翻訳（Apple の Translation フレームワーク。**この Mac の中だけ**で動く。言語モデルを通さない：速く、足したり落としたりしない）。
/// `vc translate` が使う（SPEC F52。実験）。翻訳先の言葉は、**コードが依頼の文から決める**（言語モデルは、選ばない）。
public enum TextTranslation {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
    }

    /// 言語（Translation フレームワークが扱う言語のうち、依頼で言える言語）。`words`：依頼に書かれる言い方。
    struct Language: Equatable {
        let code: String
        let name: String
        let words: [String]
    }

    static let languages: [Language] = [
        Language(code: "en", name: "英語", words: ["英語", "English", "英訳"]),
        Language(code: "ja", name: "日本語", words: ["日本語", "和訳"]),
        Language(code: "zh-Hant", name: "中国語（繁体字）", words: ["繁体字", "繁體"]),
        Language(code: "zh-Hans", name: "中国語（簡体字）", words: ["簡体字", "中国語", "中文"]),
        Language(code: "ko", name: "韓国語", words: ["韓国語", "韓国", "ハングル"]),
        Language(code: "fr", name: "フランス語", words: ["フランス語"]),
        Language(code: "de", name: "ドイツ語", words: ["ドイツ語"]),
        Language(code: "es", name: "スペイン語", words: ["スペイン語"]),
        Language(code: "it", name: "イタリア語", words: ["イタリア語"]),
        Language(code: "pt", name: "ポルトガル語", words: ["ポルトガル語"]),
        Language(code: "ru", name: "ロシア語", words: ["ロシア語"]),
        Language(code: "ar", name: "アラビア語", words: ["アラビア語"]),
        Language(code: "hi", name: "ヒンディー語", words: ["ヒンディー語"]),
        Language(code: "id", name: "インドネシア語", words: ["インドネシア語"]),
        Language(code: "nl", name: "オランダ語", words: ["オランダ語"]),
        Language(code: "pl", name: "ポーランド語", words: ["ポーランド語"]),
        Language(code: "th", name: "タイ語", words: ["タイ語"]),
        Language(code: "tr", name: "トルコ語", words: ["トルコ語"]),
        Language(code: "uk", name: "ウクライナ語", words: ["ウクライナ語"]),
        Language(code: "vi", name: "ベトナム語", words: ["ベトナム語"]),
    ]

    /// 翻訳できる文字数の上限（長いと、時間がかかる）。
    static let maxCharacters = 20_000

    static func language(code: String) -> Language? { languages.first { $0.code == code } }

    /// 依頼の文に書かれた言語（出てくる順）。「から」が続く言語は、翻訳元として、別に返す。
    static func mentions(in request: String) -> (targets: [Language], sources: [Language]) {
        var found: [(position: Int, language: Language, word: String, isSource: Bool)] = []
        let text = request as NSString
        for language in languages {
            for word in language.words {
                var from = 0
                while from < text.length {
                    let range = text.range(of: word, options: .caseInsensitive, range: NSRange(location: from, length: text.length - from))
                    if range.location == NSNotFound { break }
                    let isSource = text.substring(from: range.location + range.length).hasPrefix("から")
                    found.append((range.location, language, word, isSource))
                    from = range.location + range.length
                }
            }
        }
        // 「繁体字の中国語」：字体が書かれていれば、ただの「中国語」「中文」は、数えない
        if found.contains(where: { $0.language.code == "zh-Hant" }) { found.removeAll { $0.language.code == "zh-Hans" && ["中国語", "中文"].contains($0.word) } }
        found.sort { $0.position < $1.position }
        return (found.filter { !$0.isSource }.map(\.language), found.filter(\.isSource).map(\.language))
    }

    /// 翻訳先と、翻訳元（コードが決める）。
    /// - 依頼に、言語が書かれていれば、**最後に書かれた言語**が、翻訳先（「英語から日本語に」→ 日本語。「から」の付いた言語は、翻訳元）。
    /// - なければ、文章が日本語なら英語へ、日本語以外なら日本語へ。
    /// - 翻訳元は、文章から判定する（依頼に「〇〇から」とあれば、それを優先）。
    static func plan(request: String, text: String) -> Swift.Result<(source: Language, target: Language), Failure> {
        let (targets, sources) = mentions(in: request)
        guard let detected = detect(text) else { return .failure(Failure(message: "文章の言語を判定できませんでした（短すぎる・記号だけ・対応していない言語）")) }
        let source = sources.first ?? detected
        let target = targets.last ?? (source.code == "ja" ? language(code: "en")! : language(code: "ja")!)
        guard source.code != target.code else { return .failure(Failure(message: "文章は、すでに\(target.name)です（別の言語を指定してください。例：「英語に翻訳して」）")) }
        return .success((source, target))
    }

    static func detect(_ text: String) -> Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let code = dominant.rawValue
        if let exact = language(code: code) { return exact }
        if code.hasPrefix("zh") { return language(code: "zh-Hans") }   // 中国語の字体が判定されないとき
        return languages.first { code.hasPrefix($0.code) }
    }

    /// 翻訳の結果。
    public struct Translated: Equatable {
        public let sourceName: String
        public let targetName: String
        public let text: String
    }

    /// 翻訳する（時間がかかる：呼ぶ側の、実行の流れの中で）。依頼の文から、翻訳先を決める。
    public static func translate(_ text: String, request: String) throws -> Translated {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(message: "コピーした文章がありません。翻訳したい文章をコピーしてから、頼んでください") }
        guard trimmed.count <= maxCharacters else { throw Failure(message: "文章が長すぎます（\(maxCharacters) 文字まで。いま \(trimmed.count) 文字）") }
        let (source, target) = try plan(request: request, text: trimmed).get()
        let translated = try blocking { try await run(trimmed, source: source, target: target) }
        return Translated(sourceName: source.name, targetName: target.name, text: translated)
    }

    /// 非同期の処理を、いまのスレッドで、待つ（実行の流れは、同期。専用のタスクで動かすので、呼ぶ側の（メインでない）スレッドを塞ぐだけ）。
    private final class Box<T: Sendable>: @unchecked Sendable { var value: Swift.Result<T, Error>? }
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>(); let done = DispatchSemaphore(value: 0)
        Task.detached { do { box.value = .success(try await work()) } catch { box.value = .failure(error) }; done.signal() }
        done.wait()
        return try box.value!.get()
    }

    private static func run(_ text: String, source: Language, target: Language) async throws -> String {
        let from = Locale.Language(identifier: source.code), to = Locale.Language(identifier: target.code)
        switch await LanguageAvailability().status(from: from, to: to) {
        case .installed: break
        case .supported:
            throw Failure(message: "\(source.name)→\(target.name)の翻訳に使う言語が、まだ、この Mac に入っていません。システム設定 > 一般 > 言語と地域 > 翻訳言語 で、\(source.name)と\(target.name)をダウンロードしてください")
        default:
            throw Failure(message: "\(source.name)→\(target.name)の翻訳には、対応していません")
        }
        // 行ごとに分けて、まとめて翻訳する（空行・段落は、そのまま）
        let lines = text.components(separatedBy: "\n")
        let requests = lines.enumerated().compactMap { index, line -> TranslationSession.Request? in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : TranslationSession.Request(sourceText: line, clientIdentifier: String(index))
        }
        let session = TranslationSession(installedSource: from, target: to)
        var translated: [Int: String] = [:]
        for response in try await session.translations(from: requests) {
            if let id = response.clientIdentifier, let index = Int(id) { translated[index] = response.targetText }
        }
        return lines.enumerated().map { translated[$0.offset] ?? $0.element }.joined(separator: "\n")
    }

    /// コピーした文章（クリップボードの文字）。なければ nil。
    public static func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }
}
