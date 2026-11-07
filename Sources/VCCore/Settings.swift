import Foundation

/// 設定（`~/.voice-control/settings.json`）。
/// - `disabledSkills`：スキルの有効・無効。**既定は有効**（無効にしたものだけ、記録する）。
/// - `hotkey`：押している間だけ聞くトリガーの書き方（文字列。解釈は Speech 層）。なければ、`shift` の長押し。
/// - `dictateHotkey`：音声入力（`vc dictate`）のトリガー。なければ、声で頼むトリガー（`hotkey`）と同じ。**設定すると、`vc listen --hotkey` も、このトリガーで音声入力になる**（トリガーで切り替わる）。
/// - `stt`：使う音声認識（`apple`、またはダウンロードしたモデルの ID。解釈は Speech 層）。なければ、Apple の `SpeechTranscriber`。
/// - `mute`：録音中に、ほかの音（出力）を消すか。`true` が既定（なければ、消す）。`false` なら、流したまま。
/// - `removeFillers`：音声入力で、つなぎ言葉（「えーと」など）を消すか。なければ、消さない。
/// - `fillers`：消すつなぎ言葉の辞書（利用者が足し引きする）。なければ、既定の辞書（解釈は Speech 層）。
/// - `engine`：スキルを実行するモデル（`apple`・`ollama:<モデル>`・`openai:<モデル>@<ポート>`。解釈は Skill 層）。なければ、Apple。
/// - `trustedProjects`：プロジェクトのスキル（`<ルート>/.voice-control/skills`）を読み込んでよいと、利用者が確認したプロジェクトのルート。**既定は、どれも信頼しない**。
public struct Settings: Codable, Sendable, Equatable {
    public var disabledSkills: [String] = []
    public var hotkey: String?
    public var dictateHotkey: String?
    public var stt: String?
    public var mute: Bool?
    public var removeFillers: Bool?
    public var fillers: [String]?
    public var engine: String?
    public var trustedProjects: [String] = []

    public init() {}

    // 項目が足りない古いファイルも読めるように、すべて `decodeIfPresent`。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabledSkills = try c.decodeIfPresent([String].self, forKey: .disabledSkills) ?? []
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        dictateHotkey = try c.decodeIfPresent(String.self, forKey: .dictateHotkey)
        stt = try c.decodeIfPresent(String.self, forKey: .stt)
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute)
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers)
        fillers = try c.decodeIfPresent([String].self, forKey: .fillers)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
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
