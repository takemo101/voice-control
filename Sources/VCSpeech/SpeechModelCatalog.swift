import Foundation
import VCCore

/// ダウンロードして使える、音声認識のモデル 1 つ（GGUF。transcribe.cpp で動かす）。
public struct SpeechModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// 選ぶときの説明（特徴・ライセンス）。
    public let summary: String
    /// 取得の定義：**リポジトリ・版（commit）・ファイル名・バイト数・SHA-256 を固定**する。同じ名前のファイルが、あとから入れ替わっても、検証に通らない。
    public let spec: ModelSpec

    /// モデルのファイル（`~/.voice-control/models/<id>/<ファイル>`）。
    public var file: ModelFile { spec.files[0] }
    public var directory: URL { ModelStore.defaultDirectory(for: spec) }
    public var fileURL: URL { directory.appendingPathComponent(file.name) }
    public var isInstalled: Bool { ModelStore.isInstalled(spec, in: directory) }
}

/// 使えるモデルの一覧。**ライセンスが明確で、測って役に立ったものだけ**（Whisper：MIT）。
/// モデルは `handy-computer`（transcribe.cpp の作者）が、GGUF（Q8_0）へ変換して公開しているもの。
/// 測定（docs/verification.md「音声認識モデルの比較」）：Qwen3-ASR 0.6B は、Apple より誤りが多かったので、入れない。
public enum SpeechModelCatalog {
    public static let all: [SpeechModel] = [
        SpeechModel(
            id: "whisper-large-v3-turbo", name: "Whisper large-v3-turbo",
            summary: "雑音が軽いとき・英字の語に強い傾向（自作の合成音声での測定）。認識に 0.5 秒ほどかかる。MIT ライセンス。",
            spec: ModelSpec(
                name: "whisper-large-v3-turbo",
                baseURL: URL(string: "https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf/resolve/d222c9f621c1128299248f2ded4d8a1820519780")!,
                files: [ModelFile(name: "whisper-large-v3-turbo-Q8_0.gguf", bytes: 886_381_824, sha256: "d5e65f2b0828802ae2c231673d31982cebe3a778c95d9494a9f3efee6bd17448")]))
    ]

    public static func model(id: String) -> SpeechModel? { all.first { $0.id == id } }
}

/// 使う音声認識。Apple の `SpeechTranscriber`（既定）か、ダウンロードしたモデル。
public enum SpeechChoice: Sendable, Equatable {
    case apple
    case local(SpeechModel)

    /// 保存・CLI で使う名前。`apple`、またはモデルの ID。
    public var id: String {
        switch self {
        case .apple: return "apple"
        case let .local(model): return model.id
        }
    }

    public var title: String {
        switch self {
        case .apple: return "Apple（SpeechTranscriber）"
        case let .local(model): return model.name
        }
    }

    public struct Unknown: Error, CustomStringConvertible, Equatable {
        public let id: String
        public var description: String { "知らない音声認識: \(id)（apple・\(SpeechModelCatalog.all.map(\.id).joined(separator: "・"))）" }
    }

    /// 名前から選択を作る。知らない名前は、`Unknown`（黙って Apple にしない）。
    public static func parse(_ id: String) -> Result<SpeechChoice, Unknown> {
        if id == "apple" { return .success(.apple) }
        if let model = SpeechModelCatalog.model(id: id) { return .success(.local(model)) }
        return .failure(Unknown(id: id))
    }
}

extension Settings {
    /// 設定された音声認識。なければ Apple。設定の名前が知らないものなら、理由。
    public var speechChoice: Result<SpeechChoice, SpeechChoice.Unknown> {
        guard let stt else { return .success(.apple) }
        return SpeechChoice.parse(stt)
    }
}
