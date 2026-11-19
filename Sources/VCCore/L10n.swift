import Foundation

/// アプリの言語（日本語・英語）。**表示言語**（設定ウィンドウとダイアログ。設定 `uiLanguage`）と、**音声認識の言語**（設定 `sttLanguage`）に使う。
/// どちらも、なければ日本語（これまでの動作）。
public enum AppLanguage: String, CaseIterable, Sendable, Equatable {
    case ja, en

    /// 画面に出す名前（その言語の名前：翻訳しない）。
    public var displayName: String { self == .ja ? "日本語" : "English" }
    /// Apple の `Locale`（`SpeechTranscriber`）の識別子。
    public var bcp47: String { self == .ja ? "ja-JP" : "en-US" }
    /// transcribe.cpp（Whisper）に渡す言語の符号。
    public var whisperCode: String { rawValue }
    /// モデルへの指示に書く、言語の名前（「Answer in …」）。
    public var englishName: String { self == .ja ? "Japanese" : "English" }

    /// 設定の書き方（`ja`・`en`）から。知らない書き方は nil（呼ぶ側が、日本語に戻すか、理由を示す）。
    public static func parse(_ text: String?) -> AppLanguage? {
        guard let text else { return nil }
        return AppLanguage(rawValue: text.lowercased())
    }
}

/// 表示言語の切り替えと、翻訳の表（英語）。**表は、日本語の文（鍵）→ 英語の文**。表にない文は、日本語のまま出す（欠けても、読める）。
/// 翻訳する場所は、`tr`。**画面の言葉すべて**（設定ウィンドウ・ダイアログ・メニュー・上のパネル・画像・会話・Markdown のウィンドウ・端末の `vc`）。モデルへの指示・照合の語・開発用のコマンドは、翻訳しない（`// l10n-skip`）。
/// `@unchecked Sendable` の理由：可変な状態（`language`・`english`）は、すべて `lock` で守る。
public final class L10n: @unchecked Sendable {
    public static let shared = L10n()
    private let lock = NSLock()
    private var current = AppLanguage.ja
    private var answering = AppLanguage.ja
    private var english: [String: String] = [:]

    /// いまの表示言語。
    public var language: AppLanguage { lock.withLock { current } }

    /// 表示言語を決める。nil（設定なし）は、日本語。
    public func use(_ language: AppLanguage?) { lock.withLock { current = language ?? .ja } }

    /// **答えの言語**（会話・スキルの結果・画像の説明を、モデルに書かせる言語）：認識する言語（設定 `sttLanguage`）。モデルへの指示の「Answer in …」に入る。
    public var answerLanguage: AppLanguage { lock.withLock { answering } }
    public func useAnswerLanguage(_ language: AppLanguage) { lock.withLock { answering = language } }

    /// モデルへの指示（英語）の「Japanese」を、答えの言語の名前にする（日本語なら、そのまま）。指示は、**呼び出すたびに**作る（言語は、設定で替わる）。
    public func inAnswerLanguage(_ prompt: String) -> String {
        let language = answerLanguage
        return language == .ja ? prompt : prompt.replacingOccurrences(of: "Japanese", with: language.englishName)
    }

    /// 英語の表を足す（同じ鍵は、あとのものが勝つ）。アプリの起動で、1 回。
    public func install(english table: [String: String]) { lock.withLock { english.merge(table) { _, new in new } } }

    /// 翻訳。**英語のとき、表にあれば、英語**。`args` は、`%@`（または `%1$@`）に、順に入れる。
    public func translate(_ key: String, args: [String]) -> String {
        let (language, table) = lock.withLock { (current, english) }
        let text = language == .en ? (table[key] ?? key) : key
        return Self.fill(text, args)
    }

    /// 翻訳の表にあるか（検査用）。
    public func hasEnglish(_ key: String) -> Bool { lock.withLock { english[key] != nil } }

    /// `%@`（順に）・`%1$@`（番号で）に、`args` を入れる。足りない番号は、そのまま残す。
    static func fill(_ text: String, _ args: [String]) -> String {
        guard !args.isEmpty, text.contains("%") else { return text }
        var out = ""
        var next = 0
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("%@"), next < args.count { out += args[next]; next += 1; index = text.index(index, offsetBy: 2); continue }
            if rest.hasPrefix("%"), let match = rest.range(of: #"^%(\d+)\$@"#, options: .regularExpression),
               let n = Int(rest[match].dropFirst().prefix { $0.isNumber }), n >= 1, n <= args.count {
                out += args[n - 1]; index = match.upperBound; continue
            }
            out.append(text[index]); index = text.index(after: index)
        }
        return out
    }
}

/// 翻訳の鍵：**日本語の文**（補間つき）。`tr("…\(x)…")` と書くと、補間は `%@` になり、表の鍵と同じ形になる。
public struct L10nKey: ExpressibleByStringInterpolation, Sendable {
    public let key: String
    public let args: [String]

    public init(stringLiteral value: String) { key = value; args = [] }
    public init(stringInterpolation: Interpolation) { key = stringInterpolation.key; args = stringInterpolation.args }

    public struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) { key += "%@"; args.append(String(describing: value)) }
    }
}

/// 表示言語に合わせた文（日本語の文を渡す。英語のときは、表の英語）。
public func tr(_ text: L10nKey) -> String { L10n.shared.translate(text.key, args: text.args) }

/// **実行時に決まる文**（組み込みのデータの説明など）を、そのまま鍵にして引く。コードに文が書けないとき（`tr("…")` が使えないとき）だけ。表の行には、`// l10n-dynamic` を付ける（使われない鍵として、報告されない）。
public func tr(verbatim text: String) -> String { L10n.shared.translate(text, args: []) }
