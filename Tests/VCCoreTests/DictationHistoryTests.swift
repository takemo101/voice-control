import Foundation
import Testing
@testable import VCCore

/// 音声入力の履歴：残す日数・上限・検索・削除・自分だけが読める権限。**文は、テスト用の作り物**（実際の発話は、使わない）。
@Suite struct DictationHistoryTests {
    /// 時計を動かせる、テスト用の履歴。
    private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_800_000_000) }
    private func make() throws -> (DictationHistory, Clock, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-history-\(UUID().uuidString)")
        let clock = Clock()
        return (DictationHistory(file: directory.appendingPathComponent("history.jsonl"), now: { clock.date }), clock, directory)
    }

    @Test func entriesComeBackNewestFirstAndSearchIgnoresCase() throws {
        let (history, clock, directory) = try make(); defer { try? FileManager.default.removeItem(at: directory) }
        try history.append("First sample sentence", days: 7); clock.date += 60
        try history.append("二つ目のサンプル", days: 7); clock.date += 60
        try history.append("third SAMPLE", days: 7)
        #expect(history.entries().map(\.text) == ["third SAMPLE", "二つ目のサンプル", "First sample sentence"])
        #expect(history.entries(matching: "sample").map(\.text) == ["third SAMPLE", "First sample sentence"])
        #expect(history.entries(matching: "サンプル").map(\.text) == ["二つ目のサンプル"])
        #expect(history.entries(matching: "   ").count == 3)   // 空の検索は、すべて
    }

    @Test func entriesOlderThanTheRetentionAreDroppedWhenAddingAndWhenPruning() throws {
        let (history, clock, directory) = try make(); defer { try? FileManager.default.removeItem(at: directory) }
        try history.append("old one", days: 7)
        clock.date += 8 * 86_400
        try history.append("new one", days: 7)   // 追加のとき、8 日前のものが消える
        #expect(history.entries().map(\.text) == ["new one"])
        clock.date += 3 * 86_400
        try history.prune(days: 2)               // 日数を縮めたとき
        #expect(history.entries().isEmpty)
        #expect(DictationHistory.days(setting: nil) == 7 && DictationHistory.days(setting: 0) == 1 && DictationHistory.days(setting: 9999) == 365)
    }

    @Test func theCountIsCappedAndDeletingOneOrAllWorks() throws {
        let (history, clock, directory) = try make(); defer { try? FileManager.default.removeItem(at: directory) }
        for i in 0..<(DictationHistory.maxEntries + 5) { try history.append("entry \(i)", days: 7); clock.date += 1 }
        let all = history.entries()
        #expect(all.count == DictationHistory.maxEntries && all.first?.text == "entry \(DictationHistory.maxEntries + 4)")   // 古いほうが、消える
        try history.delete(id: all[0].id)
        #expect(history.entries().count == DictationHistory.maxEntries - 1)
        try history.clear()
        #expect(history.entries().isEmpty)
        try history.clear()   // 何もなくても、失敗しない
    }

    @Test func theFileIsReadableOnlyByTheOwnerAndABrokenLineIsSkipped() throws {
        let (history, _, directory) = try make(); defer { try? FileManager.default.removeItem(at: directory) }
        try history.append("kept", days: 7)
        let file = directory.appendingPathComponent("history.jsonl")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600 && directoryMode == 0o700)
        var broken = try Data(contentsOf: file); broken.append(Data("{ this is not json\n".utf8)); try broken.write(to: file)
        #expect(history.entries().map(\.text) == ["kept"])   // 壊れた行は、読み飛ばす
        try history.append("after", days: 7)
        #expect(history.entries().map(\.text).sorted() == ["after", "kept"])
    }

    @Test func recentDictationsKeepTheLastFiveWithoutDuplicates() {
        let recent = RecentDictations()
        #expect(recent.last == nil)
        for text in ["a", "b", "c", "d", "e", "f"] { recent.add(text) }
        #expect(recent.recent == ["f", "e", "d", "c", "b"])      // 5 件まで
        recent.add("c")
        #expect(recent.recent == ["c", "f", "e", "d", "b"])      // 同じ文は、先頭へ（重ねない）
        recent.add("")                                           // 空は、足さない
        #expect(recent.last == "c")
        recent.clear(); #expect(recent.recent.isEmpty)
    }
}
