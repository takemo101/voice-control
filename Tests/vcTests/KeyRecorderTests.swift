import Testing
import VCSpeech
@testable import vc

/// 設定画面の、キーの記録：押されたキーから、設定の書き方を作る（画面・イベントなし）。
@Suite struct KeyRecorderTests {
    // 仮想キーコード：左 Shift 56・右 Shift 60・左 Command 55・右 Command 54・左 Option 58・左 Control 59・S 1・Space 49・F5 96・A 0・Esc 53・Caps Lock(未対応) 57
    private func run(_ inputs: [KeyRecorder.Input]) -> [KeyRecorder.Outcome] {
        var recorder = KeyRecorder()
        return inputs.map { recorder.handle($0) }
    }

    @Test func aModifierPressedAndReleasedAloneIsAHold() {
        #expect(run([.modifier(code: 56, down: true), .modifier(code: 56, down: false)]).last == .recorded("shift"))
        #expect(run([.modifier(code: 59, down: true), .modifier(code: 59, down: false)]).last == .recorded("ctrl"))
    }

    @Test func aRightSideModifierAloneMeansTheRightSideOnly() {
        #expect(run([.modifier(code: 60, down: true), .modifier(code: 60, down: false)]).last == .recorded("rshift"))
        #expect(run([.modifier(code: 54, down: true), .modifier(code: 54, down: false)]).last == .recorded("rcmd"))
    }

    @Test func severalModifiersHeldTogetherAreOneHoldInTheCanonicalOrder() {
        let outcomes = run([.modifier(code: 55, down: true), .modifier(code: 59, down: true), .modifier(code: 55, down: false), .modifier(code: 59, down: false)])
        #expect(outcomes.last == .recorded("ctrl+cmd"))
        #expect(outcomes.dropLast().allSatisfy { $0 == .waiting })   // 全部が離れるまで、決めない
    }

    @Test func modifiersPlusAKeyAreACombinationAndTheHoldIsNotAlsoRecorded() {
        var recorder = KeyRecorder()
        _ = recorder.handle(.modifier(code: 59, down: true))
        _ = recorder.handle(.modifier(code: 58, down: true))
        #expect(recorder.handle(.key(code: 49, modifiers: [.control, .option])) == .recorded("ctrl+opt+space"))
        // 組み合わせのあと、修飾キーを離しても、長押しとして、もう一度は、決まらない
        _ = recorder.handle(.modifier(code: 59, down: false))
        #expect(recorder.handle(.modifier(code: 58, down: false)) == .waiting)
        #expect(run([.key(code: 1, modifiers: [.control, .option])]).last == .recorded("ctrl+opt+s"))
    }

    @Test func aPlainKeyNeedsAModifierExceptFunctionKeys() {
        #expect(run([.key(code: 0, modifiers: [])]).last == .rejected("修飾キー（⌃ ⌥ ⇧ ⌘）と一緒に押してください（F キーだけは、単独で使えます）"))
        #expect(run([.key(code: 96, modifiers: [])]).last == .recorded("f5"))
    }

    @Test func escapeCancelsAndUnknownKeysAreRejected() {
        #expect(run([.key(code: 53, modifiers: [])]).last == .cancelled)
        #expect(run([.key(code: 50, modifiers: [.command])]).last == .rejected("このキーは、使えません"))   // 対応していないキー
        #expect(run([.modifier(code: 57, down: true), .modifier(code: 57, down: false)]).last == .waiting)       // Caps Lock などは、修飾キーとして扱わない
    }

    @Test func everythingRecordedCanBeParsedBackIntoTheSameSpec() {
        for text in ["shift", "rshift", "rcmd", "ctrl+cmd", "ctrl+opt+space", "ctrl+opt+s", "f5"] {
            guard case let .success(spec) = HotKeySpec.parse(text) else { Issue.record("\(text) を、読めない"); continue }
            #expect(spec.description == text)   // 記録した文字は、そのまま、正規の書き方
        }
    }
}
