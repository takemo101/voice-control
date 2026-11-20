import Foundation

/// **言語ごとのデータ**（1 つの言語につき 1 か所）。**言語を足すときは、`AppLanguage` に case を足して、ここに、その言語の項目を書く**（`switch` は、すべての case を書かないと、コンパイルが通らない：書き忘れが、ビルドで分かる）。
/// 翻訳の表（画面の言葉）は、別（`Sources/vc/L10n/<言語>/`。足し方は `docs/development.md` の「言語を足す」）。
/// - 声の確認の「はい」・つなぎ言葉・「会話を終わる」の言い方は、**登録したすべての言語の語を、合わせて**使う（音声認識の言語が何でも、どの言語の「はい」も通る。従来の、日本語と英語の合わせ方と同じ）。
public struct LanguageProfile: Sendable {
    /// その言語での、その言語の名前（設定の選択肢に出す。翻訳しない）。
    public let displayName: String
    /// Apple の `Locale`（`SpeechTranscriber`・日付の書式）の識別子。
    public let bcp47: String
    /// transcribe.cpp（Whisper）に渡す言語の符号。
    public let whisperCode: String
    /// モデルへの指示に書く、言語の名前（「Answer in …」）。
    public let englishName: String
    /// NaturalLanguage の言語の符号（読み上げる文字の言語を決めるとき）。
    public let nlCode: String
    /// 文字が全角（漢字・かな・ハングルなど）で、端末の表の幅が、広く取れるか（`colWidth`）。
    public let usesWideGlyphs: Bool
    /// 実行してよい、という決まった言い方（小文字で書く。複数の語の言い方も、1 つの言い方）。「いいです」「大丈夫です」のように、断りの意味にもなる言い方は、入れない。
    public let affirmatives: [String]
    /// つなぎ言葉（「えーと」「um」など）の既定の辞書。ふつうの語でもある語は、入れない。
    public let fillers: [String]
    /// 「会話を終わる」の言い方（どこにあってもよい。空白・句読点を除いた文に、含まれるか）。
    public let chatEndPhrases: [String]
    /// 「忘れて」のように、**短い発話の全体のときだけ**、会話を終わりにする言い方（空白・句読点を除いた文と、まったく同じか）。
    public let chatForgetPhrases: [String]
}

extension AppLanguage {
    public var profile: LanguageProfile {
        switch self {
        case .ja:
            return LanguageProfile(
                displayName: "日本語", bcp47: "ja-JP", whisperCode: "ja", englishName: "Japanese", nlCode: "ja", usesWideGlyphs: true,
                affirmatives: ["はい", "ハイ", "ええ", "うん", "お願いします", "お願い", "おねがいします", "実行して", "実行してください", "やって", "やってください", "やってくれ", "いいよ", "いいですよ", "どうぞ", "ok", "オーケー", "オッケー", "了解", "了解です", "承知", "進めて", "進めてください", "続けて", "続けてください"],
                fillers: ["えーっと", "ええっと", "えーと", "えっと", "ええと", "あのー", "あのう", "そのー", "うーんと", "うーん", "んー", "えー"],
                chatEndPhrases: ["会話を終わ", "会話を終了", "会話をやめ", "会話をリセット", "会話をはじめから", "新しい会話", "会話リセット", "会話終了"],
                chatForgetPhrases: ["忘れて", "全部忘れて", "すべて忘れて", "ぜんぶ忘れて"])
        case .en:
            return LanguageProfile(
                displayName: "English", bcp47: "en-US", whisperCode: "en", englishName: "English", nlCode: "en", usesWideGlyphs: false,
                affirmatives: ["yes", "yeah", "yep", "yup", "sure", "okay", "please", "proceed", "continue", "confirm", "confirmed", "go ahead", "do it", "please do", "run it", "sounds good", "that works", "yes please", "yes go ahead"],
                fillers: ["uh", "um", "uhm", "umm", "uhh", "hmm", "erm"],
                chatEndPhrases: [],
                chatForgetPhrases: [])
        }
    }

    /// 登録したすべての言語の語を、合わせたもの（言語の順に）。
    public static var allAffirmatives: [String] { allCases.flatMap { $0.profile.affirmatives } }
    public static var allFillers: [String] { allCases.flatMap { $0.profile.fillers } }
    public static var allChatEndPhrases: [String] { allCases.flatMap { $0.profile.chatEndPhrases } }
    public static var allChatForgetPhrases: [String] { allCases.flatMap { $0.profile.chatForgetPhrases } }
}
