import Foundation
import Testing
@testable import Fast

struct DevNetAgentCopyTests {
    private func row(_ resource: NetResource) -> NetRow {
        NetRow(id: NetRow.ids(resource.id, hop: nil), resource: resource, hop: nil, from: nil)
    }

    @Test func longDocumentAndRequestBodiesKeepTheirMiddle() {
        var resource = NetResource(id: 1)
        resource.url = "https://example.test/form"
        resource.type = "document"
        resource.method = "POST"
        resource.finished = true
        let padding = String(repeating: "я🙂", count: 140_000)
        let sent = padding + "REQUEST_MIDDLE" + padding
        let received = "<html>" + padding + "RESPONSE_MIDDLE" + padding + "</html>"
        resource.postData = sent
        let report = NetCopy.agent([row(resource)], bodies: [1: NetBody(text: received, base64: false)], page: nil)
        let completeRequest = report.contains("Sent:\n" + sent + "\n")
        let completeResponse = report.contains("Got:\n" + received + "\n")
        #expect(completeRequest)
        #expect(completeResponse)
        #expect(!report.contains("KB cut"))
    }

    @Test func everyStackFrameKeepsItsAddressAndColumn() {
        var resource = NetResource(id: 1)
        resource.initiator.stack = (1...50).map {
            NetFrameLine(function: "frame\($0)", url: "https://example.test/src/part\($0)/app.js", line: $0, column: $0 + 1)
        }
        let report = NetCopy.agent([row(resource)], bodies: [:], page: nil)
        for frame in resource.initiator.stack {
            #expect(report.contains("\(frame.function) · \(frame.url):\(frame.line):\(frame.column)"))
        }
    }

    @Test func binaryResponseHasItsEncodingAndAllBytes() {
        let encoded = Data((0..<20_000).map { UInt8($0 % 256) }).base64EncodedString()
        let report = NetCopy.agent([row(NetResource(id: 1))], bodies: [1: NetBody(text: encoded, base64: true)], page: nil)
        let completeBinary = report.contains("Got (base64):\n" + encoded + "\n")
        #expect(completeBinary)
    }

    @Test func missingFailedAndEmptyBodiesAreDistinguishable() {
        var resource = NetResource(id: 1)
        resource.finished = true
        let failed = NetCopy.agent([row(resource)], bodies: [1: NetBody(text: "", base64: false, error: "gone from WebKit")], page: nil)
        #expect(failed.contains("Response body unavailable: gone from WebKit"))
        let missing = NetCopy.agent([row(resource)], bodies: [:], page: nil)
        #expect(missing.contains("Response body unavailable."))
        let empty = NetCopy.agent([row(resource)], bodies: [1: NetBody(text: "", base64: false)], page: nil)
        #expect(empty.contains("Got:\n"))
        #expect(!empty.contains("unavailable"))
        resource.finished = false
        #expect(NetCopy.agent([row(resource)], bodies: [:], page: nil).contains("Response body pending."))
        resource.failed = true
        #expect(NetCopy.agent([row(resource)], bodies: [:], page: nil).contains("Response body unavailable."))
    }

    @Test func copyingManyDocumentsIncludesEverySuppliedBody() {
        let rows = (1...25).map { id -> NetRow in
            var resource = NetResource(id: id)
            resource.type = "document"
            resource.finished = true
            return row(resource)
        }
        let bodies = Dictionary(uniqueKeysWithValues: rows.map { ($0.resource.id, NetBody(text: "DOCUMENT_\($0.resource.id)_END", base64: false)) })
        let report = NetCopy.agent(rows, bodies: bodies, page: nil)
        for body in bodies.values { #expect(report.contains(body.text)) }
    }

    @Test func completeCopiesStillRemoveCredentials() {
        var resource = NetResource(id: 1)
        resource.url = "https://example.test/?token=private-value"
        resource.requestHeaders = [NetHeader(name: "Authorization", value: "Bearer private-value"), NetHeader(name: "Cookie", value: "sid=private-value")]
        resource.responseHeaders = [NetHeader(name: "Set-Cookie", value: "sid=private-value")]
        resource.postData = "key=sk-abcdefghijklmnopqrstuvwxyz"
        let report = NetCopy.agent([row(resource)], bodies: [:], page: nil)
        #expect(!report.contains("private-value"))
        #expect(!report.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        #expect(report.contains("Authorization: [removed]"))
        #expect(report.contains("Set-Cookie: [removed]"))
    }
}
