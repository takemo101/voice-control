import Foundation

/// アプリの言語。**表示言語**（設定ウィンドウとダイアログ。設定 `uiLanguage`）と、**音声認識の言語**（設定 `sttLanguage`。`SpeechLanguage`）の、どちらにも使う。どちらも、なければ日本語（これまでの動作）。
/// **言語を足す**：ここに case を足す → `LanguageProfile.swift`（言語ごとのデータ）と、翻訳の表の登録（`L10nTables`）が、コンパイルで、足りないと言ってくる（`switch` は、全部の case が要る）。手順は `docs/development.md` の「言語を足す」。
public enum AppLanguage: String, CaseIterable, Sendable, Hashable {
    case ja, en

    /// 画面に出す名前（その言語の名前：翻訳しない）。
    public var displayName: String { profile.displayName }
    /// Apple の `Locale`（`SpeechTranscriber`・日付の書式）の識別子。
    public var bcp47: String { profile.bcp47 }
    /// transcribe.cpp（Whisper）に渡す言語の符号。
    public var whisperCode: String { profile.whisperCode }
    /// モデルへの指示に書く、言語の名前（「Answer in …」）。
    public var englishName: String { profile.englishName }

    /// 設定の書き方（`ja`・`en`…）から。知らない書き方は nil（呼ぶ側が、日本語に戻すか、理由を示す）。
    public static func parse(_ text: String?) -> AppLanguage? {
        guard let text else { return nil }
        return AppLanguage(rawValue: text.lowercased())
    }

    /// 設定に書く文字（日本語は、書かない：なければ日本語）。
    public static var codes: String { allCases.map(\.rawValue).joined(separator: "・") }
}

/// 音声認識の言語（設定 `sttLanguage`）：登録した言語のどれか・**自動**。
/// 自動は、**ダウンロードしたモデル（Whisper）だけ**が、音声から言語を判定できる（Apple の `SpeechTranscriber` は、言語を決めて始めるので、不可）。
/// Apple のときの自動は、**Mac の言語**（登録した言語なら、その言語。なければ英語）で認識する（`resolved`）。
public enum SpeechLanguage: Sendable, Hashable, CaseIterable {
    case fixed(AppLanguage)
    case auto

    public static let ja = SpeechLanguage.fixed(.ja)
    public static let en = SpeechLanguage.fixed(.en)
    /// 選択肢の並び：登録した言語、続けて、自動。
    public static var allCases: [SpeechLanguage] { AppLanguage.allCases.map { .fixed($0) } + [.auto] }

    /// 設定の書き方（`ja`・`en`…・`auto`）。
    public var rawValue: String {
        switch self {
        case let .fixed(language): return language.rawValue
        case .auto: return "auto"
        }
    }

    /// 画面に出す名前（言語の名前は、その言語のもの：翻訳しない。自動は、呼ぶ側が翻訳する）。
    public var displayName: String? {
        if case let .fixed(language) = self { return language.displayName }
        return nil
    }
    public var isAuto: Bool { self == .auto }

    /// 言語を決めて始める認識（Apple）・録音中の文字・声の見つけ方に使う言語。自動は、Mac の言語。
    public var resolved: AppLanguage { resolved(systemLanguages: Locale.preferredLanguages) }
    public func resolved(systemLanguages: [String]) -> AppLanguage {
        switch self {
        case let .fixed(language): return language
        case .auto:
            // Mac の言語の、最初のもの（`ja-JP`・`fr-FR`…）が、登録した言語なら、その言語。なければ、英語
            let first = (systemLanguages.first ?? "").lowercased()
            return AppLanguage.allCases.first { first == $0.rawValue || first.hasPrefix($0.rawValue + "-") } ?? .en
        }
    }

    /// transcribe.cpp（Whisper）へ渡す言語の符号。自動は nil（モデルが、音声から判定する）。
    public var whisperCode: String? {
        if case let .fixed(language) = self { return language.whisperCode }
        return nil
    }

