import Foundation
import VCCore
import VCDecision
import VCPCControl
import VCSkill

/// 設定の読み取りで、壊れていることを、1 回だけ知らせる。
final class SettingsWarning: @unchecked Sendable {
    private let lock = NSLock()
    private var shown = false
    func once(_ problem: Settings.Unreadable) {
        lock.lock(); defer { lock.unlock() }
        guard !shown else { return }
        shown = true
        eprint(Style.yellow("\(problem)"))
    }
}

/// 1 回の `vc` の起動で、コマンドが共有するもの。`main.swift` が 1 つ作って、コマンドへ渡す（グローバルの状態は持たない）。
/// 終了（`fail`・`usageError`）は、プロセスを終えるだけで、状態を持たないので、`Output.swift` の関数のまま。
struct CommandContext {
    let options: CommonOptions
    /// 確信度の下限（`--floor`）を反映したゲート。
    let gate: Gate
    /// 利用者が足したキー操作の定義（`vc plan`・`vc act` の候補）。
    let keyCatalog: KeyBindingCatalog.Loaded
    private let settingsWarning = SettingsWarning()

    init(options: CommonOptions, keyCatalog: KeyBindingCatalog.Loaded) {
        self.options = options
        var gate = Gate()
        if let floor = options.floor { gate.floor = floor }
        self.gate = gate
        self.keyCatalog = keyCatalog
    }

    /// キー操作の定義を読んで、作る。`--keys <dir>`、`VC_KEYS_DIR`、`./keys`、`~/.voice-control/keys` の、あるものを全部読む。
    /// 読めなかったものは、起動のたびに、標準エラーへ出す（どのコマンドでも）。
    static func make(options: CommonOptions, keysDirectory: String?) -> CommandContext {
        let support = VoiceControlHome.root.appendingPathComponent("keys").path
        let dirs = [keysDirectory, ProcessInfo.processInfo.environment["VC_KEYS_DIR"], "keys", support].compactMap { $0 }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = dirs.map { URL(fileURLWithPath: $0).standardizedFileURL }.filter { seen.insert($0.path).inserted }
        let loaded = KeyBindingCatalog.load(directories: unique)
        for p in loaded.problems { FileHandle.standardError.write(Data("skill: \(p)\n".utf8)) }
        return CommandContext(options: options, keyCatalog: loaded)
    }

    /// モデルの場所：--model、環境変数 VC_MODEL_DIR、~/.voice-control/models/tiny-jev-0.6b（`vc model download` の置き場所）、./models/tiny-jev-0.6b（開発用）の順に、最初に tokenizer.json があるもの。
    /// 使うときまで解決しない（`vc skills` などは、モデルがなくても動く）。
    func resolveModelDir() -> URL {
        let candidates = [options.model, ProcessInfo.processInfo.environment["VC_MODEL_DIR"], ModelStore.defaultDirectory().path, "models/tiny-jev-0.6b"].compactMap { $0 }.filter { !$0.isEmpty }
        let found = candidates.first { FileManager.default.fileExists(atPath: $0 + "/tokenizer.json") }
        guard let found else { fail("モデルが見つかりません（探した場所: \(candidates.joined(separator: ", "))）。vc model download で取得") }
        return URL(fileURLWithPath: found)
    }

    func loadJev() -> TinyJev {
        do {
            let t0 = Date()
            let jev = try TinyJev(directory: resolveModelDir(), length: options.length)
            _ = try jev.choose(state: "テスト", question: "テスト", options: ["a", "b"])  // グラフのコンパイルを、計測の外へ出す
            eprint(Style.dim(String(format: "model loaded %.1fs (length %d)", Date().timeIntervalSince(t0), options.length)))
            return jev
        } catch {
            fail("モデルを読めません: \(error)（vc model download で取得）")
        }
    }

    /// 設定の読み取り：読めなければ（壊れている）、警告を 1 回だけ出して、空の設定（信頼したプロジェクトは、なし）で続ける。書き込みは、`Settings.save` が、壊れたファイルを上書きせずに失敗する。
    func currentSettings() -> Settings {
        let (settings, problem) = Settings.loadOrDefault()
        if let problem { settingsWarning.once(problem) }
        return settings
    }
}
