import Foundation
import VCCore
import VCSpeech

struct FillersCommand: Command {
    static let info = CommandInfo(
        name: "fillers", group: .settings, summary: "音声入力で消す、つなぎ言葉（えーと・um など）の辞書の確認・足し引き・オン／オフ",
        usage: ["vc fillers [show]", "vc fillers on", "vc fillers off", "vc fillers add <語>…", "vc fillers remove <語>…", "vc fillers reset"],
        details: [
            "**音声入力（vc dictate・vc listen --hotkey の音声入力のトリガー）で入力する文字から、辞書にある、つなぎ言葉を消す**（言語モデルは使わない。文字列の一致だけ）。既定は off。声で頼む依頼文には、かけない（依頼に出てくる語を、消してしまわないため）。",
            "設定は ~/.voice-control/settings.json の removeFillers（オン／オフ）と fillers（辞書）。辞書は、書き換えると、**次の入力から**有効（動いている vc を、再起動しなくてよい）。",
            "既定の辞書：日本語は、つなぎ言葉だと間違いない形だけ（えーと・えっと・あのー・うーん など。「あの」「その」「まあ」は、ふつうの語でもあるので、入れない）と、英語（um・uh・hmm など）。",
            "一致の規則：英数字の語は、単語全体（umbrella・uh-huh は残る）。日本語は、文頭・句読点の直後、または、3 文字以上の語が、直後に読点・句点を伴うとき。消した語に付く読点も、一緒に消す。",
            "**注意**：ふつうの語の一部にもなる語（「あの」など）を足すと、文頭・句読点の直後にある、その語も消える。1 文字の語と、最後が助詞（を・は・も・が・に）の語（声から取り出すと、付いてくることがある）は、足せない。",
            "add：辞書に足す（すでにあれば、何もしない）。声でも足せる：filler-add スキル（vc skills install filler-add。「『あのさ』をつなぎ言葉に追加して」）。remove：辞書から外す。reset：辞書を、既定に戻す（オン／オフは、そのまま）。",
        ],
        options: [],
        examples: ["vc fillers", "vc fillers on", "vc fillers add あのさ", "vc fillers add \"you know\"", "vc fillers remove えー", "vc fillers reset"])

    func run(_ arguments: Arguments, _ context: CommandContext) async throws {
        let sub = arguments.positionals.first ?? "show"
        let words = Array(arguments.positionals.dropFirst())
        var settings = context.currentSettings()
        func save() { do { try settings.save() } catch { fail("設定を保存できません: \(error)") } }
        let list = FillerWords.list(setting: settings.fillers)
        let enabled = FillerWords.isEnabled(setting: settings.removeFillers)
        let stateText = enabled ? "on（音声入力で、つなぎ言葉を消す）" : "off（消さない）"

        switch sub {
        case "show", "list":
            heading("つなぎ言葉の除去（音声入力）")
            kv("いまの設定", Style.bold(stateText) + Style.dim(settings.removeFillers == nil ? "（既定）" : "（設定）"))
            kv("辞書", "\(list.count) 語" + Style.dim(settings.fillers == nil ? "（既定の辞書）" : "（設定）"))
            print("  " + (list.isEmpty ? Style.dim("（空）") : list.joined(separator: "　")))
            print("")
            notice("変える：vc fillers on / off。足す：vc fillers add <語>。外す：vc fillers remove <語>。既定の辞書に戻す：vc fillers reset")
        case "on", "off":
            settings.removeFillers = sub == "on"
            save()
            print(Style.green("✓") + " つなぎ言葉の除去を " + Style.bold(sub) + " にしました" + Style.dim("（次の入力から有効。辞書 \(list.count) 語）"))
        case "add":
            guard !words.isEmpty else { usageError("fillers", "語を渡してください（例: vc fillers add あのさ）") }
            var current = list
            var added: [String] = [], existing: [String] = []
            for word in words {
                switch FillerWords.adding(word, to: current) {
                case let .success(result):
                    current = result.list
                    if result.added { added.append(word.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")) } else { existing.append(word) }
                case let .failure(error): fail("「\(word.prefix(30))」を足せません：\(error)")
                }
            }
            if !added.isEmpty { settings.fillers = current; save() }
            var line = Style.green("✓")
            line += added.isEmpty ? " 辞書に、すでにあります：\(existing.joined(separator: "・"))" : " 辞書に追加しました：\(added.joined(separator: "・"))" + (existing.isEmpty ? "" : "（すでにあった：\(existing.joined(separator: "・"))）")
            print(line + Style.dim("（辞書 \(current.count) 語。つなぎ言葉の除去は、いま \(enabled ? "on" : "off")）"))
            if !enabled { notice("音声入力で消すには：vc fillers on") }
        case "remove":
            guard !words.isEmpty else { usageError("fillers", "語を渡してください（例: vc fillers remove えー）") }
            var current = list
            var removed: [String] = [], missing: [String] = []
            for word in words {
                let result = FillerWords.removing(word, from: current)
                current = result.list
                if result.removed { removed.append(word) } else { missing.append(word) }
            }
            if !removed.isEmpty { settings.fillers = current; save() }
            if removed.isEmpty { fail("辞書にありません：\(missing.joined(separator: "・"))") }
            print(Style.green("✓") + " 辞書から外しました：\(removed.joined(separator: "・"))" + (missing.isEmpty ? "" : "（辞書になかった：\(missing.joined(separator: "・"))）") + Style.dim("（辞書 \(current.count) 語）"))
        case "reset":
            settings.fillers = nil
            save()
            print(Style.green("✓") + " 辞書を、既定に戻しました" + Style.dim("（\(FillerWords.defaults.count) 語。オン／オフは、そのまま：いま \(enabled ? "on" : "off")）"))
        default:
            usageError("fillers", "知らないサブコマンド: \(sub)（show・on・off・add・remove・reset）")
        }
    }
}
