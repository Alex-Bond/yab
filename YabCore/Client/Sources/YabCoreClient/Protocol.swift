import Foundation

/// Only JSON values cross the process boundary. Undefined script results become null.
public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
}
public struct YabCoreEvent: Sendable, Equatable {
    public let name: String
    public let params: [String: JSONValue]
    public init(name: String, params: [String: JSONValue]) { self.name = name; self.params = params }
    public var tab: String? { params["tab"]?.string }
}
public enum YabCoreError: Error, LocalizedError, Sendable, CustomStringConvertible {
    case disconnected, timeout, protocolViolation(String), remote(String), transport(String)
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .disconnected: return "YabCore disconnected"
        case .timeout: return "YabCore request timed out"
        case .protocolViolation(let s), .remote(let s), .transport(let s): return s
        }
    }
}
struct Request: Encodable {
    let v = 1
    let id: String
    let method: String
    let params: [String: JSONValue]
    /// How long this request may take, said to the helper too: without it
    /// the helper answers "Operation timed out" at 20 s from its arrival.
    var timeout: Double? = nil
}
struct Envelope: Decodable {
    let v: Int
    let id: String?
    let event: String?
    let params: [String: JSONValue]?
    let result: JSONValue?
    let error: JSONValue?
}
