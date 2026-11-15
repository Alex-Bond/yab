import Foundation

/// Identity of one read on one already connected helper. Never an engine URL.
public struct OriginalPDFBinding: Sendable, Equatable {
    public let tab: String, profile: String, call: String
    public init(tab: String, profile: String, call: String) {
        self.tab = tab; self.profile = profile; self.call = call
    }
}
/// Metadata identity of the original loaded native plugin. It is not an export
/// lease, an address guess, or a continuous promise that the bytes remain live.
public struct OriginalPDFPresenceIdentity: Sendable, Equatable {
    public let browserID: Int, size: Int
    public let rootDocument: String, rootFrameID: String
    public let pdfDocument: String, pdfFrameID: String
    public let listener: String, pluginSource: String

    private static func integer(_ value: JSONValue?, maximum: Double) throws -> Int {
        guard let n = value?.number, n.isFinite, n > 0, n <= maximum,
              n.rounded(.towardZero) == n else {
            throw YabCoreError.protocolViolation("Malformed original PDF presence integer")
        }
        return Int(n)
    }
    init(native: [String: JSONValue]) throws {
        browserID = try Self.integer(native["browserId"], maximum: Double(Int32.max))
        size = try Self.integer(native["size"], maximum: 64 * 1024 * 1024)
        func text(_ key: String) throws -> String {
            guard let s = native[key]?.string, !s.isEmpty, s.utf8.count <= 256 else {
                throw YabCoreError.protocolViolation("Malformed original PDF presence identity")
            }
            return s
        }
        rootDocument = try text("rootDocument"); rootFrameID = try text("rootFrameId")
        pdfDocument = try text("pdfDocument"); pdfFrameID = try text("pdfFrameId")
        listener = try text("listener"); pluginSource = try text("pluginSource")
    }
    public func requireMatch(_ receipt: OriginalPDFReceipt) throws {
        guard try Self(native: receipt.native) == self else {
            throw YabCoreError.protocolViolation("Original PDF changed after native presence")
        }
    }
}

/// The helper generation maps to a captured local epoch only through the exact
/// observe RPC reply. The two counters must never be compared to each other.
public struct OriginalPDFPresenceAdmission: Sendable, Equatable {
    public let documentGeneration: Int, browserID: Int
    public init(_ reply: JSONValue) throws {
        guard reply["observing"] == .bool(true),
              let d = reply["documentGeneration"].number, d.isFinite, d >= 0,
              d <= 9_007_199_254_740_991, d.rounded(.towardZero) == d,
              let b = reply["nativeBrowserId"].number, b.isFinite, b > 0,
              b <= Double(Int32.max), b.rounded(.towardZero) == b else {
            throw YabCoreError.protocolViolation("Original PDF observation lacks native admission")
        }
        documentGeneration = Int(d); browserID = Int(b)
    }
    public func matches(_ report: OriginalPDFPresenceReport) -> Bool {
        documentGeneration == report.documentGeneration && browserID == report.browserID
    }
}

