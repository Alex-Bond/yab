import Foundation

/// What a field holds: anything JSON can say. Fields stay this loose so a
/// record written by a newer Yab, with fields this one has never heard of,
/// passes through untouched.
public enum Value: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Value])
    case object([String: Value])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [Value]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: Value]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }
}

extension Value: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([Value].self) { self = .array(a) }
        else { self = .object(try c.decode([String: Value].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension Value: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral s: String) { self = .string(s) }
    public init(booleanLiteral b: Bool) { self = .bool(b) }
    public init(floatLiteral n: Double) { self = .number(n) }
    public init(integerLiteral n: Int) { self = .number(Double(n)) }
    public init(nilLiteral: ()) { self = .null }
}

public extension Value {
    /// Optional Swift values as fields: nil is `.null`.
    init(_ s: String?) { self = s.map { .string($0) } ?? .null }
    init(_ b: Bool?) { self = b.map { .bool($0) } ?? .null }
    init(_ n: Double?) { self = n.map { .number($0) } ?? .null }
    init(_ n: Int?) { self = n.map { .number(Double($0)) } ?? .null }

    /// Any Codable value as a field, through JSON.
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(Value.self, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
