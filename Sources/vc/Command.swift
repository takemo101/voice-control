/// ヘルプでの分類（`vc --help` の見出し。並びも、これ）。
enum CommandGroup: String, CaseIterable {
    case skills = "スキル（主な機能）"
    case evaluation = "評価・検証"
    case settings = "設定"
}

/// コマンドの説明（`vc --help`・`vc <コマンド> --help`）。
struct CommandInfo {
    let name: String
    let group: CommandGroup
    let summary: String
    let usage: [String]
    let details: [String]
    let options: [(flag: String, text: String)]
    let examples: [String]
}

/// `vc <name>` の 1 つ。足し方は docs/development.md の「コマンドの足し方」。
protocol Command {
    /// 名前・使い方・説明。`Help` は、ここから文を作る。
    static var info: CommandInfo { get }
    init()
    /// `arguments` は、共通のオプション（`CommonOptions`）を取り除いたあとの残り。自分のオプションは、ここから取り除く（`var` に写して、`option`・`flag`）。
    /// AppKit を使うので、メインアクターで動く（従来の `main.swift` のトップレベルと同じ）。
    @MainActor func run(_ arguments: Arguments, _ context: CommandContext) async throws
}

/// コマンドの一覧。`vc --help` の表示順（グループの中の並び）は、この並び。
enum Commands {
    static let all: [any Command.Type] = [
        SkillsCommand.self, RunCommand.self, ListenCommand.self, ShowCommand.self, FindCommand.self, PickCommand.self,
        HotkeyCheckCommand.self, HudPreviewCommand.self, EvalGateCommand.self,
        DoctorCommand.self, ModelCommand.self, HotkeyCommand.self,
    ]

    static func find(_ name: String) -> (any Command.Type)? { all.first { $0.info.name == name } }
}