    public static func parse(_ text: String?) -> SpeechLanguage? {
        guard let text else { return nil }
        let lowered = text.lowercased()
        if lowered == "auto" { return .auto }
        return AppLanguage(rawValue: lowered).map { .fixed($0) }
    }
}

/// 表示言語の切り替えと、翻訳の表（言語ごと）。**表は、日本語の文（鍵）→ その言語の文**。表にない文は、**英語の表**を引き、それにもなければ、日本語のまま出す（欠けても、読める）。
/// 翻訳する場所は、`tr`。**画面の言葉すべて**（設定ウィンドウ・ダイアログ・メニュー・上のパネル・画像・会話・Markdown のウィンドウ・端末の `vc`）。モデルへの指示・照合の語・開発用のコマンドは、翻訳しない（`// l10n-skip`）。
/// `@unchecked Sendable` の理由：可変な状態（`language`・`english`）は、すべて `lock` で守る。
public final class L10n: @unchecked Sendable {
    public static let shared = L10n()
    private let lock = NSLock()
    private var current = AppLanguage.ja
    private var answering: AppLanguage? = .ja   // nil：自動（利用者の言語で答えさせる）
    private var tables: [AppLanguage: [String: String]] = [:]

    /// いまの表示言語。
    public var language: AppLanguage { lock.withLock { current } }

    /// 表示言語を決める。nil（設定なし）は、日本語。
    public func use(_ language: AppLanguage?) { lock.withLock { current = language ?? .ja } }

    /// **答えの言語**（会話・スキルの結果・画像の説明を、モデルに書かせる言語）：認識する言語（設定 `sttLanguage`）。モデルへの指示の「Answer in …」に入る。
    public var answerLanguage: AppLanguage? { lock.withLock { answering } }
    /// 自動のときは、固定せず、「利用者の言語」で答えさせる。
    public func useAnswerLanguage(_ language: SpeechLanguage) { lock.withLock { answering = language == .auto ? nil : language.resolved } }

    /// モデルへの指示（英語）の「Japanese」を、答えの言語の名前にする（日本語なら、そのまま）。指示は、**呼び出すたびに**作る（言語は、設定で替わる）。
    public func inAnswerLanguage(_ prompt: String) -> String {
        guard let language = answerLanguage else { return prompt.replacingOccurrences(of: "Japanese", with: "the user's language") }
        return language == .ja ? prompt : prompt.replacingOccurrences(of: "Japanese", with: language.englishName)
    }

    /// ある言語の表を足す（同じ鍵は、あとのものが勝つ）。アプリの起動で、1 回。日本語は、鍵そのもの：表は、要らない。
    public func install(_ table: [String: String], for language: AppLanguage) {
        lock.withLock { tables[language, default: [:]].merge(table) { _, new in new } }
    }

    /// 翻訳。日本語は、鍵のまま。それ以外は、**その言語の表 → 英語の表 → 鍵（日本語）**の順に引く（値が空の項目は、未訳：次へ）。`args` は、`%@`（または `%1$@`）に、順に入れる。
    public func translate(_ key: String, args: [String]) -> String {
        let (language, snapshot) = lock.withLock { (current, tables) }
        let text = language == .ja ? key : Self.lookup(key, in: language, tables: snapshot)
        return Self.fill(text, args)
    }

    static func lookup(_ key: String, in language: AppLanguage, tables: [AppLanguage: [String: String]]) -> String {
        for candidate in [language, .en] {
            if let value = tables[candidate]?[key], !value.isEmpty { return value }
        }
        return key
    }

    /// その言語の表に、訳があるか（検査用。空の値は、未訳）。
    public func hasTranslation(_ key: String, for language: AppLanguage) -> Bool {
        lock.withLock { !(tables[language]?[key] ?? "").isEmpty }
    }

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
