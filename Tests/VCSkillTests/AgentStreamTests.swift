import Foundation
import Testing
@testable import VCSkill

/// 外のエージェントの実行中の出来事（JSON の行）から、いま何をしているかと、答えを読み取る。**行は、実際に動かして得たものを、短くしたもの**（`ls` を実行させた）。
@Suite struct AgentStreamTests {
    private func events(_ agent: ChatAgent, _ lines: [String]) -> [AgentStream.Event] {
        var stream = AgentStream(agent: agent)
        return lines.flatMap { stream.feed(Data(($0 + "\n").utf8)) }
    }

    @Test func claudeToolUseBecomesAnActivityAndTheResultIsTheFinalAnswer() {
        let lines = [
            #"{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"..."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls","description":"List files"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"サイバーセキュリティ ニュース"}}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"note.txt"}"#,
        ]
        #expect(events(.claude, lines) == [.activity(.run("ls")), .activity(.search("サイバーセキュリティ ニュース")), .final("note.txt")])
    }

    @Test func claudeErrorsAreReported() {
        #expect(events(.claude, [#"{"type":"result","subtype":"error","is_error":true,"result":"Not logged in"}"#]) == [.failure("Not logged in")])
    }

    @Test func codexCommandsAreShownWithoutTheShellWrapper() {
        let lines = [
            #"{"type":"thread.started","thread_id":"x"}"#,
            #"{"type":"item.started","item":{"type":"command_execution","command":"/bin/zsh -lc ls"}}"#,
            #"{"type":"item.completed","item":{"type":"command_execution","command":"/bin/zsh -lc ls"}}"#,
            #"{"type":"item.started","item":{"type":"command_execution","command":"/bin/zsh -lc 'cat note.txt'"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"done"}}"#,
        ]
        #expect(events(.codex, lines) == [.activity(.run("ls")), .activity(.run("cat note.txt"))])   // 始まったときだけ（終わりは、重ねない）
    }

    @Test func grokToolCallsAndTextChunksAreRead() {
        let lines = [
            #"{"type":"available_commands","tools":["run_terminal_command"]}"#,
            #"{"type":"tool_call","toolName":"run_terminal_command","rawInput":{"command":"ls -1","description":"List"}}"#,
            #"{"type":"tool_call_update","status":"completed"}"#,
            #"{"type":"tool_call","toolName":"web_fetch","rawInput":{"url":"https://example.com/news"}}"#,
            #"{"type":"text","data":"フォル"}"#,
            #"{"type":"text","data":"ダ"}"#,
            #"{"type":"end","stopReason":"end_turn"}"#,
        ]
        #expect(events(.grok, lines) == [.activity(.run("ls -1")), .activity(.fetch("https://example.com/news")), .text("フォル"), .text("ダ")])
    }

    @Test func grokReadAndListUseTheirOwnFieldNames() {
        let lines = [
            #"{"type":"tool_call","toolName":"list_dir","rawInput":{"target_directory":"/tmp/work"}}"#,
            #"{"type":"tool_call","toolName":"read_file","rawInput":{"target_file":"/tmp/work/note.txt"}}"#,
        ]
        #expect(events(.grok, lines) == [.activity(.list("/tmp/work")), .activity(.read("/tmp/work/note.txt"))])
    }

    @Test func agyToolStepsStartOnlyAndTheResultIsTheAnswer() {
        let lines = [
            #"{"event":"init","init":{"model":"m","tools":["read_file"]}}"#,
            #"{"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"read_file","tool_info":{"name":"read_file","parameters":{"Path":"/tmp/work/note.txt"}}}}"#,
            #"{"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"tool","tool_name":"read_file","tool_info":{"name":"read_file","parameters":{"Path":"/tmp/work/note.txt"}}}}"#,
            #"{"event":"step_update","step_update":{"step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"write_file","tool_info":{"name":"write_file","parameters":{"Path":"/tmp/work/done.txt"}}}}"#,
            #"{"event":"result","result":{"status":"SUCCESS","response":"読みました"}}"#,
        ]
        #expect(events(.agy, lines) == [.activity(.read("/tmp/work/note.txt")), .activity(.write("/tmp/work/done.txt")), .final("読みました")])
        #expect(events(.agy, [#"{"event":"result","result":{"status":"ERROR"}}"#]) == [.failure("ERROR")])
    }

    @Test func opencodeToolUseAndTheLastTextAreRead() {
        let lines = [
            #"{"type":"step_start","part":{"type":"step-start"}}"#,
            #"{"type":"tool_use","part":{"tool":"read","state":{"status":"completed","input":{"path":"note.txt"}}}}"#,
            #"{"type":"tool_use","part":{"tool":"patch","state":{"status":"completed","input":{"patchText":"*** Begin Patch\n*** Add File: done.txt\n+確認済み\n*** End Patch"}}}}"#,
            #"{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"ls -la"}}}}"#,
            #"{"type":"text","part":{"text":"作成しました"}}"#,
        ]
        #expect(events(.opencode, lines) == [.activity(.read("note.txt")), .activity(.write("done.txt")), .activity(.run("ls -la")), .final("作成しました")])
    }

    @Test func piToolExecutionsAndTheLastAssistantMessageAreRead() {
        let lines = [
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"x"}}"#,
            #"{"type":"tool_execution_start","toolName":"read","args":{"path":"note.txt","offset":1}}"#,
            #"{"type":"tool_execution_start","toolName":"write","args":{"path":"done.txt","content":"確認済み"}}"#,
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","name":"write"}]}}"#,
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"作成しました。"}]}}"#,
            #"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"依頼"}]}}"#,
        ]
        #expect(events(.pi, lines) == [.activity(.read("note.txt")), .activity(.write("done.txt")), .final("作成しました。")])
    }

    @Test func linesSplitAcrossChunksAreJoinedAndGarbageIsIgnored() {
        var stream = AgentStream(agent: .claude)
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/a.txt"}}]}}"# + "\n"
        let bytes = Array(line.utf8)
        #expect(stream.feed(Data(bytes[0..<30])).isEmpty)                         // 途中：まだ、決まらない
        #expect(stream.feed(Data(bytes[30...])) == [.activity(.read("/tmp/a.txt"))])
        #expect(stream.feed(Data("これは JSON ではない\n{壊れた\n".utf8)).isEmpty)   // 読めない行は、読み捨てる
    }

    @Test func longCommandsAreClippedAndOtherAgentsShowNothing() {
        let long = String(repeating: "a", count: 200)
        let shown = events(.claude, [#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"\#(long)"}}]}}"#])
        #expect(shown.count == 1 && { if case let .activity(activity) = shown[0] { return activity.detail.count <= 90 } else { return false } }())
        #expect(events(.apple, [#"{"type":"assistant"}"#]).isEmpty)
    }
}
