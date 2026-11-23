import Foundation
import Testing
import VCCore

/// 設定（`Settings`）の既定値と、保存して読み直したときの値。
@Suite struct SettingsTests {
    /// 音声認識の選択（`stt`）：なければ nil（既定の Apple）。保存して読み直せる。項目のない古いファイルも読める。
    @Test func theSpeechChoiceIsOptionalAndPersistent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = try Settings.load(from: file)
        #expect(settings.stt == nil)
        settings.stt = "whisper-large-v3-turbo"
        try settings.save(to: file)
        #expect(try Settings.load(from: file).stt == "whisper-large-v3-turbo")
        try Data(#"{"hotkey":"shift"}"#.utf8).write(to: file)
        #expect(try Settings.load(from: file).stt == nil)
    }

    /// 録音中の消音（`mute`）と、実行するモデル（`engine`）：なければ nil（既定）。`mute` は、false も区別して保存する。
    @Test func muteAndEngineAreOptionalAndPersistent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = try Settings.load(from: file)
        #expect(settings.mute == nil && settings.engine == nil)
        settings.mute = false
        settings.engine = "ollama:qwen3.5:4b"
        try settings.save(to: file)
        let reloaded = try Settings.load(from: file)
        #expect(reloaded.mute == false && reloaded.engine == "ollama:qwen3.5:4b")
    }

    /// つなぎ言葉の除去：なければ nil（既定：消さない・既定の辞書）。**空の辞書（`[]`）は、nil（既定の辞書）と区別して**保存する。
    @Test func fillerSettingsAreOptionalAndAnEmptyListIsNotTheDefault() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = try Settings.load(from: file)
        #expect(settings.removeFillers == nil && settings.fillers == nil)
        settings.removeFillers = true
        settings.fillers = []
        try settings.save(to: file)
        let reloaded = try Settings.load(from: file)
        #expect(reloaded.removeFillers == true && reloaded.fillers == [])
        try Data(#"{"hotkey":"shift"}"#.utf8).write(to: file)
        let old = try Settings.load(from: file)
        #expect(old.removeFillers == nil && old.fillers == nil)
    }

    @Test func skillsAreEnabledByDefaultAndTogglePersistently() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = try Settings.load(from: file)
        #expect(settings.isEnabled("a"))
        settings.setEnabled("b", false); settings.setEnabled("a", false)
        try settings.save(to: file)
        let reloaded = try Settings.load(from: file)
        #expect(!reloaded.isEnabled("a") && !reloaded.isEnabled("b") && reloaded.isEnabled("c"))
        var again = reloaded
        again.setEnabled("a", true)
        #expect(again.isEnabled("a") && !again.isEnabled("b"))
    }

    /// 会話のモデル（`chatModels`：エージェント名 → モデル）：なければ nil。保存して読み直せる。値に、記号（`[low]`）が入っていても、そのまま。
    @Test func chatModelsAreOptionalPerAgentAndPersistent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = try Settings.load(from: file)
        #expect(settings.chatModels == nil)
        settings.chatModels = ["codex": "gpt-6.1-sol[low]", "claude": "haiku"]
        try settings.save(to: file)
        #expect(try Settings.load(from: file).chatModels == ["codex": "gpt-6.1-sol[low]", "claude": "haiku"])
        try Data(#"{"hotkey":"shift"}"#.utf8).write(to: file)
        #expect(try Settings.load(from: file).chatModels == nil)
    }

    /// 種類（Ollama・OpenAI 互換）ごとの、最後に使った入力・LAN の許可：保存して、読み直せる。古いファイルでは、なし。
    @Test func eachEngineKindKeepsItsLastInputAndTheLANApprovalIsStored() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-settings-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var settings = try Settings.load(from: file)
        #expect(settings.engineRests == nil && settings.engineApproved == nil)
        settings.engine = "openai:m@8000"
        settings.engineRests = ["ollama": "qwen3.5:4b@192.168.1.5:11434", "openai": "m@8000"]
        settings.engineApproved = "192.168.1.5:11434"
        try settings.save(to: file)
        let reloaded = try Settings.load(from: file)
        #expect(reloaded.engineRests == ["ollama": "qwen3.5:4b@192.168.1.5:11434", "openai": "m@8000"] && reloaded.engineApproved == "192.168.1.5:11434")
        try Data(#"{"hotkey":"shift"}"#.utf8).write(to: file)
        #expect(try Settings.load(from: file).engineRests == nil)
    }
}
