import Foundation

/// Tiny-Jev（選択肢から 1 つ選び、確率を返すだけのモデル）。
/// `QwenDecision` ほかの `Decision/` の 5 ファイルは、meeting-analyzer（`Sources/MeetingAnalyzerKit/Decision/`）から、そのまま複製した。
/// 複製の理由：meeting-analyzer の SwiftPM パッケージは、文字起こしの静的ライブラリ（`scripts/build-native.sh`）と FluidAudio を要求し、この試作には重い。
/// 版を固定した、取得とファイルの検証（SHA-256）は、`ModelStore`（`vc model download`）が担う。
public final class TinyJev: @unchecked Sendable {
    /// Tiny-Jev 0.6B の形（meeting-analyzer の `DecisionModelCatalog` と同じ値）。
    static let shape06 = QwenShape(hidden: 1024, layers: 28, heads: 16, kvHeads: 8, headDim: 128, intermediate: 3072, rmsEps: 1e-6, ropeTheta: 1_000_000, temperature: 0.95)

    /// 入力の長さ（トークン）。長いほど遅い（0.6B：512 で約 0.15 秒、1024 で約 0.3 秒、2048 で約 0.9 秒。meeting-analyzer の計測）。
    public let length: Int
    /// 選択肢の最大数（グラフの出力の幅）。
    public static let maxOptions = OptionMarkerPrompt.maxOptions

    private let prompt: OptionMarkerPrompt
    private let engine: QwenDecision
    private let lock = NSLock()

    /// `directory` に、`model.safetensors` と `tokenizer.json` がある前提。GPU のグラフのコンパイルで、数秒かかる。
    public init(directory: URL, length: Int = 1024) throws {
        let tokenizer = try BPETokenizer(tokenizerJSON: directory.appendingPathComponent("tokenizer.json"))
        guard let marker = tokenizer.tokenId("<opt>") else { throw DecisionModelError.unreadable("トークナイザに印（<opt>）がありません") }
        self.length = length
        prompt = OptionMarkerPrompt(encode: { try tokenizer.encode($0) }, optionTokenId: marker, maxLength: length)
        engine = try QwenDecision(shape: Self.shape06, weights: directory.appendingPathComponent("model.safetensors"), length: length)
    }

    /// `options` ごとの確率（合計 1）。`state` が長ければ、先頭の 7 割と末尾を残して切る。
    public func choose(state: String, question: String, options: [String]) throws -> [Double] {
        lock.lock(); defer { lock.unlock() }
        let rendered = try prompt.render(state: state, question: question, options: options)
        return try engine.probabilities(ids: rendered.ids, positions: rendered.positions)
    }

    /// 問いと選択肢だけの長さ（トークン）。`state` を入れる前。要素の説明の長さの見積りに使う。
    public func fixedLength(question: String, options: [String]) throws -> Int {
        try prompt.fixedLength(question: question, options: options)
    }
}
