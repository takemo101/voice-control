import Foundation
import Testing

/// `todo-remind` スキルの、時刻の言い方の読み方（`todo.sh time`）。**言語モデルは、午後・半の計算を間違える**（10時半を 11:30 に、午後3時を 15:30 にした）ので、コードが読む。
@Suite struct TodoRemindTimeTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".voice-control/skills/todo-remind/todo.sh")

    private func read(_ words: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.script.path, "time", words]
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
}
