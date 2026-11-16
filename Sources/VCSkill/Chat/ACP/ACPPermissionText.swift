import Foundation
import VCCore

/// ACP の許可の確認の、**表示用の文**（**純粋**）：何をするか（種類と、実際の場所・コマンド）・実行中の操作。エージェントの文字は、非信頼：見えない文字を、見える形にする。
enum ACPPermissionText {
    /// 確認の文（何をするか）：種類と、**実際の場所・コマンド**。エージェントの題（`File ../../../private/var/…`）は、読みにくく、本当の場所を隠すので、使わない（場所がなければ、題）。
    static func detail(_ call: ACPToolCall, folder: URL) -> String {
        let title = visible(call.title)
        let path = call.path.map { visible(displayPath($0, folder: folder)) }
        switch call.kind {
        case "edit": return "ファイルを書き込む：\(path ?? title)"
        case "delete": return "ファイルを削除する：\(path ?? title)"
        case "move": return "ファイルを移動する：\(path ?? title)"
        case "execute": return "コマンドを実行する：\(call.command.map(shownCommand) ?? title)"
        default: return "操作する：\(path ?? title)"
        }
    }

    /// 場所の見せ方：作業フォルダの中は、そこからの相対（`notes/a.txt`）。**外は、全部の場所に、「作業フォルダの外」を添える**（外への書き込みに、気づけるように）。
    static func displayPath(_ path: String, folder: URL) -> String {
        let root = RealPath.eventual(folder.path)
        let target = RealPath.eventual(path)
        if target == root { return "." }
        if RealPath.isInside(target, root: root) { return String(target.dropFirst(root.count + 1)) }
        return target + "（作業フォルダの外）"
    }

    /// 確認の文に出す、コマンド（見えない文字を見える形に・長いものは、切る）。
    static func shownCommand(_ text: String) -> String {
        visible(text.count > 600 ? String(text.prefix(600)) + "…（残り \(text.count - 600) 文字）" : text)
    }

    /// 確認の文に出す、エージェントの文字：**見えない文字・向きを変える文字・制御文字を、見える形（`⟨U+202E⟩`）にする**（仕様の安全の指針：コマンド・場所に、紛れ込ませて、読み違えさせる手を、防ぐ）。改行・タブは、空白。
    static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x0A || v == 0x0D || v == 0x09 { out += " "; continue }
            let hidden = v < 0x20 || (0x7F...0x9F).contains(v) || (0x200B...0x200F).contains(v) || (0x2028...0x202E).contains(v)
                || (0x2060...0x2069).contains(v) || v == 0xFEFF || (0xE0000...0xE007F).contains(v)
            out += hidden ? "⟨U+" + String(v, radix: 16, uppercase: true) + "⟩" : String(scalar)
        }
        return out
    }

    /// 実行中の操作（画面に出す）。出さないもの（考え中）は、nil。
    static func activity(_ call: ACPToolCall) -> ChatActivity? {
        let title = call.title, name = call.name
        switch call.kind {
        case "think": return nil
        case "read": return .read(title)
        case "search": return ACPPermission.folderReadTools.contains(name?.lowercased() ?? "") ? .read(title) : .search(title)   // grep・glob は、フォルダの中を読む
        case "fetch": return .fetch(title)
        case "edit", "delete", "move": return .write(title)
        case "execute": return .run(title)
        default: return .other(title)
        }
    }
}
