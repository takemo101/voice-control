import Foundation
import VCCore

enum Help {
    /// Tiny-Jev のモデルを読むコマンド（共通のオプションを案内する）。
    static let modelUsers: Set<String> = ["run"]

    /// `vc help` の説明。実際の処理は、`handle` が、コマンドを探す前に済ませる（コマンドではない）。
    static var helpInfo: CommandInfo {
        CommandInfo(
            name: "help", group: .skills, summary: tr("ヘルプを表示する"),
            usage: [tr("vc help [コマンド]"), "vc --help", tr("vc <コマンド> --help")], details: [], options: [], examples: ["vc help run"])
    }

    /// 表示のたびに作る（表示言語は、起動のあとで決まる）。
    static var common: [(flag: String, text: String)] {
        [
            ("--model <dir>", tr("Tiny-Jev のモデルの場所（既定：VC_MODEL_DIR → ~/.voice-control/models/tiny-jev-0.6b → ./models/tiny-jev-0.6b。取得：アプリの設定 > モデル）")),
            (tr("--length <トークン数>"), tr("Tiny-Jev の入力の長さ（既定 1024。長いほど遅い）")),
            (tr("--floor <0〜1>"), tr("確信度の下限（既定 0.40。未満は実行しない）")),
            (tr("--engine <エンジン>"), tr("スキルを実行するモデル（既定：apple＝Apple のオンデバイスのモデル。ollama:<モデル>[@<場所>]＝Ollama（場所を省くと 127.0.0.1:11434）。openai:<モデル>@<場所>＝OpenAI 互換のサーバー〔LM Studio・oMLX・Strata など〕。場所は、ポート（この Mac）か ホスト:ポート（同じ LAN）に API の経路（例 http://192.168.1.5:8080/v1）。通信先は、この Mac と同じ LAN だけ。クラウドのモデルは使えない。確認：vc doctor --engine …。常にそうするなら、設定ウィンドウ > モデル）")),
            (tr("--stt <音声認識>"), tr("使う音声認識（既定：apple＝Apple の SpeechTranscriber。whisper-large-v3-turbo＝ダウンロードしたモデル。取得：設定ウィンドウ > モデル。常にそうするなら 設定ウィンドウ > モデル > 音声認識）")),
            ("-h, --help", tr("このヘルプを表示")),
            ("-V, --version", tr("版を表示")),
        ]
    }

    /// 一覧の並びは、`Commands.all` の並び（グループの中）。`help` は、最後。
    static var commands: [CommandInfo] { Commands.all.map { $0.info } + [helpInfo] }

    // MARK: 表示

    static func overview() -> String {
        var lines: [String] = []
        lines.append(Style.bold("vc") + " " + AppInfo.version + " — " + tr("スキルが使うコマンドと、診断"))
        lines.append(Style.dim(tr("声の入力・設定は、メニューバーのアプリ（VoiceControl.app。引数なしで vc を動かすと、起動する）。")))
        lines.append("")
        lines.append(Style.bold(tr("使い方")) + ": " + tr("vc <コマンド> [引数] [オプション]"))
        for group in CommandGroup.allCases {
            lines.append("")
            lines.append(Style.cyan(group.title))
            for c in commands where c.group == group {
                lines.append("  " + Style.bold(pad(c.name, to: 14)) + c.summary)
            }
        }
        lines.append("")
        lines.append(Style.cyan(tr("共通のオプション")))
        for o in common { lines.append("  " + pad(o.flag, to: 24) + o.text) }
        lines.append("")
        lines.append(Style.cyan(tr("環境変数")))
        lines.append("  " + pad("VC_HOME", to: 24) + tr("~/.voice-control の場所（スキル・設定）"))
        lines.append("  " + pad("VC_MODEL_DIR", to: 24) + tr("Tiny-Jev のモデルの場所"))
        lines.append("  " + pad("NO_COLOR", to: 24) + tr("設定すると、色を使わない"))
        lines.append("")
        lines.append(tr("コマンドごとの説明: ") + Style.bold(tr("vc <コマンド> --help")))
        lines.append(tr("例: vc skills / vc run \"Safariを開いて\" --dry-run / vc doctor"))
        return lines.joined(separator: "\n")
    }

    static func detail(_ c: CommandInfo) -> String {
        var lines: [String] = []
        lines.append(Style.bold("vc " + c.name) + " — " + c.summary)
        lines.append("")
        lines.append(Style.cyan(tr("使い方")))
        c.usage.forEach { lines.append("  " + $0) }
        if !c.details.isEmpty {
            lines.append("")
            lines.append(Style.cyan(tr("説明")))
            c.details.forEach { lines.append("  " + $0) }
        }
        if !c.options.isEmpty {
            lines.append("")
            lines.append(Style.cyan(tr("オプション")))
            let width = min(26, c.options.map { displayWidth($0.flag) }.max() ?? 0)
            for o in c.options {
                if displayWidth(o.flag) > width { lines.append("  " + o.flag); lines.append("  " + String(repeating: " ", count: width + 2) + o.text) }
                else { lines.append("  " + pad(o.flag, to: width + 2) + o.text) }
            }
        }
        if Self.modelUsers.contains(c.name) {
            lines.append("")
            lines.append(Style.cyan(tr("共通のオプション")) + Style.dim(tr("（モデルを使うコマンド）")))
            for o in common { lines.append("  " + pad(o.flag, to: 24) + o.text) }
        }
        if !c.examples.isEmpty {
            lines.append("")
            lines.append(Style.cyan(tr("例")))
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
