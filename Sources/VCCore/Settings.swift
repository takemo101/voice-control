import Foundation

/// 設定（`~/.voice-control/settings.json`）。**メニューバーのアプリの設定ウィンドウが、読み書きする**（手で編集してもよい）。
/// - `disabledSkills`：スキルの有効・無効。**既定は有効**（無効にしたものだけ、記録する）。
/// - `hotkey`：押している間だけ聞くトリガーの書き方（文字列。解釈は Speech 層）。なければ、`shift` の長押し。
/// - `dictateHotkey`：音声入力のトリガー。なければ、声で頼むトリガー（`hotkey`）と同じ。**設定すると、声の入力は、このトリガーで音声入力になる**（トリガーで切り替わる）。
/// - `shotHotkey`：スクリーンショットを撮るショートカット（設定ウィンドウ > キー）。なければ、ショートカットなし。
/// - `handsFree`：ダブルタップで、黙るまで録音する（手放し）か。なければ、する（設定ウィンドウ > キー で、押している間だけ）。
/// - `recheck`：聞き取りに自信がないとき（認識の確信度が低いとき）、実行の前に、聞こえた文を確かめるか。なければ、確かめる（設定ウィンドウ > 音声 で、確かめない。実験）。
/// - `speakResults`：実行の結果（「完了：〇〇」）を、声で読み上げるか。なければ、読み上げない（確認の問いかけは、いつも読み上げる）。設定ウィンドウ > 音声。
/// - `voice`：読み上げの声（識別子か名前）。なければ、入っている日本語の声のうち、品質がいちばん高いもの。設定ウィンドウ > 音声。
/// - `dictateEnter`：音声入力で、文字を入れたあと、**Enter を送る**か（メッセージの送信・コマンドの実行まで、自動で行う）。なければ、送らない（設定ウィンドウ > 音声）。送る前に、短い間があり、Esc で取りやめられる。
/// - `updateCheck`：新しい版の確認（GitHub の公開情報を、起動時と 1 日ごとに取りに行く。利用者のデータは、送らない）を、するか。なければ、する。見つけても、**入れるのは、利用者が選んだとき**だけ（設定ウィンドウ > 一般）。
/// - `chatAuto`：**自動モード**：会話の道具が「すべて」のとき、**作業フォルダの中の書き込みと、基本のコマンド・Tiny-Jev が無害と判定したコマンドを、確認なしで実行する**（ACP で話すエージェント。OS の制限が、効いているときだけ）。消す・外へ送る・システムを動かす・フォルダの外への書き込みは、確認か拒否のまま。なければ、オフ（設定ウィンドウ > 会話）。
/// - `chatModels`：会話のエージェントごとの、モデル（エージェント名 → モデルの値。ACP で話すもの）。なければ、エージェントの設定のまま。一覧は、エージェントが返す（設定ウィンドウ > 会話）。
/// - `fontSize`：画面の文字の大きさ（会話・Markdown のウィンドウ・上のパネル・画像の窓・拡大の窓）。標準は 13（なければ 13）・範囲は 10〜24。設定ウィンドウ > 一般 > 表示。
/// - `dictateKey`：`dictateEnter` で送るキー（書き方は、トリガーと同じ：`cmd+return`・`shift+return`・`tab`…。単独のキーも、よい）。なければ、Enter（`return`）。解釈は、Speech 層（`KeyStroke`）。
/// - `liveCaption`：録音中に聞こえている文字（途中経過）を、画面の上のパネルに出すか。なければ、出す（設定ウィンドウ > 音声 で、出さない。実験）。
/// - `chatHotkey`：会話のトリガー（設定ウィンドウ > キー）。なければ、会話はない。押している間だけ話し、離すと、**会話として**（スキルを選ばずに）質問する。
/// - `chatAgent`：会話に使うエージェント（設定ウィンドウ > 会話）。なければ、この Mac の Apple のモデル。`agy`・`claude`・`codex`・`grok`・`opencode`・`pi` を選ぶと、**会話の発話が、その提供元へ送られる**（`ask-agent` と同じ例外。利用者が選んだときだけ）。
/// - `chatTools`：会話に使う**外のエージェント**に、開ける道具の段階（`web`・`read`・`all`。なければ、会話だけ）。`all` は、ファイルの書き込み・コマンドの実行も。外へ出るのは、発話（と、道具で読んだものを、エージェントが答えに使う分）。Apple のモデルには、効かない。
/// - `chatAcp`：ACP に対応した会話のエージェント（`agy`・`opencode`）を、**常駐の接続（ACP）**で使うか。なければ、使う（設定ウィンドウ > 会話）。使えなければ、自動で、従来の方式（質問ごとに CLI を起動）に戻る。
/// - `chatSandbox`：ACP で話す会話のエージェント（`agy`・`opencode`）を、**OS の制限（macOS の Seatbelt）つき**で起動するか（書き込みを、作業フォルダ〔「すべて」のとき〕とエージェント自身の置き場だけに限る。鍵の置き場は、読めない）。なければ、使う（設定ウィンドウ > 会話）。
/// - `chatFolder`：道具を開けたとき（`read`・`all`）の、作業フォルダ。なければ、`~/.voice-control/chat`。
/// - `uiLanguage`：**表示言語**（`ja`・`en`。設定ウィンドウとダイアログ）。なければ、日本語。
/// - `sttLanguage`：**音声認識の言語**（`ja`・`en`・`auto`。`auto` は、ダウンロードしたモデルだけが音声から判定する：Apple は、Mac の言語）。録音の認識・録音中の文字・読み上げの声に効く。なければ、日本語。
/// - `history`：**音声入力の履歴**を、ファイル（`~/.voice-control/history.jsonl`。自分だけが読める）に残すか。**なければ、残さない**（既定オフ。SPEC F64。利用者の判断：2026-11-19）。`historyDays`：残す日数（なければ 7・1〜365）。
/// - `pasteLastHotkey`：**直前の入力を、もう一度、前面のアプリへ入れる**ショートカット（キーの組み合わせ。なければ、ショートカットなし。メニューからも、できる）。直前の入力は、メモリだけに持つ。
/// - `dictateKeys`：**音声入力のあとに送るキーの一覧**（利用者が、設定ウィンドウ > 音声入力 で、足し引きする。`cmd+return`・`shift+return`・`tab`…）。なければ、`dictateKey`（古い設定。さらになければ Enter）の 1 つ。`dictateMode`：いま使う候補（0＝送らない・1〜＝一覧の 1 番目から）。なければ、`dictateEnter` に従う（古い設定のまま）。`dictateCycleHotkey`：候補を、順に切り替えるショートカット（キーの組み合わせ。なければ、ショートカットなし。メニューからも、できる）。
/// - `smartSpacing`：英語の文字を、**単語のすぐあとに入れるとき、空白を 1 つ足す**か。なければ、足す（日本語には、働かない）。
/// - `stt`：使う音声認識（`apple`、またはダウンロードしたモデルの ID。解釈は Speech 層）。なければ、Apple の `SpeechTranscriber`。
/// - `mute`：録音中に、ほかの音（出力）を消すか。`true` が既定（なければ、消す）。`false` なら、流したまま。
/// - `removeFillers`：音声入力で、つなぎ言葉（「えーと」など）を消すか。なければ、消さない。
/// - `fillers`：消すつなぎ言葉の辞書（利用者が足し引きする）。なければ、既定の辞書（解釈は Speech 層）。
/// - `multiStep`：1 つの依頼を、複数のステップに分けて実行するか。なければ、分ける（設定ウィンドウ > モデル で、1 依頼 = 1 スキル）。
/// - `engine`：スキルを実行するモデル（`apple`・`ollama:<モデル>`・`openai:<モデル>@<ポート>`・LAN は `openai:<モデル>@<ホスト>:<ポート>`。解釈は Skill 層）。なければ、Apple。
/// - `engineRests`：エンジンの種類（`ollama`・`openai`）ごとの、**最後に使った入力**（`<モデル>@<場所>` の、`<モデル>@…` の部分）。種類を切り替えても、それぞれの設定が、残る。使うのは、`engine` だけ。
/// - `engineApproved`：LAN のサーバー（`ホスト:ポート`）へ、**音声・画面の内容を送ることを、利用者が許可した場所**（設定ウィンドウ > モデル）。`engine` の場所と違えば、使わない。
/// - **APIキーは、ここに置かない**（`EngineKeyStore`：自分だけが読める別のファイル）。
/// - `trustedProjects`：プロジェクトのスキル（`<ルート>/.voice-control/skills`）を読み込んでよいと、利用者が確認したプロジェクトのルート。**既定は、どれも信頼しない**。
public struct Settings: Codable, Sendable, Equatable {
    public var disabledSkills: [String] = []
    public var hotkey: String?
    public var dictateHotkey: String?
    public var chatHotkey: String?
    public var chatAgent: String?
    public var chatTools: String?
    public var chatFolder: String?
    public var chatAcp: Bool?
    public var chatSandbox: Bool?
    public var stt: String?
    public var history: Bool?
    public var historyDays: Int?
    public var pasteLastHotkey: String?
    public var dictateCycleHotkey: String?
    public var dictateKeys: [String]?
    public var dictateMode: Int?
    public var smartSpacing: Bool?
    public var uiLanguage: String?
    public var sttLanguage: String?
    public var shotHotkey: String?
    public var handsFree: Bool?
    public var recheck: Bool?
    public var speakResults: Bool?
    public var liveCaption: Bool?
    public var dictateEnter: Bool?
    public var dictateKey: String?
    public var updateCheck: Bool?
    public var fontSize: Int?
    public var chatModels: [String: String]?
    public var chatAuto: Bool?
    public var voice: String?
    public var mute: Bool?
    public var removeFillers: Bool?
    public var multiStep: Bool?
    public var fillers: [String]?
    public var engine: String?
    public var engineApproved: String?
    public var engineRests: [String: String]?
    public var trustedProjects: [String] = []

