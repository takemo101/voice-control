import Foundation

/// スキルを実行するモデル。既定は、Apple のオンデバイスの言語モデル。`--engine ollama:<モデル>` で、自分の Mac の Ollama（ローカル）のモデルに替えられる。
/// スキルを選ぶ Tiny-Jev は、どちらでも同じ。
public enum Engine: Sendable, Equatable {
    case apple
    /// Ollama のモデル名（例：`qwen3.5:4b`）。通信先は、この Mac の Ollama だけ（`OllamaClient`）。
    case ollama(model: String)

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case invalidModel(String)
        case cloudModel(String)
        public var description: String {
            switch self {
            case .unknown(let s): return "エンジン「\(s)」は使えません（apple か、ollama:<モデル>。例：ollama:qwen3.5:4b）"
            case .invalidModel(let m): return "Ollama のモデル名「\(m)」が使えません（英数字・. _ : / - だけ）"
            case .cloudModel(let m): return "「\(m)」は、クラウドのモデルです。音声・画面の内容を、外へ出さないので、使えません"
            }
        }
    }

    /// `apple` か `ollama:<モデル>`（モデル名の中の `:` は、そのまま：`ollama:qwen3.5:4b`）。
    public static func parse(_ text: String) throws -> Engine {
        if text == "apple" { return .apple }
        guard text.hasPrefix("ollama:") else { throw ParseError.unknown(text) }
        let model = String(text.dropFirst("ollama:".count))
        guard model.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,100}$", options: .regularExpression) != nil else { throw ParseError.invalidModel(model) }
        // Ollama には、クラウドで動くモデル（名前に cloud が付く）がある。入力を外へ出さないので、ローカルのモデルだけ
        guard !model.lowercased().contains("cloud") else { throw ParseError.cloudModel(model) }
        return .ollama(model: model)
    }
}
