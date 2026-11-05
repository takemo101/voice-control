import Foundation

enum Help {
    /// Tiny-Jev のモデルを読むコマンド（共通のオプションを案内する）。
    static let modelUsers: Set<String> = ["run", "listen"]

    /// `vc help` の説明。実際の処理は、`handle` が、コマンドを探す前に済ませる（コマンドではない）。
    static let helpInfo = CommandInfo(
        name: "help", group: .settings, summary: "ヘルプを表示する",
        usage: ["vc help [コマンド]", "vc --help", "vc <コマンド> --help"], details: [], options: [], examples: ["vc help run"])

    static let common: [(flag: String, text: String)] = [
        ("--model <dir>", "Tiny-Jev のモデルの場所（既定：VC_MODEL_DIR → ~/.voice-control/models/tiny-jev-0.6b → ./models/tiny-jev-0.6b。取得：vc model download）"),
        ("--length <トークン数>", "Tiny-Jev の入力の長さ（既定 1024。長いほど遅い）"),
        ("--floor <0〜1>", "確信度の下限（既定 0.40。未満は実行しない）"),
        ("--engine <エンジン>", "スキルを実行するモデル（既定：apple＝Apple のオンデバイスのモデル。ollama:qwen3.5:4b＝この Mac の Ollama。openai:<モデル>@<ポート>＝この Mac の OpenAI 互換サーバー〔LM Studio・llama.cpp など〕。通信先は 127.0.0.1 だけ。クラウドのモデルは使えない。確認：vc doctor --engine …。常にそうするなら vc engine set）"),
        ("--stt <音声認識>", "使う音声認識（既定：apple＝Apple の SpeechTranscriber。whisper-large-v3-turbo＝ダウンロードしたモデル。取得：vc model download <ID>。常にそうするなら vc stt set）"),
        ("-h, --help", "このヘルプを表示"),
        ("-V, --version", "版を表示"),
    ]

    /// 一覧の並びは、`Commands.all` の並び（グループの中）。`help` は、最後。
    static let commands: [CommandInfo] = Commands.all.map { $0.info } + [helpInfo]

    // MARK: 表示

    static func overview() -> String {
        var lines: [String] = []
        lines.append(Style.bold("vc") + " " + AppInfo.version + " — Mac を依頼文・声で操作する試作")
        lines.append(Style.dim("Tiny-Jev がスキルを選び、Apple の言語モデルが、許可されたコマンドを実行する。"))
        lines.append("")
        lines.append(Style.bold("使い方") + ": vc <コマンド> [引数] [オプション]")
        for group in CommandGroup.allCases {
            lines.append("")
            lines.append(Style.cyan(group.rawValue))
            for c in commands where c.group == group {
                lines.append("  " + Style.bold(pad(c.name, to: 14)) + c.summary)
            }
        }
        lines.append("")
        lines.append(Style.cyan("共通のオプション"))
        for o in common { lines.append("  " + pad(o.flag, to: 24) + o.text) }
        lines.append("")
        lines.append(Style.cyan("環境変数"))
        lines.append("  " + pad("VC_HOME", to: 24) + "~/.voice-control の場所（スキル・設定）")
        lines.append("  " + pad("VC_MODEL_DIR", to: 24) + "Tiny-Jev のモデルの場所")
        lines.append("  " + pad("NO_COLOR", to: 24) + "設定すると、色を使わない")
        lines.append("")
        lines.append("コマンドごとの説明: " + Style.bold("vc <コマンド> --help"))
        lines.append("例: vc skills / vc run \"Safariを開いて\" --dry-run")
        return lines.joined(separator: "\n")
    }

    static func detail(_ c: CommandInfo) -> String {
        var lines: [String] = []
        lines.append(Style.bold("vc " + c.name) + " — " + c.summary)
        lines.append("")
        lines.append(Style.cyan("使い方"))
        c.usage.forEach { lines.append("  " + $0) }
        if !c.details.isEmpty {
            lines.append("")
            lines.append(Style.cyan("説明"))
            c.details.forEach { lines.append("  " + $0) }
        }
        if !c.options.isEmpty {
            lines.append("")
            lines.append(Style.cyan("オプション"))
            let width = min(26, c.options.map { displayWidth($0.flag) }.max() ?? 0)
            for o in c.options {
                if displayWidth(o.flag) > width { lines.append("  " + o.flag); lines.append("  " + String(repeating: " ", count: width + 2) + o.text) }
                else { lines.append("  " + pad(o.flag, to: width + 2) + o.text) }
            }
        }
        if Self.modelUsers.contains(c.name) {
            lines.append("")
            lines.append(Style.cyan("共通のオプション") + Style.dim("（モデルを使うコマンド）"))
            for o in common { lines.append("  " + pad(o.flag, to: 24) + o.text) }
        }
        if !c.examples.isEmpty {
            lines.append("")
            lines.append(Style.cyan("例"))
            c.examples.forEach { lines.append("  " + Style.dim("$ ") + $0) }
        }
        return lines.joined(separator: "\n")
    }

    /// ヘルプが求められていれば、表示して `true`。モデルの読み込みなど、他の処理の前に呼ぶ。
    static func handle(_ arguments: [String]) -> Bool {
        if arguments.first == "--version" || arguments.first == "-V" { print("vc \(AppInfo.version)"); return true }
        let wantsHelp = arguments.contains("--help") || arguments.contains("-h")
        guard let first = arguments.first else { print(overview()); return true }
        if first == "help" || first == "--help" || first == "-h" {
            let name = arguments.dropFirst().first { !$0.hasPrefix("-") }
            print(name.flatMap(info(for:)).map(detail) ?? overview())
            return true
        }
        guard wantsHelp else { return false }
        let name = arguments.first { !$0.hasPrefix("-") }
        print(name.flatMap(info(for:)).map(detail) ?? overview())
        return true
    }

    static func info(for name: String) -> CommandInfo? { commands.first { $0.name == name } }
}