public struct OriginalPDFPresenceReport: Sendable, Equatable {
    public let documentGeneration: Int, browserID: Int
    public let identity: OriginalPDFPresenceIdentity?
    public init(_ packet: JSONValue, tab: String, profile: String) throws {
        guard packet["tab"] == .string(tab), packet["profile"] == .string(profile),
              let d = packet["documentGeneration"].number, d.isFinite, d >= 0,
              d <= 9_007_199_254_740_991, d.rounded(.towardZero) == d,
              let n = packet["native"].object,
              n["version"] == .number(1), n["kind"] == .string("originalLoadedPDFPresence"),
              n["operation"] == .string("presence"),
              let status = n["status"]?.string, ["ready", "unavailable", "unknown"].contains(status),
              n["available"] == .bool(status == "ready"), n["complete"] == .bool(false),
              n["loadedAtMetadataAck"] == .bool(status == "ready"),
              let b = n["browserId"]?.number, b.isFinite, b > 0,
              b <= Double(Int32.max), b.rounded(.towardZero) == b else {
            throw YabCoreError.protocolViolation("Malformed original PDF presence report")
        }
        for key in ["generation", "rootDocument", "rootFrameId"] {
            guard let s = n[key]?.string, !s.isEmpty, s.utf8.count <= 256 else {
                throw YabCoreError.protocolViolation("Original PDF presence has no native document")
            }
        }
        for key in ["request", "source", "pdfDocument", "pdfFrameId", "listener", "pluginSource"] {
            if let value = n[key] {
                guard let s = value.string, s.utf8.count <= 256 else {
                    throw YabCoreError.protocolViolation("Malformed original PDF presence field")
                }
            }
        }
        guard n["source"] == nil || n["source"] == .string("") else {
            throw YabCoreError.protocolViolation("Presence cannot supply a native export lease")
        }
        if status == "ready" {
            guard let request = n["request"]?.string, !request.isEmpty else {
                throw YabCoreError.protocolViolation("Native PDF presence request is absent")
            }
            identity = try OriginalPDFPresenceIdentity(native: n)
        } else {
            if let size = n["size"] {
                guard let count = size.number, count.isFinite, count >= 0,
                      count <= 64 * 1024 * 1024, count.rounded(.towardZero) == count else {
                    throw YabCoreError.protocolViolation("Malformed unavailable PDF size")
                }
            }
            identity = nil
        }
        documentGeneration = Int(d); browserID = Int(b)
    }
}

public struct OriginalPDFReceipt: Sendable, Equatable {
    public let binding: OriginalPDFBinding
    public let lease: String, source: String
    public let size: Int
    fileprivate let native: [String: JSONValue]
    public init(_ reply: JSONValue, binding: OriginalPDFBinding, operation: String,
                previous: OriginalPDFReceipt? = nil) throws {
        func fail() -> YabCoreError { .protocolViolation("Original PDF ownership or native ACK mismatch") }
        guard ["state", "export"].contains(operation),
              reply["tab"] == .string(binding.tab), reply["profile"] == .string(binding.profile),
              reply["call"] == .string(binding.call), reply["nativeAcknowledged"] == .bool(true),
              let lease = reply["lease"].string, !lease.isEmpty, lease.utf8.count <= 256,
              let native = reply["native"].object,
              native["version"] == .number(1), native["kind"] == .string("originalLoadedPDF"),
              native["operation"] == .string(operation), native["status"] == .string("ready"),
              native["available"] == .bool(true), native["complete"] == .bool(operation == "export"),
              let browser = native["browserId"]?.number, browser.isFinite, browser > 0,
              browser.rounded(.towardZero) == browser, browser <= Double(Int32.max),
              let count = native["size"]?.number, count.isFinite, count > 0,
              count.rounded(.towardZero) == count, count <= 64 * 1024 * 1024 else { throw fail() }
        for key in ["request", "source", "rootDocument", "rootFrameId", "pdfDocument", "pdfFrameId", "listener", "pluginSource"] {
            guard let value = native[key]?.string, !value.isEmpty, value.utf8.count <= 256 else { throw fail() }
        }
        if let previous {
            guard operation == "export", previous.binding == binding, previous.lease == lease else { throw fail() }
            for key in ["browserId", "size", "source", "rootDocument", "rootFrameId", "pdfDocument", "pdfFrameId", "listener", "pluginSource"] {
                guard native[key] == previous.native[key] else { throw fail() }
            }
            guard native["request"] != previous.native["request"] else { throw fail() }
        }
        self.binding = binding; self.lease = lease; self.source = native["source"]!.string!
        self.size = Int(count); self.native = native
    }
}

