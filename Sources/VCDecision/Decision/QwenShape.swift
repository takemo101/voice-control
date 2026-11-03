import Foundation

/// Qwen3 の decoder の形（`config.json` の値。固定した版のものを、ここに持つ）。
public struct QwenShape: Sendable, Equatable {
    public let hidden: Int
    public let layers: Int
    public let heads: Int
    public let kvHeads: Int
    public let headDim: Int
    public let intermediate: Int
    public let rmsEps: Float
    public let ropeTheta: Float
    /// 較正した温度（判断の頭の出力を割る）。
    public let temperature: Float

    public init(hidden: Int, layers: Int, heads: Int, kvHeads: Int, headDim: Int, intermediate: Int, rmsEps: Float, ropeTheta: Float, temperature: Float) {
        self.hidden = hidden
        self.layers = layers
        self.heads = heads
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.intermediate = intermediate
        self.rmsEps = rmsEps
        self.ropeTheta = ropeTheta
        self.temperature = temperature
    }
}
