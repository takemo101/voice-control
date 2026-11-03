import Foundation
import Testing
@testable import VCSpeech

/// 取りやめたときの録音の後始末。取りやめの合図そのものは `VCCore`、コマンドを止める側は `VCSkill` のテスト（同じ名前のスイート）。
@Suite struct CancellationTests {
    @Test func discardedRecordingLeavesNoFileAndNoError() throws {
        let session = RecordingSession()
        session.discard()   // 録音していなくても、何も起きない
        #expect(try session.stop() == nil)
    }
}
