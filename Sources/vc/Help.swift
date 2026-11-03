import Foundation

/// コマンドの説明（`vc --help`・`vc <コマンド> --help`）。
struct CommandInfo {
    let name: String
    let group: String
    let summary: String
    let usage: [String]
    let details: [String]
    let options: [(flag: String, text: String)]
    let examples: [String]
}

enum Help {
    /// Tiny-Jev のモデルを読むコマンド（共通のオプションを案内する）。
    static let modelUsers: Set<String> = ["run", "plan", "act", "listen", "eval", "eval-context"]
    static let groups = ["スキル（主な機能）", "PC 操作（試作）", "評価・検証", "設定"]

    static let common: [(flag: String, text: String)] = [
        ("--model <dir>", "Tiny-Jev のモデルの場所（既定：VC_MODEL_DIR → ~/.voice-control/models/tiny-jev-0.6b → ./models/tiny-jev-0.6b。取得：vc model download）"),
        ("--length <トークン数>", "Tiny-Jev の入力の長さ（既定 1024。長いほど遅い）"),
        ("--floor <0〜1>", "確信度の下限（既定 0.40。未満は実行しない）"),
        ("-h, --help", "このヘルプを表示"),
        ("-V, --version", "版を表示"),
    ]

    static let commands: [CommandInfo] = [
        CommandInfo(
            name: "skills", group: groups[0], summary: "スキルの一覧・詳細・有効／無効・プロジェクトの信頼",
            usage: ["vc skills [list]", "vc skills show <name>", "vc skills enable <name>", "vc skills disable <name>", "vc skills trust", "vc skills untrust"],
            details: [
                "置き場所は 2 つ。グローバル：~/.voice-control/skills/<name>/SKILL.md（環境変数 VC_HOME で ~/.voice-control を変えられる）。プロジェクト：<vc を起動した場所>/.voice-control/skills/<name>/SKILL.md（起動した場所が、プロジェクトのルート）。",
                "同じ名前なら、プロジェクトのスキルが、グローバルを上書きする。",
                "既定スキル（default）：どのスキルにも当てはまらない依頼を、Apple の言語モデルが、agent-desktop と基本のコマンド（open・say・ls・pwd・date）で実行する組み込みのスキル。Tiny-Jev の選択肢には入らない。許可を広げるなら、同じ名前（default）のスキルを置く。使わないなら vc skills disable default。",
                "プロジェクトのスキルは、外から来るもの（リポジトリなど）なので、**信頼したプロジェクトだけ**読み込む。初めは、未信頼で、件数だけを出す。中身（許可するコマンド）を確かめてから、そのプロジェクトで vc skills trust。やめるのは vc skills untrust。信頼は ~/.voice-control/settings.json に、プロジェクトの場所ごとに記録する。",
                "list：name・置き場所・description・有効／無効の一覧。読み込めなかったスキルは、理由つきで、下に出る。",
                "show：許可するコマンド・確認の要否・置き場所・ファイルの場所。",
                "enable / disable：Tiny-Jev の選択肢にするか。既定は有効。設定は ~/.voice-control/settings.json（名前ごと。プロジェクトのスキルも、同じ名前なら、まとめて）。",
                "trust / untrust：起動した場所のプロジェクトのスキルを、読み込んでよいか。trust は、許可するコマンドを表示してから、信頼する。",
            ],
            options: [],
            examples: ["vc skills", "vc skills show open-app", "vc skills disable open-app", "vc skills trust"]),
        CommandInfo(
            name: "run", group: groups[0], summary: "スキルを選んで、コマンドを実行する",
            usage: ["vc run <依頼> [--skill <name>] [--dry-run] [--yes]"],
            details: [
                "Tiny-Jev が、有効なスキルから、呼ぶものを選ぶ。スキルの本文と依頼文を Apple の言語モデルに渡し、コマンドを実行させる。",
                "実行してよいのは、スキルの allowed-commands に一致するコマンドだけ（シェルは使わない）。実行するコマンドと結果は、すべて表示する。",
                "確信度が 0.70 未満、またはスキルが confirm: true のときは、実行の前に [y/N] で確認する。",
            ],
            options: [
                ("--skill <name>", "Tiny-Jev で選ばず、このスキルを使う（無効なスキルは使えない）"),
                ("--dry-run", "コマンドを実行せず、実行しようとするコマンドだけを表示する（モデルは出力を見られないので、途中は推測になる）"),
                ("--yes", "確認を省略する"),
            ],
            examples: ["vc run \"Safariを開いて\" --dry-run", "vc run \"設定ボタンを押して\" --skill fixture-press --yes"]),
        CommandInfo(
            name: "plan", group: groups[1], summary: "発話から選んだ操作・確率・判定を表示する（実行しない）",
            usage: ["vc plan <発話> [--app <名前>]", "vc plan --audio <ファイル> [--app <名前>]"],
            details: [
                "前面のアプリの画面・アプリ・ショートカット・スクロールなどの候補から、Tiny-Jev が 1 手を選ぶ。複数の手に分けて、それぞれ表示する。",
                "--app を付けなければ、そのとき前面にあるアプリが対象（端末から実行すると、端末自身）。",
            ],
            options: [
                ("--app <名前>", "対象のアプリ"),
                ("--audio <ファイル>", "音声ファイルから文字起こしして、発話にする"),
                ("--llm-split", "Apple の言語モデルで、発話を 1 手ずつに書き直す（既定はルール）"),
                ("--no-context", "前の指示を、文脈に使わない"),
                ("--no-location", "要素の位置情報を、選択肢に添えない"),
                ("--keys <dir>", "キー操作の JSON 定義のディレクトリ"),
            ],
            examples: ["vc plan \"下にスクロールして\"", "vc plan --app Fixture \"削除して\""]),
        CommandInfo(
            name: "act", group: groups[1], summary: "発話から選んだ操作を実行する",
            usage: ["vc act <発話> [--app <名前>] [--execute] [--yes]", "vc act --audio <ファイル> [--execute] [--yes]"],
            details: [
                "plan と同じ流れ。既定は dry-run（--execute を付けたときだけ、実際に操作する）。",
                "確認が要る判定は、--yes がなければ実行しない。",
            ],
            options: [
                ("--execute", "実際に操作する"),
                ("--yes", "確認が要る判定を、承認する"),
                ("--app <名前> / --audio <ファイル> / --llm-split / --no-context / --no-location / --keys <dir>", "plan と同じ"),
            ],
            examples: ["vc act --app Fixture \"設定を開いて\" --execute"]),
        CommandInfo(
            name: "listen", group: groups[1], summary: "マイクから聞いて、スキルまたは PC 操作で実行する",
            usage: ["vc listen [--hotkey] [--trigger <キー>] [--dry-run] [--app <名前>] [--execute] [--yes]"],
            details: [
                "既定：Enter で録音を始め、もう一度 Enter で止める（q で終了）。マイクの許可が要る。",
                "--hotkey：トリガーを押している間だけ録音する。離すと、文字にして、Tiny-Jev がスキルを選び、Apple の言語モデルが実行する（vc run と同じ）。**当てはまるスキルがなければ、既定スキル（default）**が、agent-desktop と基本のコマンド（open・say・ls・pwd・date）で実行する。会話・独り言は、実行しない。取り消しにくい依頼（削除・送信・購入など）は、実行の前に、声の「はい」で確認する。既定スキルを無効にする（vc skills disable default）と、従来の PC 操作へ回す。",
                "画面の上に、録音中・認識中・選んだスキル・実行したコマンドと結果・言語モデルの返事を出す（クリックを通し、フォーカスを奪わない）。",
                "**Esc で取りやめ**：録音中は、録音を捨てる（認識しない）。認識中・実行中・確認の待ちは、処理を止める（実行中のコマンドも止める）。Esc を受けるのは、これらの間だけで、ふだんの Esc には触れない。録音中（Shift などを押している間）の Esc は、アクセシビリティの許可が要る。",
                "実行の既定：スキルは、vc run と同じく、**実行する**（--dry-run を付けたときだけ、表示だけ）。PC 操作（既定スキルも使えないとき）は、**--execute を付けたときだけ**実行する（なければ、計画の表示だけ）。",
                "トリガーは、既定が Shift の長押し。変えるには vc hotkey set <キー>（~/.voice-control/settings.json に保存）か、その回だけ --trigger <キー>。長押し（修飾キーだけ）の検出には、アクセシビリティの許可が要る（vc を動かす端末アプリに）。",
            ],
            options: [
                ("--hotkey", "押している間だけ録音する"),
                ("--trigger <キー>", "この回だけのトリガー（例：shift・ctrl+opt+space・f5。書き方は vc hotkey）"),
                ("--dry-run", "スキルのコマンドを実行せず、表示だけにする"),
                ("--app <名前> / --execute / --yes", "act と同じ（--execute：PC 操作を実行する）"),
            ],
            examples: ["vc listen --hotkey", "vc listen --hotkey --execute", "vc listen --hotkey --dry-run"]),
        CommandInfo(
            name: "hotkey-check", group: groups[1], summary: "トリガーが届くかを確かめる（マイクは使わない）",
            usage: ["vc hotkey-check [--trigger <キー>] [--seconds <秒>]"],
            details: ["押した・離したを表示し、画面の上に「録音中」を出す。いまの設定（vc hotkey）を使う。既定は 10 秒間。"],
            options: [("--trigger <キー>", "この回だけのトリガー"), ("--seconds <秒>", "待つ時間（既定 10）")],
            examples: ["vc hotkey-check", "vc hotkey-check --trigger ctrl+opt+space"]),
        CommandInfo(
            name: "hud-preview", group: groups[2], summary: "画面の上の表示の見本を出す（マイク・実行なし。見た目の確認用）",
            usage: ["vc hud-preview [--stage recording|working|confirm|success|failure|denied] [--seconds <秒>]"],
            details: ["--stage がなければ、順に、すべて出す。1 つの段階を出す秒数は、既定 3。内容は、作り物の見本。"],
            options: [("--stage <名前>", "この段階だけを出す"), ("--seconds <秒>", "1 段階あたりの秒数（既定 3）")],
            examples: ["vc hud-preview", "vc hud-preview --stage success --seconds 8"]),
        CommandInfo(
            name: "eval", group: groups[2], summary: "固定した画面での、操作の当たり率を測る（実機は操作しない）",
            usage: ["vc eval <plans.tsv> [--speak] [--llm] [--no-location]"],
            details: [
                "コーパスの形：snapshot<TAB>期待<TAB>発話。画面は、コーパスと同じ場所の snapshots/<名前>.json、アプリの一覧は apps.txt。",
                "確認なしで実行してしまった誤りの数も出す。",
            ],
            options: [
                ("--speak", "発話を say で合成し、文字起こしを通す（聞き違いも込みで測る）"),
                ("--llm", "同じ文を、Apple の言語モデルにも選ばせて、比べる"),
                ("--no-location", "位置情報なしで測る（比較用）"),
            ],
            examples: ["vc eval corpus/plans.tsv", "vc eval corpus/plans.tsv --no-location"]),
        CommandInfo(
            name: "eval-gate", group: groups[2], summary: "「操作の依頼か」の判定（既定スキルに回すか）の、当たり率を測る",
            usage: ["vc eval-gate <gate.tsv>"],
            details: ["コーパスの形：正解（op＝操作の依頼・chat＝会話や独り言）<TAB>発話。操作の依頼を、既定スキルへ回せたか・会話を止めたかを数え、取りこぼしと誤通過を出す。"],
            options: [], examples: ["vc eval-gate corpus/gate.tsv"]),
        CommandInfo(
            name: "eval-context", group: groups[2], summary: "前の指示を文脈に使うときと使わないときの、当たり率",
            usage: ["vc eval-context <followups.tsv>"],
            details: ["コーパスの形：snapshot<TAB>直前の操作<TAB>期待<TAB>発話。"],
            options: [], examples: ["vc eval-context corpus/followups.tsv"]),
        CommandInfo(
            name: "decompose", group: groups[2], summary: "長い依頼の分け方を、ルールと言語モデルで比べる",
            usage: ["vc decompose <発話>"], details: [], options: [], examples: ["vc decompose \"Chromeを開いて最近の流行を検索して\""]),
        CommandInfo(
            name: "llm", group: groups[2], summary: "Apple の言語モデルが選ぶ次の 1 手を見る",
            usage: ["vc llm <snapshot.json> <発話>"],
            details: ["環境変数 VC_LLM_DEBUG=1 で、モデルの生の出力も表示する。"],
            options: [], examples: ["vc llm corpus/snapshots/fixture-en.json \"削除して\""]),
        CommandInfo(
            name: "model", group: groups[3], summary: "Tiny-Jev のモデルの確認・取得（~/.voice-control/models）",
            usage: ["vc model [status [--verify]]", "vc model download [--force]", "vc model path"],
            details: [
                "Tiny-Jev 0.6B（約 1.2 GB）を、~/.voice-control/models/tiny-jev-0.6b に置く（VC_HOME で ~/.voice-control を変えられる）。",
                "download：版を固定した Hugging Face から取得し、SHA-256 を検証する。取得済みで一致するファイルは飛ばす。途中で切れたら、もう一度実行すると続きから。モデルの取得だけが、外部との通信（音声・画面は送らない）。",
                "status：置き場所・ファイルの有無と大きさ・実際に使われる場所。--verify で SHA-256 まで確かめる。path：置き場所だけを出す。",
            ],
            options: [("--verify", "status：SHA-256 まで確かめる"), ("--force", "download：取得済みでも、取り直す")],
            examples: ["vc model download", "vc model status --verify"]),
        CommandInfo(
            name: "hotkey", group: groups[3], summary: "押している間だけ聞くトリガー（ホットキー）の確認・変更",
            usage: ["vc hotkey [show]", "vc hotkey set <キー>", "vc hotkey reset"],
            details: [
                "設定は ~/.voice-control/settings.json の hotkey。既定は shift の長押し。",
                "書き方：修飾キー（ctrl・opt・shift・cmd）を + でつなぐ。修飾キーだけ（shift・ctrl+opt）は長押し（他のキーなしで 0.35 秒以上。アクセシビリティの許可が要る）。修飾キー + キー（ctrl+opt+space・cmd+shift+r）は、キーの組み合わせ（許可は要らない）。f1〜f12 だけは、単独でもよい。",
                "キーは、英字・数字・space・return・tab・escape・矢印（left・right・up・down）・f1〜f12。普通の入力を奪う、修飾キーなしの文字は使えない。macOS が先に使う組み合わせ（cmd+space など）は、届かないことがある。",
                "変えたら、vc hotkey-check で確かめる。vc listen --hotkey の次の起動から有効。",
            ],
            options: [],
            examples: ["vc hotkey", "vc hotkey set ctrl+opt+space", "vc hotkey set f5", "vc hotkey reset"]),
        CommandInfo(
            name: "keys", group: groups[3], summary: "キー操作の JSON 定義の一覧（plan・act の候補）",
            usage: ["vc keys [--keys <dir>]"],
            details: ["組み込みのキー操作と、足した定義（./keys、~/.voice-control/keys、VC_KEYS_DIR、--keys）を表示する。SKILL.md のスキルとは別のもの。"],
            options: [("--keys <dir>", "定義のディレクトリを足す")], examples: ["vc keys"]),
        CommandInfo(
            name: "help", group: groups[3], summary: "ヘルプを表示する",
            usage: ["vc help [コマンド]", "vc --help", "vc <コマンド> --help"], details: [], options: [], examples: ["vc help run"]),
    ]

    // MARK: 表示

    static func overview() -> String {
        var lines: [String] = []
        lines.append(Style.bold("vc") + " " + AppInfo.version + " — Mac を依頼文・声で操作する試作")
        lines.append(Style.dim("Tiny-Jev がスキルを選び、Apple の言語モデルが、許可されたコマンドを実行する。"))
        lines.append("")
        lines.append(Style.bold("使い方") + ": vc <コマンド> [引数] [オプション]")
        for group in groups {
            lines.append("")
            lines.append(Style.cyan(group))
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
        lines.append("  " + pad("VC_KEYS_DIR", to: 24) + "キー操作の JSON 定義の場所")
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