    public init() {}

    // 項目が足りない古いファイルも読めるように、すべて `decodeIfPresent`。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabledSkills = try c.decodeIfPresent([String].self, forKey: .disabledSkills) ?? []
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        dictateHotkey = try c.decodeIfPresent(String.self, forKey: .dictateHotkey)
        chatHotkey = try c.decodeIfPresent(String.self, forKey: .chatHotkey)
        chatAgent = try c.decodeIfPresent(String.self, forKey: .chatAgent)
        chatTools = try c.decodeIfPresent(String.self, forKey: .chatTools)
        chatFolder = try c.decodeIfPresent(String.self, forKey: .chatFolder)
        chatAcp = try c.decodeIfPresent(Bool.self, forKey: .chatAcp)
        chatSandbox = try c.decodeIfPresent(Bool.self, forKey: .chatSandbox)
        stt = try c.decodeIfPresent(String.self, forKey: .stt)
        history = try c.decodeIfPresent(Bool.self, forKey: .history)
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays)
        pasteLastHotkey = try c.decodeIfPresent(String.self, forKey: .pasteLastHotkey)
        dictateCycleHotkey = try c.decodeIfPresent(String.self, forKey: .dictateCycleHotkey)
        dictateKeys = try c.decodeIfPresent([String].self, forKey: .dictateKeys)
        dictateMode = try c.decodeIfPresent(Int.self, forKey: .dictateMode)
        smartSpacing = try c.decodeIfPresent(Bool.self, forKey: .smartSpacing)
        uiLanguage = try c.decodeIfPresent(String.self, forKey: .uiLanguage)
        sttLanguage = try c.decodeIfPresent(String.self, forKey: .sttLanguage)
        shotHotkey = try c.decodeIfPresent(String.self, forKey: .shotHotkey)
        handsFree = try c.decodeIfPresent(Bool.self, forKey: .handsFree)
        recheck = try c.decodeIfPresent(Bool.self, forKey: .recheck)
        speakResults = try c.decodeIfPresent(Bool.self, forKey: .speakResults)
        liveCaption = try c.decodeIfPresent(Bool.self, forKey: .liveCaption)
        dictateEnter = try c.decodeIfPresent(Bool.self, forKey: .dictateEnter)
        dictateKey = try c.decodeIfPresent(String.self, forKey: .dictateKey)
        updateCheck = try c.decodeIfPresent(Bool.self, forKey: .updateCheck)
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize)
        chatModels = try c.decodeIfPresent([String: String].self, forKey: .chatModels)
        chatAuto = try c.decodeIfPresent(Bool.self, forKey: .chatAuto)
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute)
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers)
        multiStep = try c.decodeIfPresent(Bool.self, forKey: .multiStep)
        fillers = try c.decodeIfPresent([String].self, forKey: .fillers)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        engineApproved = try c.decodeIfPresent(String.self, forKey: .engineApproved)
        engineRests = try c.decodeIfPresent([String: String].self, forKey: .engineRests)
        trustedProjects = try c.decodeIfPresent([String].self, forKey: .trustedProjects) ?? []
    }

    /// 設定ファイルを読めない理由。**読めないファイルを、黙って空の設定にしない**（そのあとの `save` が、信頼・無効化の設定を消すため）。
    public struct Unreadable: Error, CustomStringConvertible {
        public let file: URL
        public let reason: String
        public var description: String { "設定ファイル \(file.path) を読めません（\(reason)）。直すか、移動してください。壊れたままのファイルは、上書きしません" }
    }

    /// 読む。ファイルがなければ、空の設定（初めての使用）。あるのに読めなければ（壊れている・権限がない）、`Unreadable`。
    public static func load(from file: URL = VoiceControlHome.settingsFile) throws -> Settings {
        guard FileManager.default.fileExists(atPath: file.path) else { return Settings() }
        do { return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file)) } catch { throw Unreadable(file: file, reason: "\(error.localizedDescription)") }
    }

    /// 読み取りだけの使い方：読めなければ、**空の設定**（信頼したプロジェクトは、なし＝安全側）と、その理由を返す。
    public static func loadOrDefault(from file: URL = VoiceControlHome.settingsFile) -> (settings: Settings, problem: Unreadable?) {
        do { return (try load(from: file), nil) } catch { return (Settings(), error as? Unreadable ?? Unreadable(file: file, reason: "\(error)")) }
    }

    /// 書く。**壊れた既存のファイルは、上書きせず**、`Unreadable` を投げる（直してから、もう一度）。
    public func save(to file: URL = VoiceControlHome.settingsFile) throws {
        _ = try Self.load(from: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    public func isEnabled(_ name: String) -> Bool { !disabledSkills.contains(name) }

    public mutating func setEnabled(_ name: String, _ enabled: Bool) {
        disabledSkills.removeAll { $0 == name }
        if !enabled { disabledSkills.append(name); disabledSkills.sort() }
    }

    private static func key(_ project: URL) -> String { project.standardizedFileURL.resolvingSymlinksInPath().path }

    /// このプロジェクト（のルート）のスキルを、読み込んでよいか。
    public func isTrusted(project: URL) -> Bool { trustedProjects.contains(Self.key(project)) }

    public mutating func setTrusted(project: URL, _ trusted: Bool) {
        let path = Self.key(project)
        trustedProjects.removeAll { $0 == path }
        if trusted { trustedProjects.append(path); trustedProjects.sort() }
    }
}

extension Settings {
    /// 表示言語（設定 `uiLanguage`。なければ、書き間違いも、日本語：画面は、読めることを優先する）。
    public var displayLanguage: AppLanguage { AppLanguage.parse(uiLanguage) ?? .ja }
    /// 音声認識の言語（設定 `sttLanguage`）。書き間違いは、nil（呼ぶ側が、理由を示す）。なければ、日本語。
    public var recognitionLanguage: Result<SpeechLanguage, UnknownLanguage> {
        guard let sttLanguage else { return .success(.ja) }
        return SpeechLanguage.parse(sttLanguage).map { .success($0) } ?? .failure(UnknownLanguage(text: sttLanguage))
    }
    /// 画面・指示に使う、音声認識の言語（書き間違いは、日本語。書き間違いを知らせるのは、起動の検査：`CommandContext.resolveSttLanguage`）。
    public var recognitionLanguageOrDefault: SpeechLanguage { (try? recognitionLanguage.get()) ?? .ja }
    public struct UnknownLanguage: Error, Equatable, CustomStringConvertible {
        public let text: String
        public var description: String { "sttLanguage「\(text)」は、使えません（\(AppLanguage.codes)・auto）" }
    }
}

