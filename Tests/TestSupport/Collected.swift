import Foundation

/// どのスレッドから足してもよい、値の入れ物（出力・出来事を集める）。
public final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Value] = []

    public init() {}

    public func add(_ value: Value) { lock.lock(); all.append(value); lock.unlock() }
    public var values: [Value] { lock.lock(); defer { lock.unlock() }; return all }
}

/// 端末の色の指定（端末で実行したときだけ付く）を取り除く。
public func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
