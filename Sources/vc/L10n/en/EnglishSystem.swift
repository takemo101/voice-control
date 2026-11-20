import Foundation

extension EnglishTables {
    /// システムの状態の説明（Apple Intelligence・マイク・画面収録・エンジン）と、スキルの読み込みの失敗の理由。
    static let system: [String: String] = [
        // Apple Intelligence
        "この Mac（または環境）は、Apple Intelligence に対応していません": "This Mac (or environment) doesn't support Apple Intelligence.",
        "Apple Intelligence が、オフです": "Apple Intelligence is turned off.",
        "Apple の言語モデルが、まだ使えません（ダウンロード中など）": "The Apple language model isn't available yet (for example, it is still downloading).",
        "Apple の言語モデルが、使えません": "The Apple language model isn't available.",
        "Apple Intelligence は、対応する Mac・macOS・言語と地域でだけ使えます（仮想マシンなどでは、使えないことがあります）。スキルの実行には、これが要ります": "Apple Intelligence works only on supported Macs, macOS versions, languages and regions (it may not work in a virtual machine). Running skills requires it.",
        "システム設定 > Apple Intelligence と Siri で、Apple Intelligence をオンにしてください（オンにすると、言語モデルのダウンロードが始まります）": "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri (the language model starts downloading once it is on).",
        "システム設定 > Apple Intelligence と Siri で、ダウンロードが終わるのを待って、もう一度実行してください": "Wait for the download to finish (System Settings > Apple Intelligence & Siri), then run it again.",
        "システム設定 > Apple Intelligence と Siri を確かめてください（対応する言語・地域の設定も）": "Check System Settings > Apple Intelligence & Siri (including a supported language and region).",
        // マイク
        "マイクが、この Mac の制限（管理プロファイル・ペアレンタルコントロール）で、使えません": "The microphone is blocked by a restriction on this Mac (a management profile or parental controls).",
        "マイクが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）。許可が要るのは、vc を動かしている端末アプリです（tmux・ssh の中などで、アプリを特定できませんでした。端末アプリから、直接、動かしてみてください）": "Microphone access isn't allowed (System Settings > Privacy & Security > Microphone). The permission belongs to the terminal app running vc. It couldn't be identified (for example, you may be inside tmux or ssh), so try running vc directly from the terminal app.",
        "マイクが許可されていません。許可が要るのは vc ではなく、vc を動かしているアプリ「%@」です（システム設定 > プライバシーとセキュリティ > マイク で、オンに）": "Microphone access isn't allowed. The permission belongs not to vc but to the app running it, “%@”. Turn it on in System Settings > Privacy & Security > Microphone.",
        "「%@」": "“%@”",
        "・": ", ",
        "。同じアプリの中の別のもの（%@）の許可を、見ている場合もあります": ". The permission may also be checked against another process in the same app (%@).",
        " ／ ": " / ",
        "。許可の記録を、やり直す：%@（そのアプリだけが、リセットされます。そのあと、アプリを開き直すと、次の実行で、確認が出ます）": ". To reset the permission record, run: %@ (this resets only that app. Rerelaunch it, and the prompt appears on the next run).",
        // 画面収録
        "システム設定 > プライバシーとセキュリティ > 画面収録 で、voice-control（端末から動かしているなら、その端末アプリ）を許可してください（許可したら、アプリを開き直してください）": "Allow voice-control (or the terminal app, if you run it from a terminal) in System Settings > Privacy & Security > Screen Recording, then relaunch the app.",
        "画面収録の許可がありません。%@": "Screen recording isn't allowed. %@",
        "撮った画像を保存できません（%@）": "Couldn't save the captured image (%@)",
        "スクリーンショットを置けません（%@）": "Couldn't store the screenshot (%@)",
        // 音声認識
        // エンジン
        "エンジン「%@」は使えません（apple・ollama:<モデル>・openai:<モデル>@<ポート>。例：ollama:qwen3.5:4b・openai:qwen3-4b@1234）": "The engine “%@” isn't supported (use apple, ollama:<model> or openai:<model>@<port>, for example ollama:qwen3.5:4b or openai:qwen3-4b@1234).",
        "モデル名「%@」が使えません（英数字・. _ : / - だけ）": "The model name “%@” isn't valid (letters, digits and . _ : / - only).",
        "「%@」は、クラウドのモデルです。音声・画面の内容を、外へ出さないので、使えません": "“%@” is a cloud model. It can't be used because voice and screen content never leave this Mac.",
        "ポート「%@」が使えません（1〜65535 の数。通信先は、この Mac の 127.0.0.1 だけ）": "The port “%@” isn't valid (a number from 1 to 65535; only 127.0.0.1 on this Mac is used).",
        // スキルの読み込み
        "先頭に、フロントマター（--- で囲む）がない": "The front matter (enclosed in ---) is missing at the top",
        "name がない": "name is missing",
        "name は、英小文字・数字・ハイフン（40 文字まで）": "name must use lowercase letters, digits and hyphens (up to 40 characters)",
        "name（%@）が、ディレクトリ名（%@）と違う": "name (%@) doesn't match the directory name (%@)",
        "description がない": "description is missing",
        "description が長い（%@ 文字。%@ まで）": "description is too long (%1$@ characters; the limit is %2$@)",
        "allowed-commands がない（実行してよいコマンドを、明示する）": "allowed-commands is missing (list the commands that may run)",
        "allowed-commands「%@」：${SCREENSHOT} は、本文だけに書ける（許可は、実行のたびに変わる値で決めないため）": "allowed-commands “%@”: ${SCREENSHOT} can be used only in the body (permissions must not depend on a value that changes on every run)",
        "allowed-commands「%@」：${USER_REQUEST} は、本文だけに書ける（許可を、発話で変えないため）": "allowed-commands “%@”: ${USER_REQUEST} can be used only in the body (permissions must not be changed by what you say)",
        "allowed-commands「%@」：知らない記号 ${%@}（使えるのは ${SKILL_DIR}）": "allowed-commands “%@”: unknown placeholder ${%@} (only ${SKILL_DIR} is available)",
        "allowed-commands「%@」：%@": "allowed-commands “%@”: %@",
        "result「%@」は使えない（markdown-note・markdown-window）": "result “%@” isn't supported (use markdown-note or markdown-window)",
        "timeout「%@」は使えない（%@〜%@ の整数。秒）": "timeout “%@” isn't supported (an integer from %@ to %@, in seconds)",
        "本文に、知らない記号 ${%@}（使えるのは ${SKILL_DIR}・${USER_REQUEST}・${SCREENSHOT}。書き間違いでなければ、$ と { の間に、スペースなどを入れる）": "The body has an unknown placeholder ${%@} (available: ${SKILL_DIR}, ${USER_REQUEST} and ${SCREENSHOT}). If it isn't a typo, put a space between $ and {",
        "本文（言語モデルへの指示）が空": "The body (instructions for the language model) is empty",
        "image「%@」は、true・screenshot（撮ったスクリーンショット）・clipboard（コピーした画像）・any（どちらでも）のどれかです": "image “%@” must be one of true, screenshot (the captured screenshot), clipboard (the copied image) or any (either)",
        // コマンドの許可
        "引用符が閉じていない": "A quotation mark isn't closed",
        "末尾が \\ で終わっている": "It ends with a backslash (\\)",
        "ツール名は Bash だけ（%@）": "Only Bash is allowed as a tool name (%@)",
        "解釈できない（引用符・\\ の閉じ忘れ）": "Can't be parsed (an unclosed quotation mark or backslash)",
        "空": "empty",
        "コマンド名に * は使えない（どのコマンドにも一致してしまう）": "The command name can't contain * (it would match every command)",
        "コマンド名にパスは使えない（PATH の名前だけ）": "The command name can't be a path (use a name found on PATH)",
        "コマンド名に使えない文字がある": "The command name contains characters that aren't allowed",
        "%@ は、許可できない（シェル・別のコマンドを起動する・権限を上げる）": "%@ can't be allowed (it is a shell, launches other commands or raises privileges)",
    ]
}
