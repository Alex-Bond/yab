import Testing
import Foundation
import YabCoreClient

/// Controlled wire receipts only. No native source/runtime acceptance claim.
struct ChromiumOriginalPDFTests {
    private func rejects(_ body: () throws -> Void, _ reason: String = "") {
        do { try body(); Issue.record("Expected original PDF rejection: \(reason)") } catch {}
    }
    private let binding = OriginalPDFBinding(tab: "tab-A", profile: "profile-A", call: "call-A")
    private func packet(_ operation: String, size: Int = 7) -> JSONValue {
        .object(["tab": .string(binding.tab), "profile": .string(binding.profile), "call": .string(binding.call),
            "lease": .string("lease-A"), "nativeAcknowledged": .bool(true), "native": .object([
                "version": .number(1), "kind": .string("originalLoadedPDF"), "operation": .string(operation),
                "status": .string("ready"), "available": .bool(true), "complete": .bool(operation == "export"),
                "browserId": .number(4), "size": .number(Double(size)), "request": .string("native-"+operation),
                "source": .string("source-A"), "rootDocument": .string("root-A"), "rootFrameId": .string("root-frame"),
                "pdfDocument": .string("pdf-A"), "pdfFrameId": .string("pdf-frame"), "listener": .string("listener-A"), "pluginSource": .string("plugin-A")])])
    }
    private func native(_ packet: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        var outer = packet.object!, body = outer["native"]!.object!; body[key] = value; outer["native"] = .object(body); return .object(outer)
    }
    private func outer(_ packet: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        var body = packet.object!; body[key] = value; return .object(body)
    }
    private func chunk(_ bytes: Data, offset: Int, eof: Bool, size: Int = 7) -> JSONValue {
        var value = packet("export",size: size).object!
        value.merge(["size": .number(Double(size)), "offset": .number(Double(offset)), "eof": .bool(eof),
                     "base64Encoded": .bool(true), "data": .string(bytes.base64EncodedString())]) { _, new in new }
        return .object(value)
    }
    @Test func testWholeOriginalBytesRequireMatchingStateAndExportACK() throws {
        let state = try OriginalPDFReceipt(packet("state"), binding: binding, operation: "state")
        let exported = try OriginalPDFReceipt(packet("export"), binding: binding, operation: "export", previous: state)
        var stream = OriginalPDFAccumulator(receipt: exported)
        try stream.append(chunk(Data([1,2,3]),offset: 0,eof: false))
        rejects({ _ = try stream.finish() })
        try stream.append(chunk(Data([4,5,6,7]),offset: 3,eof: true))
        #expect(try stream.finish() == Data([1,2,3,4,5,6,7]))
    }
    @Test func testStateCannotClaimCompleteBytes() {
        rejects({ _ = try OriginalPDFReceipt(native(packet("state"),"complete",.bool(true)),binding: binding,operation: "state") })
    }
    @Test func testExportRejectsEveryRetiredNativeOwnerStamp() throws {
        let state = try OriginalPDFReceipt(packet("state"),binding: binding,operation: "state")
        for key in ["source","rootDocument","rootFrameId","pdfDocument","pdfFrameId","listener","pluginSource"] {
            rejects({ _ = try OriginalPDFReceipt(native(packet("export"),key,.string("replacement")),binding: binding,operation: "export",previous: state) }, key)
        }
        for key in ["browserId","size"] {
            rejects({ _ = try OriginalPDFReceipt(native(packet("export"),key,.number(9)),binding: binding,operation: "export",previous: state) }, key)
        }
    }
    @Test func testForeignHelperOwnerAndMissingNativeACKReject() {
        for key in ["tab","profile","call"] {
            rejects({ _ = try OriginalPDFReceipt(outer(packet("state"),key,.string("foreign")),binding: binding,operation: "state") }, key)
        }
        rejects({ _ = try OriginalPDFReceipt(outer(packet("state"),"nativeAcknowledged",.bool(false)),binding: binding,operation: "state") })
    }
    @Test func testMalformedVersionSizeAndUnknownAreNotData() {
        for value in [JSONValue.bool(true),.number(0),.number(7.5),.number(Double.infinity),.number(64*1024*1024+1)] {
            rejects({ _ = try OriginalPDFReceipt(native(packet("state"),"size",value),binding: binding,operation: "state") })
        }
        rejects({ _ = try OriginalPDFReceipt(native(packet("state"),"version",.bool(true)),binding: binding,operation: "state") })
        rejects({ _ = try OriginalPDFReceipt(native(packet("state"),"status",.string("unknown")),binding: binding,operation: "state") })
    }
    @Test func testOldStateRequestCannotImpersonateExportACK() throws {
        let state = try OriginalPDFReceipt(packet("state"),binding: binding,operation: "state")
        rejects({ _ = try OriginalPDFReceipt(native(packet("export"),"request",.string("native-state")),binding: binding,operation: "export",previous: state) })
        rejects({ _ = try OriginalPDFReceipt(outer(packet("export"),"lease",.string("different")),binding: binding,operation: "export",previous: state) })
    }
    @Test func testReplayWrongOffsetAndEarlyEOFNeverPublishPrefix() throws {
        let receipt = try OriginalPDFReceipt(packet("export"),binding: binding,operation: "export")
        var stream = OriginalPDFAccumulator(receipt: receipt)
        try stream.append(chunk(Data([1,2,3]),offset: 0,eof: false))
        rejects({ _ = try stream.append(chunk(Data([1,2,3]),offset: 0,eof: false)) })
        rejects({ _ = try stream.append(chunk(Data([4]),offset: 3,eof: true)) })
        rejects({ _ = try stream.finish() })
    }
    @Test func testForeignChunkAndFalseFinalCannotComplete() throws {
        let receipt = try OriginalPDFReceipt(packet("export"),binding: binding,operation: "export")
        var stream = OriginalPDFAccumulator(receipt: receipt)
        rejects({ _ = try stream.append(native(chunk(Data([1,2,3,4,5,6,7]),offset: 0,eof: true),"pdfDocument",.string("replacement"))) })
        rejects({ _ = try stream.append(chunk(Data([1,2,3,4,5,6,7]),offset: 0,eof: false)) })
        rejects({ _ = try stream.finish() })
    }
    @Test func testOversizedAndNonBase64ChunkReject() throws {
        let receipt = try OriginalPDFReceipt(packet("export",size: 196_609),binding: binding,operation: "export")
        var stream = OriginalPDFAccumulator(receipt: receipt)
        rejects({ _ = try stream.append(chunk(Data(repeating: 1,count: 196_609),offset: 0,eof: true,size: 196_609)) })
        rejects({ _ = try stream.append(outer(chunk(Data([1]),offset: 0,eof: false,size: 196_609),"data",.string("not base64"))) })
        rejects({ _ = try stream.finish() })
    }
}
