import Foundation

/// JSON の値（`Sendable`）。ACP（JSON-RPC）の、やり取りを、型なしで扱う（`JSONSerialization` の `Any` は、スレッドをまたげない）。
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let v as NSNumber:
            self = CFGetTypeID(v) == CFBooleanGetTypeID() ? .bool(v.boolValue) : .number(v.doubleValue)
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(v): return v
        case let .number(v): return v
        case let .string(v): return v
        case let .array(v): return v.map(\.any)
        case let .object(v): return v.mapValues(\.any)
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).map { JSONValue(any: $0) }
    }

    func serialized() -> Data? {
        try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(v) = self { return v[key] }
        return nil
    }

    var string: String? { if case let .string(v) = self { return v } else { return nil } }
    var int: Int? { if case let .number(v) = self { return Int(exactly: v) } else { return nil } }
    var bool: Bool? { if case let .bool(v) = self { return v } else { return nil } }
    var array: [JSONValue]? { if case let .array(v) = self { return v } else { return nil } }
}
