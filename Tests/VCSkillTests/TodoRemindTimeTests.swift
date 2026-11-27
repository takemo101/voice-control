import Foundation
import Testing

/// `todo-remind` スキルの、時刻の言い方の読み方（`todo.sh time`）。**言語モデルは、午後・半の計算を間違える**（10時半を 11:30 に、午後3時を 15:30 にした）ので、コードが読む。
@Suite struct TodoRemindTimeTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".voice-control/skills/todo-remind/todo.sh")

    private func read(_ words: String, _ action: String = "time") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.script.path, action, words]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「夕方5時ごろ」は、`Process` の引数で、濁点が分かれた形（NFD）で届く：そのままでは、「ごろ」を照合できなかった（実際の不具合）。
    @Test func spokenTimesBecomeTwentyFourHourClockTimes() throws {
        let table: [(String, String)] = [
            ("15:00", "15:00"), ("9:30", "09:30"), ("15時", "15:00"), ("15時半", "15:30"), ("10時半", "10:30"), ("9時15分", "09:15"),
            ("午前9時", "09:00"), ("午後1時", "13:00"), ("午後3時", "15:00"), ("午後3時半", "15:30"), ("午後12時", "12:00"), ("午前12時", "00:00"),
            ("夕方5時ごろ", "17:00"), ("夜の8時", "20:00"), ("夜12時", "00:00"), ("夜3時", "03:00"), ("朝7時", "07:00"), ("昼の12時", "12:00"), ("昼の1時", "13:00"), ("正午", "12:00"),
            ("９時半", "09:30"), ("10", "10:00"), ("夜の8", "20:00"), ("午後 5 時", "17:00"),
        ]
        for (words, expected) in table {
            let got = try read(words)
            #expect(got == expected, "\(words) -> \(got)")
        }
    }

    @Test func unreadableOrImpossibleTimesAreRefusedInsteadOfGuessed() throws {
        for words in ["25:00", "9時61分", "あした", "午後", "", "123", "99"] {
            let got = try read(words)
            #expect(got == "error", "\(words) -> \(got)")
        }
    }

    /// 「5分後」「1時間半後」：いまからの長さを、秒に（足し算は、コードが行う）。
    @Test func relativeTimesBecomeSecondsAndImpossibleOnesAreRefused() throws {
        let table: [(String, String)] = [("5分後", "300"), ("5分", "300"), ("30秒後", "30"), ("1時間後", "3600"), ("1時間半後", "5400"), ("1時間30分後", "5400"), ("２時間後に", "7200"), ("90分後", "5400"), ("24時間後", "86400")]
        for (words, expected) in table {
            let got = try read(words, "relative")
            #expect(got == expected, "\(words) -> \(got)")
        }
        for words in ["0分後", "25時間後", "後", "あした", "5時間30", "1000分後", "9時15分", "15時", ""] {
            let got = try read(words, "relative")
            #expect(got == "error", "\(words) -> \(got)")
        }
    }

    /// 文から、時刻の言い方を、コードが取り出す（言語モデルは、「5分後」を「5時」に書き換えるので、文全体を、写させる）。
    @Test func theTimeIsReadFromTheUsersOwnSentence() throws {
        let table: [(String, String)] = [
            ("5分後に音楽をかけるよう予約して", "5分後"), ("1時間半後にSafariを開くよう予約して", "1時間半後"), ("1時間30分後に曲を止めて", "1時間30分後"), ("30秒後に音を鳴らして", "30秒後"),
            ("15時に資料を送るTodoを追加して", "15時"), ("午後3時半に歯医者へ行くのでTodoに入れて", "午後3時半"), ("夜の8時に画面を撮る予約をして", "夜の8時"), ("9時15分に薬を飲むのでTodoに入れて", "9時15分"),
            ("正午にメモ帳を開くよう予約して", "正午"), ("１８：３０に電話するのでTodo", "18:30"), ("3時間後に5分休むのでTodoに入れて", "3時間後"),
        ]
        for (sentence, expected) in table {
            let got = try read(sentence, "extract")
            #expect(got == expected, "\(sentence) -> \(got)")
        }
        // 時刻でない文・長さ（後がない）は、取り出さない（このときは、言語モデルが渡した時刻を使う）
        for sentence in ["1時間かけて資料を作る予約をして", "今日のTodoを見せて", ""] {
            let got = try read(sentence, "extract")
            #expect(got == "error", "\(sentence) -> \(got)")
        }
    }
}