/// Only finish() publishes bytes. Incomplete, replayed or foreign chunks throw.
public struct OriginalPDFAccumulator: Sendable {
    private let receipt: OriginalPDFReceipt
    private var bytes = Data()
    public private(set) var complete = false
    public var byteCount: Int { bytes.count }
    public init(receipt: OriginalPDFReceipt) { self.receipt = receipt }
    public mutating func append(_ reply: JSONValue) throws {
        let owner = try OriginalPDFReceipt(reply, binding: receipt.binding, operation: "export")
        guard !complete, owner == receipt, reply["size"] == .number(Double(receipt.size)),
              reply["offset"] == .number(Double(bytes.count)), reply["base64Encoded"] == .bool(true),
              let text = reply["data"].string, text.utf8.count <= 262_144,
              let chunk = Data(base64Encoded: text), !chunk.isEmpty, chunk.count <= 196_608,
              chunk.count <= receipt.size - bytes.count,
              reply["eof"] == .bool(bytes.count + chunk.count == receipt.size) else {
            throw YabCoreError.protocolViolation("Original PDF stream is incomplete, foreign or out of order")
        }
        bytes.append(chunk); complete = bytes.count == receipt.size
    }
    public func finish() throws -> Data {
        guard complete, bytes.count == receipt.size else {
            throw YabCoreError.protocolViolation("Original PDF stream ended before the expected whole buffer")
        }
        return bytes
    }
}

extension YabCoreClient {
    /// Uses this exact connection only. A caller guard must retain its original
    /// remote/profile/document epoch. No generic evaluate/print/refetch fallback.
    public func originalPDFData(binding: OriginalPDFBinding,
                                expectedPresence: OriginalPDFPresenceIdentity? = nil,
                                isCurrent: @escaping @Sendable () async -> Bool) async throws -> Data {
        guard !binding.tab.isEmpty, binding.tab.utf8.count <= 256,
              !binding.profile.isEmpty, binding.profile.utf8.count <= 100,
              !binding.call.isEmpty, binding.call.utf8.count <= 128,
              nativeHooks["nativeOriginalPDF"] == .bool(true),
              nativeHooks["nativeOriginalPDFVersion"] == .number(1), await isCurrent() else {
            throw YabCoreError.remote("Original native PDF bytes are unavailable on this endpoint")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        func remaining(_ maximum: TimeInterval) -> TimeInterval {
            min(maximum, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
        }
        let owner: [String: JSONValue] = ["tab": .string(binding.tab), "profile": .string(binding.profile), "call": .string(binding.call)]
        defer {
            // Lost/late state replies may not have delivered a lease. Retire by
            // the original call on this original actor, never by reconnecting.
            Task { [self] in _ = try? await request("page.originalPDF.cancel", params: owner, timeout: 5) }
        }
        try Task.checkCancellation()
        let started = try await request("page.originalPDF.state", params: owner, timeout: remaining(10))
        guard ProcessInfo.processInfo.systemUptime < deadline, await isCurrent() else { throw CancellationError() }
        let source = try OriginalPDFReceipt(started, binding: binding, operation: "state")
        try expectedPresence?.requireMatch(source)
        var export = owner; export["lease"] = .string(source.lease); export["source"] = .string(source.source)
        try Task.checkCancellation()
        let ready = try await request("page.originalPDF.export", params: export, timeout: remaining(15))
        guard ProcessInfo.processInfo.systemUptime < deadline, await isCurrent() else { throw CancellationError() }
        let exported = try OriginalPDFReceipt(ready, binding: binding, operation: "export", previous: source)
        var result = OriginalPDFAccumulator(receipt: exported)
        let read = owner.merging(["lease": .string(exported.lease)]) { _, value in value }
        while !result.complete {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline, await isCurrent() else { throw CancellationError() }
            let part = try await request("page.originalPDF.read", params: read, timeout: remaining(10))
            guard ProcessInfo.processInfo.systemUptime < deadline, await isCurrent() else { throw CancellationError() }
            try result.append(part)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, await isCurrent() else { throw CancellationError() }
        return try result.finish()
    }
}
