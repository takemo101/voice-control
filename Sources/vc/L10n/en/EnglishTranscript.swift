import Foundation

extension EnglishTables {
    /// 文字起こし（システム音声。F80）・整理（F79）
    static let transcript: [String: String] = [
        "Mac から出ている音を、文字にします。録音・文字起こしには、相手の同意が要る場合があります。自分のマイクも文字にするときは、ヘッドホンを使ってください（スピーカーだと、マイクが相手の声を拾います）。": "Transcribes the sound coming out of this Mac. Recording or transcribing may require the other person's consent. If you also transcribe your own microphone, use headphones (with speakers the microphone picks up the other person's voice).",
        "文字起こし（相手の音声）": "Transcription (other party's audio)",
        "Mac から出ている音（会議・動画など）を、文字にします。画面収録の許可が要ります。音は、残しません。文字は、画面に出し、下の履歴をオンにしたときだけ、残します。スキルの実行・会話には、使いません。録音・文字起こしには、相手の同意が要る場合があります。": "Transcribes the sound coming out of this Mac (meetings, videos, etc.). Requires the Screen Recording permission. Audio is never saved. The text is shown on screen and saved only if the history below is on. It is never used to run skills or in conversation. Recording or transcribing may require the other person's consent.",
        "音が出るのを、待っています…": "Waiting for sound…",
        "「開始」を押すと、Mac から出ている音を、文字にします。": "Press Start to transcribe the sound coming out of this Mac.",
        "すべての音": "All sound",
        "システム音声の取り込みを始められません（%@）": "Can't start capturing system audio (%@)",
        "自分（マイク）も文字にする": "Also transcribe me (microphone)",
        "ヘッドホンを使ってください（スピーカーだと、マイクが、相手の声を拾います）": "Use headphones (with speakers the microphone picks up the other person's voice)",
        "マイクの入力が、ありません": "No microphone input",
        "一覧を読む": "Load list",
        "元：%@": "Original: %@",
        "取り込む音": "Sound to capture",
        "既定は、Mac から出ている音すべて。アプリを選ぶには、「一覧を読む」": "Default: all sound from this Mac. To pick an app, press Load list",
        "取り込めるアプリが、ありません": "No apps to capture",
        "始めています…": "Starting…",
        "履歴を書けませんでした：%@": "Couldn't write the history: %@",
        "文字にしています": "Transcribing",
        "文字起こしのウィンドウ": "Transcription window",
        "開始と停止は、ウィンドウの中のボタンです（メニューバーからも開けます）": "Start and stop with the buttons in the window (it can also be opened from the menu bar)",
        "文字起こし（相手の音声）を開く": "Open transcription (other party's audio)",
        "止まっています": "Stopped",
        "画面収録が許可されていません（システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で、このアプリを許可してください）": "Screen recording isn't allowed (System Settings > Privacy & Security > Screen & System Audio Recording: allow this app)",
        "相手": "Other party",
        "自分": "Me",
        "停止": "Stop",
        "開始": "Start",
        "音声の形式を、認識に渡せません": "Can't pass the audio format to recognition",
        "音声認識の言語（%@）のモデルが、入っていません（設定 > 音声 で、言語を入れてください）": "The speech recognition model for the language (%@) isn't installed (install it in Settings > Voice)",
        "音声認識を始められません（%@）": "Can't start speech recognition (%@)",
        "選んだアプリが起動していません：%@": "The selected app isn't running: %@",
        "音声入力・文字起こしの履歴を残す": "Keep dictation and transcription history",
    ]
}
