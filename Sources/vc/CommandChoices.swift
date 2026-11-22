import Foundation
import VCCore
import VCSkill
import VCSpeech

/// 起動できない理由（利用者に、そのまま見せる）。`page`：直せる設定のページ。メニューバーのアプリは、ダイアログに出して、そのページを開く（アプリは終わらない）。
struct StartupProblem: Error, CustomStringConvertible {
    let description: String
    let page: SettingsPage?
    init(_ text: String, page: SettingsPage? = nil) { description = text; self.page = page }
}

/// キーの設定（検査済み）。
struct ResolvedKeys {
    let listen: (spec: HotKeySpec, source: String)
    let dictate: (spec: HotKeySpec, source: String)?
    let chat: HotKeySpec?
    let shot: HotKeySpec?
    let pasteLast: HotKeySpec?
    let cycleSend: HotKeySpec?
}

/// 設定・引数から決まる、**使うもの**（スキルを実行するモデル・音声認識・会話のエージェント・キー）。書き間違いは、ここで一度だけ検査して、型にする。
struct ResolvedChoices {
    let engine: Engine
    let speech: SpeechChoice
    let sttLanguage: SpeechLanguage
    let chatAgent: ChatAgent
    let keys: ResolvedKeys
}

extension CommandContext {
    /// スキルを実行するモデル（`--engine` → 設定 → 既定の Apple のモデル）。
    func resolveEngine(settings: Settings) throws -> Engine {
        guard let text = options.engine ?? settings.engine else { return .apple }
        let fromSettings = options.engine == nil
        let engine: Engine
        do { engine = try Engine.parse(text) } catch {
            throw StartupProblem(fromSettings ? tr("settings.json の engine: \(error)（設定ウィンドウ > モデル > エンジン で直す）") : "\(error)", page: fromSettings ? .models : nil)
        }
        // **LAN のサーバーへは、音声・画面の内容が出る**：設定からは、利用者が、その場所を許可したときだけ（`--engine` は、その場の、明示の指定）
        if fromSettings, engine.talksOverLAN, settings.engineApproved?.lowercased() != engine.serverEndpoint {
            throw StartupProblem(tr("LAN のサーバー（\(engine.serverEndpoint ?? "")）へ、音声・画面の内容を送ることを、許可していません（設定ウィンドウ > モデル で、許可する）"), page: .models)
        }
        return engine
    }

    /// 使う音声認識（`--stt` → 設定 → 既定の Apple）。
    func resolveSpeechChoice(settings: Settings) throws -> SpeechChoice {
        if let text = options.stt {
            switch SpeechChoice.parse(text) {
            case let .success(choice): return choice
            case let .failure(error): throw StartupProblem("--stt \(text): \(error)")
            }
        }
        switch settings.speechChoice {
        case let .success(choice): return choice
        case let .failure(error): throw StartupProblem(tr("settings.json の stt: \(error)（設定ウィンドウ > モデル > 音声認識 で直す）"), page: .models)
        }
    }

    /// 音声認識の言語（設定 `sttLanguage`。なければ日本語）。
    func resolveSttLanguage(settings: Settings) throws -> SpeechLanguage {
        switch settings.recognitionLanguage {
        case let .success(language): return language
        case let .failure(error): throw StartupProblem(tr("settings.json の \(error)（設定ウィンドウ > 音声 で直す）"), page: .voice)
        }
    }

    /// 会話に使うエージェント（設定。なければ Apple）。
    func resolveChatAgent(settings: Settings) throws -> ChatAgent {
        guard let text = settings.chatAgent else { return .apple }
        guard let agent = ChatAgent.parse(text) else {
            let names = ChatAgent.allCases.map(\.rawValue).joined(separator: "・")   // l10n-skip
            throw StartupProblem(tr("settings.json の chatAgent「\(text)」は、使えません（\(names)）。設定ウィンドウ > 会話 で直す"), page: .chat)
        }
        return agent
    }

    /// エンジン・音声認識・会話のエージェント・キーを、**設定を 1 回だけ読んで**検査する。メニューバーのアプリは、これを通した文脈を使う：書き間違いで、アプリが終わらない（端末の `vc` は、必要なものだけを、使うときに検査して、`fail` で終わる）。
    func resolvingChoices() throws -> CommandContext {
        let settings = currentSettings()
        var resolved = self
        resolved.choices = ResolvedChoices(engine: try resolveEngine(settings: settings), speech: try resolveSpeechChoice(settings: settings), sttLanguage: try resolveSttLanguage(settings: settings), chatAgent: try resolveChatAgent(settings: settings), keys: try resolveKeys(settings: settings))
        return resolved
    }
}
