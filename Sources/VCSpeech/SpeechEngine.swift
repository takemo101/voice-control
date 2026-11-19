import Foundation
import VCCore

/// 使う音声認識（選んだもの）を、`Transcribing` にして渡す。**認識の前に、声があるか確かめる**（`GatedTranscriber`）ので、どの認識でも、無音は、空になる。
/// ダウンロードしたモデルは、`make` で開く（開けなければ、ここで失敗する）。**プロセスを終える前に、`close()`**（開いたまま `exit` すると、ggml の後始末が abort する）。
public struct SpeechEngine: Sendable {
    public let choice: SpeechChoice
    public let transcriber: Transcribing
    private let closer: @Sendable () -> Void

    public func close() { closer() }

    public enum Failure: Error, CustomStringConvertible {
        /// ダウンロードしていない。**黙って Apple に切り替えない**（理由と手順を示す）。
        case modelMissing(SpeechModel)
        case cannotOpen(String)
        public var description: String {
            switch self {
            case let .modelMissing(model): return tr("音声認識モデル \(model.name) を取得していません（設定ウィンドウ > モデル。約 \(model.file.bytes / 1_048_576) MB）。Apple に戻すなら 設定ウィンドウ > モデル > 音声認識")
            case let .cannotOpen(reason): return tr("音声認識のモデルを開けません（\(reason)）")
            }
        }
    }

    /// `language`：認識する言語（設定 `sttLanguage`）。Apple は `Locale`、ダウンロードしたモデルは、言語の符号で渡す。
    public static func make(_ choice: SpeechChoice, language: SpeechLanguage = .ja) throws -> SpeechEngine {
        switch choice {
        case .apple:
            return SpeechEngine(choice: choice, transcriber: GatedTranscriber(FileTranscriber(locale: Locale(identifier: language.resolved.bcp47))), closer: {})
        case let .local(model):
            guard model.isInstalled else { throw Failure.modelMissing(model) }
            let local: LocalTranscriber
            do { local = try LocalTranscriber(modelFile: model.fileURL, language: language.whisperCode) } catch { throw Failure.cannotOpen("\(error)") }
            return SpeechEngine(choice: choice, transcriber: GatedTranscriber(local), closer: { local.close() })
        }
    }
}
