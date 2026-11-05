import Foundation
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 設定の読み取りで、壊れていることを、1 回だけ知らせる。
/// `@unchecked Sendable` の理由：可変な状態（`shown`）は、すべて `lock` で守る。
/// Tiny-Jev を、最初に使うときに 1 回だけ読み込んで、持つ。
/// `@unchecked Sendable` の理由：可変な状態（`jev`）は、すべて `lock` で守る。
final class LazyJev: @unchecked Sendable {
    private let lock = NSLock()
    private var jev: TinyJev?
    init(_ jev: TinyJev?) { self.jev = jev }

    func get(load: () -> TinyJev) -> OptionScorer? {
        lock.lock(); defer { lock.unlock() }
        if jev == nil { jev = load() }
        return jev
    }
}

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
    private let settingsWarning = SettingsWarning()

    init(options: CommonOptions) {
        self.options = options
        var gate = Gate()
        if let floor = options.floor { gate.floor = floor }
        self.gate = gate
    }

    /// スキルを実行するモデル（`--engine`）。書き方が違えば、理由を示して終わる。既定は、Apple のモデル。
    var engine: Engine {
        guard let text = options.engine else { return .apple }
        do { return try Engine.parse(text) } catch { fail("\(error)") }
    }

    /// 使う音声認識：`--stt` → 設定（`vc stt set`）→ 既定（Apple）。名前が違えば、理由を示して終わる。
    var speechChoice: SpeechChoice {
        if let text = options.stt {
            switch SpeechChoice.parse(text) {
            case let .success(choice): return choice
            case let .failure(error): fail("--stt \(text): \(error)")
            }
        }
        switch currentSettings().speechChoice {
        case let .success(choice): return choice
        case let .failure(error): fail("settings.json の stt: \(error)（vc stt set で直す）")
        }
    }

    /// 使う音声認識を開く（ダウンロードしたモデルは、ここで読み込む）。開けなければ、理由を示して終わる。
    func makeSpeechEngine() -> SpeechEngine {
        do { return try SpeechEngine.make(speechChoice) } catch { fail("\(error)") }
    }

    /// モデルの場所：--model、環境変数 VC_MODEL_DIR、~/.voice-control/models/tiny-jev-0.6b（`vc model download` の置き場所）、./models/tiny-jev-0.6b（開発用）の順に、最初に tokenizer.json があるもの。
    /// 使うときまで解決しない（`vc skills` などは、モデルがなくても動く）。
    func resolveModelDir() -> URL {
        guard let found = findModelDirectory() else { fail("モデルが見つかりません（探した場所: \(modelCandidates.joined(separator: ", "))）。vc model download で取得") }
        return found
    }

    /// モデルを探す場所（resolveModelDir の順）。
    var modelCandidates: [String] {
        [options.model, ProcessInfo.processInfo.environment["VC_MODEL_DIR"], TinyJevModel.defaultDirectory.path, "models/tiny-jev-0.6b"].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// 見つかったモデルの場所。なければ `nil`（`fail` しない：`vc doctor` が、状態を調べるのに使う）。
    func findModelDirectory() -> URL? {
        modelCandidates.first { FileManager.default.fileExists(atPath: $0 + "/tokenizer.json") }.map { URL(fileURLWithPath: $0) }
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

    /// Tiny-Jev を、使うときまで読み込まない形で渡す（`vc pick`・`vc find` を使うスキルが、選ぶのに使う）。`loaded` があれば、それを使う（読み込み済みを、読み直さない）。
    func scorerProvider(loaded: TinyJev? = nil) -> @Sendable () -> OptionScorer? {
        let holder = LazyJev(loaded)
        return { holder.get { loadJev() } }
    }

    /// 設定の読み取り：読めなければ（壊れている）、警告を 1 回だけ出して、空の設定（信頼したプロジェクトは、なし）で続ける。書き込みは、`Settings.save` が、壊れたファイルを上書きせずに失敗する。
    func currentSettings() -> Settings {
        let (settings, problem) = Settings.loadOrDefault()
        if let problem { settingsWarning.once(problem) }
        return settings
    }
}
