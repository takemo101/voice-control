import Foundation
import VCCore

/// ACP で話す会話のエージェント（`agy`・`opencode`・`claude`・`codex`）を、**OS の制限（macOS の Seatbelt。`sandbox-exec`）つきで起動する**：**書き込みを、作業フォルダ（「すべて」のときだけ）と、エージェント自身の状態の置き場だけ**に限る。
/// 許可の確認（`ACPPermission`）は、「エージェントが聞いてきたとき」だけ働く（仕様でも、許可の要求は助言）。**これは、エージェントの申告に頼らない、もう 1 つの壁**：確認で「はい」と答えても、作業フォルダの外へは、書けない。
/// 読む側は、**鍵の置き場**（`~/.ssh`・`~/.aws`・`~/.gnupg`）だけ、閉じる（外のモデルへ、鍵が渡る道を、塞ぐ）。ネットワークは、そのまま（Web 検索・モデルの呼び出しに要る）。
/// 制約：コマンドも、この制限の中で動く（`~/Library/Caches` などへの書き込み・`npm install` のキャッシュは、できない）。設定 `chatSandbox` で、切れる。Seatbelt は、Apple が非推奨にしているが、動いている（手元で確認）。
enum ACPSandbox {
    static let executable = "/usr/bin/sandbox-exec"

    /// 制限をかけられるエージェント（ACP で話せるもの）。
    static func applies(to agent: ChatAgent) -> Bool { ACPAgentProfile.of(agent) != nil }

    /// 起動の引数を、制限つきの起動に包む。
    static func wrap(_ argv: [String], agent: ChatAgent, level: ChatToolLevel, folder: URL, home: String = NSHomeDirectory()) -> [String] {
        [executable, "-p", profile(agent: agent, level: level, folder: folder, home: home)] + argv
    }

    /// 制限の中身（Seatbelt の設定）。**純粋**。
    static func profile(agent: ChatAgent, level: ChatToolLevel, folder: URL, home: String) -> String {
        var writable: [String] = []
        if level == .all { writable.append(RealPath.eventual(folder.path)) }   // 書き込みの確認が出るのは「すべて」だけ。それ以外は、フォルダにも、書かせない
        writable += stateDirectories(agent: agent, home: home)
        writable.append("/private/var/folders")   // 一時フォルダ（TMPDIR）
        let unreadable = [".ssh", ".aws", ".gnupg"].map { home + "/" + $0 }
        var lines = ["(version 1)", "(allow default)", "(deny file-write*)"]
        lines.append("(deny file-read* " + unreadable.map { "(subpath \(quote($0)))" }.joined(separator: " ") + ")")
        let files = stateFiles(agent: agent, home: home).map { "(literal \(quote($0))) (regex #\"^\(regexEscaped($0))\\..*$\")" }.joined(separator: " ")   // 名前の頭が同じ、一時・ロック・退避のファイルも
        let prefixes = (ACPAgentProfile.of(agent)?.statePrefixes ?? []).map { "(regex #\"^\(regexEscaped($0))\")" }.joined(separator: " ")   // 頭が一致する、絶対の場所
        lines.append("(allow file-write* " + writable.map { "(subpath \(quote($0)))" }.joined(separator: " ")
                     + (files.isEmpty ? "" : " " + files) + (prefixes.isEmpty ? "" : " " + prefixes)
                     + " (literal \"/dev/null\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\") (literal \"/dev/ptmx\") (regex #\"^/dev/ttys[0-9]+$\"))")
        lines.append("(allow pseudo-tty)")   // コマンドの実行（agy は、端末を作る）
        return lines.joined(separator: "\n")
    }

    /// エージェント自身が、書く場所（会話・認証・設定・キャッシュ）。
    static func stateDirectories(agent: ChatAgent, home: String) -> [String] {
        (ACPAgentProfile.of(agent)?.stateDirectories ?? []).map { home + "/" + $0 }
    }

    /// エージェント自身が、書く**ファイル**（ホームの直下の設定ファイルなど）。
    static func stateFiles(agent: ChatAgent, home: String) -> [String] {
        (ACPAgentProfile.of(agent)?.stateFiles ?? []).map { home + "/" + $0 }
    }

    /// 正規表現の中で、そのままの文字として扱うために、記号を逃がす（ホームの場所に、`.` などが入っていても、別の場所に、一致しない）。
    private static func regexEscaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\.+*?()[]{}|^$".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Seatbelt の文字列（`"` と `\` を逃がす）。
    private static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
