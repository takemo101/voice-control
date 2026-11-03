import Foundation

/// このツールの置き場所（`~/.voice-control`。環境変数 `VC_HOME` で変える：検証用）。
public enum VoiceControlHome {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["VC_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voice-control")
    }
    public static var skillsDirectory: URL { root.appendingPathComponent("skills") }
    public static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    /// プロジェクトのスキルの置き場所：`<プロジェクトのルート>/.voice-control/skills`。ルートは、コマンドを起動した場所（カレントディレクトリ）。
    public static func projectSkillsDirectory(root: URL) -> URL { root.appendingPathComponent(".voice-control/skills") }
    /// 起動した場所（プロジェクトのルート）。
    public static var launchDirectory: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
}
