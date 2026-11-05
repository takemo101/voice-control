import Foundation
import Testing
@testable import VCSpeech

/// 認識の時間の上限は、録音の長さで決める（短くても 10 秒は待つ。長い録音は、それに応じて）。
@Suite struct AnalysisTimeoutTests {
    @Test func theLimitFollowsTheRecordingLengthWithAFloor() {
        #expect(FileTranscriber.analysisTimeout(forSeconds: 0.5) == 10)
        #expect(FileTranscriber.analysisTimeout(forSeconds: 3) == 14)
        #expect(FileTranscriber.analysisTimeout(forSeconds: 30) == 95)
    }
}
