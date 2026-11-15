import XCTest
import Foundation
import Darwin
@testable import YabCoreClient

private final class Stub: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "YabCoreClientTests.stub")
    init(mode: String) throws {
        path = "/tmp/yc-test-\(UUID().uuidString).sock"
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let descriptor = listener
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(listener, 1) == 0 else { throw YabCoreError.transport("Stub bind failed") }
        queue.async { [self] in
            let peer = Darwin.accept(listener, nil, nil)
            guard peer >= 0 else { return }
            defer { Darwin.close(peer) }
            var yes: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            var input = Data(), held: String?
            var buffer = [UInt8](repeating: 0, count: 4096)
            func send(_ object: [String: Any]) {
                guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
                // Deliberately fragment every response, including Unicode, across reads.
                for part in [data.prefix(7), data.dropFirst(7), Data([10])[...]] {
                    part.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            let n = Darwin.write(peer, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if n <= 0 { return }; offset += n
                        }
                    }
                    usleep(10_000)
                }
            }
            while true {
                let n = Darwin.read(peer, &buffer, buffer.count)
                if n <= 0 { return }
                input.append(contentsOf: buffer.prefix(n))
                while let newline = input.firstIndex(of: 10) {
                    let data = Data(input[..<newline]); input.removeSubrange(...newline)
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    if object?["flow"] != nil { continue } // event credit: the wire's own frame
                    guard let request = object, let id = request["id"] as? String else { return }
                    if request["method"] as? String == "hello" {
                        send(["v": 1, "id": id, "result": ["version": 1, "eventFlow": 1]])
                    } else if mode.hasPrefix("readiness") {
                        let params = request["params"] as! [String: Any]
                        send(["v": 1, "id": id, "result": ["ready": true, "devToolsReady": true,
                            "hasDocument": false, "proof": "mainFrameDocument", "frame": "main",
                            "context": 1, "generation": 2,
                            "profile": mode == "readiness-mismatch" ? "foreign" : params["profile"]!,
                            "url": params["url"] ?? "about:blank"]])
                    } else if mode == "envelope" {
                        send(["v": 1, "id": id, "result": request["timeout"] ?? NSNull()])
                    } else if mode == "big" {
                        // A page's picture: megabytes in one frame, then a small one.
                        let size = (request["params"] as? [String: Any])?["size"] as? Int ?? 1
                        send(["v": 1, "id": id, "result": String(repeating: "a", count: size)])
                    } else if mode == "disconnect" { return }
                    else if mode == "timeout" { continue }
                    else if mode == "reorder" {
                        if let first = held {
                            send(["v": 1, "event": "page.state", "params": ["tab": "test", "title": "日本語"]])
                            send(["v": 1, "id": id, "result": request["method"]!])
                            send(["v": 1, "id": first, "result": "first"])
                            held = nil
                        } else { held = id }
                    }
                }
            }
        }
    }
    deinit { Darwin.close(listener); unlink(path) }
}
final class ConnectionTests: XCTestCase {
    func testWheelSubmissionDoesNotWaitForThePreviousNativeReply() async throws {
        // This server deliberately withholds the first reply until the second
        // request arrives. Waiting for the first reply would deadlock input.
        let stub = try Stub(mode: "reorder")
        let client = try await YabCoreClient.connect(path: stub.path)
        let submitted = expectation(description: "First wheel queued")
        let first = Task { try await client.sendInput(["kind": .string("wheel"), "deltaY": .number(1)],
                                                     submitted: { submitted.fulfill() }) }
        await fulfillment(of: [submitted], timeout: 2)
        let second = Task { try await client.sendInput(["kind": .string("wheel"), "deltaY": .number(2)], submitted: {}) }
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, .string("first"))
        XCTAssertEqual(b, .string("input.send"))
        await client.disconnect()
    }

    func testInputSubmissionUnblocksOnPreflightFailure() async throws {
        let stub = try Stub(mode: "timeout")
        let client = try await YabCoreClient.connect(path: stub.path)
        await client.disconnect()
        let submitted = expectation(description: "Failed submission released")
        do {
            _ = try await client.sendInput(["kind": .string("wheel")], submitted: { submitted.fulfill() })
            XCTFail("Disconnected input succeeded")
        } catch { }
        await fulfillment(of: [submitted], timeout: 2)
    }

    func testSubmittedInputRemainsCancellableWithoutASecondSubmissionCallback() async throws {
        let stub = try Stub(mode: "timeout")
        let client = try await YabCoreClient.connect(path: stub.path)
        let submitted = expectation(description: "Input queued once")
        submitted.assertForOverFulfill = true
        let task = Task { try await client.sendInput(["kind": .string("wheel")], submitted: { submitted.fulfill() }) }
        await fulfillment(of: [submitted], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled input succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await client.disconnect()
    }
    func testVerifiedDocumentDoesNotWaitForStaleCEFHasDocument() async throws {
        let stub = try Stub(mode: "readiness")
        let client = try await YabCoreClient.connect(path: stub.path)
        let proof = try await client.waitForDocument(tab: "test", profile: "space", url: "https://example.test/")
        XCTAssertEqual(proof["ready"], .bool(true))
        XCTAssertEqual(proof["hasDocument"], .bool(false))
        await client.disconnect()
    }
    func testReadinessRejectsAnotherProfile() async throws {
        let stub = try Stub(mode: "readiness-mismatch")
        let client = try await YabCoreClient.connect(path: stub.path)
        do { _ = try await client.waitForDocument(tab: "test", profile: "space"); XCTFail("Foreign proof accepted") }
        catch { XCTAssertTrue(String(describing: error).contains("target")) }
        await client.disconnect()
    }
    func testReadinessCancellationStopsPendingProof() async throws {
        let stub = try Stub(mode: "timeout")
        let client = try await YabCoreClient.connect(path: stub.path)
        let task = Task { try await client.waitForDocument(tab: "test", profile: "space") }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled readiness accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        await client.disconnect()
    }
    func testFragmentedInterleavedEventsAndOutOfOrderResponses() async throws {
        let stub = try Stub(mode: "reorder")
        let client = try await YabCoreClient.connect(path: stub.path)
        let first = Task { try await client.request("first") }
        // Force the first call into the socket before sending the second.
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task { try await client.request("second") }
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, .string("first")); XCTAssertEqual(b, .string("second"))
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.params["title"], .string("日本語"))
        await client.disconnect()
    }
    /// A frame of megabytes read in many pieces arrives whole, and the frames
    /// around it in order: the newline is looked for only in what is new.
    func testMegabyteFramesArriveWholeAcrossManyReads() async throws {
        let stub = try Stub(mode: "big")
        let client = try await YabCoreClient.connect(path: stub.path)
        for size in [3_000_000, 5, 1_500_000, 1] {
            let value = try await client.request("big", params: ["size": .number(Double(size))], timeout: 30)
            XCTAssertEqual(value.string?.count, size)
            XCTAssertEqual(value.string?.allSatisfy { $0 == "a" }, true)
        }
        await client.disconnect()
    }
    func testRequestsPastTheLimitWaitTheirTurn() async throws {
        let stub = try Stub(mode: "timeout")
        let client = try await YabCoreClient.connect(path: stub.path)
        let said = await withTaskGroup(of: String.self) { group in
            for _ in 0..<300 {
                group.addTask {
                    do { _ = try await client.request("held", timeout: 0.1); return "answered" }
                    catch { return String(describing: error) }
                }
            }
            return await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(said, ["YabCore request timed out"])
        await client.disconnect()
    }
    func testDisconnectReleasesRequestsWaitingTheirTurn() async throws {
        let stub = try Stub(mode: "timeout")
        let client = try await YabCoreClient.connect(path: stub.path)
        let tasks = (0..<200).map { _ in Task { try await client.request("held", timeout: 30) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.disconnect()
        for task in tasks {
            do { _ = try await task.value; XCTFail("Disconnect was swallowed") }
            catch { XCTAssertTrue(error is YabCoreError) }
        }
    }
    /// R2256 (code 4): a page's load waited 20 s on a busy helper and failed. What a
    /// load waits on now waits as long as the helper takes, and says so.
    func testPageLoadRequestsTellTheHelperTheirAllowance() async throws {
        let stub = try Stub(mode: "envelope")
        let client = try await YabCoreClient.connect(path: stub.path)
        let navigate = try await client.request("tab.navigate", params: ["tab": .string("t")])
        XCTAssertEqual(navigate, .number(YabCoreClient.loadAllowance))
        let other = try await client.request("page.snapshot")
        XCTAssertEqual(other, .null, "other requests keep the helper's own 20 s")
        await client.disconnect()
    }
    func testSlowHelperDoesNotFailAPageLoad() async throws {
        let stub = try Stub(mode: "timeout")
        let client = try await YabCoreClient.connect(path: stub.path)
        let load = Task { try await client.request("tab.create", params: [:], timeout: 0.1) }
        let other = Task { try await client.request("page.snapshot", params: [:], timeout: 0.1) }
        do { _ = try await other.value; XCTFail("Unanswered request answered") }
        catch { XCTAssertEqual(String(describing: error), "YabCore request timed out") }
        try await Task.sleep(nanoseconds: 400_000_000)
        await client.disconnect()
        do { _ = try await load.value; XCTFail("Unanswered load answered") }
        catch { XCTAssertEqual(String(describing: error), "YabCore disconnected", "only the helper's end ends a load's wait") }
    }
    func testDisconnectFailsPendingCall() async throws {
        let stub = try Stub(mode: "disconnect")
        let client = try await YabCoreClient.connect(path: stub.path)
        do { _ = try await client.request("pending"); XCTFail("Disconnect was swallowed") }
        catch { XCTAssertTrue(error is YabCoreError) }
    }
    func testTimeoutAndCancellationResumeOnce() async throws {
        let stub = try Stub(mode: "timeout")
        let client = try await YabCoreClient.connect(path: stub.path)
        do { _ = try await client.request("timeout", timeout: 0.05); XCTFail("Timeout was swallowed") }
        catch { XCTAssertEqual(String(describing: error), "YabCore request timed out") }
        let task = Task { try await client.request("cancel") }
        try await Task.sleep(nanoseconds: 20_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation was swallowed") }
        catch { XCTAssertTrue(error is CancellationError) }
        await client.disconnect()
    }
}
