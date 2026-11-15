import Foundation
import Darwin
import Testing
@testable import YabCoreClient

/// Controlled stamp + actual socket/client adapter tests. The wire fixture is
/// NOT a CEF helper and creates no native owner or positive peer witness.
struct ChromiumNativeOriginalPeerBindingTests {
    private func stamp() -> NativePeerIdentity.LaunchStamp {
        .init(pid: 123, parent: 122, uid: getuid(), sec: 1000, usec: 1, executable: "/owned/YabCore", argv: String(repeating: "a", count: 64), boot: "01234567-89AB-4CDE-8123-456789ABCDEF")
    }
    private func evidence() -> NativePeerIdentity.Evidence {
        .init(pid: 123, parent: 122, uid: getuid(), startSec: 1000, startUsec: 1, executable: "/owned/YabCore", argvSHA256: String(repeating: "a", count: 64),
              bootSession: "01234567-89AB-4CDE-8123-456789ABCDEF", auditSHA256: String(repeating: "b", count: 64), codeIdentifier: "controlled", codeUnique: String(repeating: "c", count: 40))
    }
    @Test func originalLaunchStampMustMatchEveryKernelField() {
        let peer = evidence(), original = stamp()
        #expect(NativePeerIdentity.LaunchWitness.matches(peer, original))
        for changed in [
            NativePeerIdentity.LaunchStamp(pid: 124, parent: original.parent, uid: original.uid, sec: original.sec, usec: original.usec, executable: original.executable, argv: original.argv, boot: original.boot),
            .init(pid: original.pid, parent: 121, uid: original.uid, sec: original.sec, usec: original.usec, executable: original.executable, argv: original.argv, boot: original.boot),
            .init(pid: original.pid, parent: original.parent, uid: original.uid, sec: original.sec, usec: 2, executable: original.executable, argv: original.argv, boot: original.boot),
            .init(pid: original.pid, parent: original.parent, uid: original.uid, sec: original.sec, usec: original.usec, executable: "/other", argv: original.argv, boot: original.boot),
            .init(pid: original.pid, parent: original.parent, uid: original.uid, sec: original.sec, usec: original.usec, executable: original.executable, argv: String(repeating: "b", count: 64), boot: original.boot),
            .init(pid: original.pid, parent: original.parent, uid: original.uid, sec: original.sec, usec: original.usec, executable: original.executable, argv: original.argv, boot: "11234567-89AB-4CDE-8123-456789ABCDEF")
        ] { #expect(!NativePeerIdentity.LaunchWitness.matches(peer, changed)) }
    }
    @Test func helloPIDLabelsCannotReplaceActualPeerBirth() {
        let peer = evidence(), source = NativeOriginalPeerSource(evidence: peer, connection: "actual-local-connection")
        var hello: [String: JSONValue] = ["helperPID": .number(123), "helperBirthSec": .string("1000"), "helperBirthUsec": .number(1), "connection": .string("original-helper-connection"), "helperOwner": .string("original-owner")]
        #expect(YabCoreClient.sameHelperHello(hello, source: source)) // Diagnostic matcher, no counterpart value exists.
        hello["helperBirthUsec"] = .number(2)
        #expect(!YabCoreClient.sameHelperHello(hello, source: source))
        hello["helperBirthUsec"] = .bool(true)
        #expect(!YabCoreClient.sameHelperHello(hello, source: source))
    }
    @Test func missingOriginalWitnessPreservesOrdinaryWireButBlocksTypedAndRawGroups() async throws {
        let server = try WireFixture(); defer { server.close() }
        let core = try await YabCoreClient.connect(path: server.path)
        let ordinary = try await core.request("probe.ordinary")
        #expect(ordinary["ordinary"] == .bool(true))
        #expect(await core.nativeHooks["nativeMediaSession"] == .bool(true))
        #expect(await core.nativeHooks["nativeGroupApprovals"] == .bool(false))
        #expect(await core.nativeHooks["nativeGroupSources"] == .bool(false))
        #expect(await core.nativeHooks["nativeGroupSourcesVersion"] == .number(0))
        #expect(await core.originalPeerSource() == .unavailable)
        let member = try #require(NativeGroupApprovalMember(tab: "controlled", profile: "controlled", document: "controlled"))
        let command = try #require(NativeGroupApprovalCommand.reserve(members: [member], coordinator: member.tab))
        #expect(await core.nativeGroupApproval(command) == .unavailable)
        var refused = false
        do { _ = try await core.request("switch.group.native", params: command.parameters) } catch { refused = true }
        #expect(refused && server.methods == ["hello", "probe.ordinary"])
        // Wire helper claims every source flag, but has no retained actual
        // signed original launch/counterpart. It cannot write even intent WAL.
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("source-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let journal = try NativeSwitchJournal(directory: parent.appendingPathComponent("owned"))
        let intent = NativeSwitchJournal.Intent(id: UUID(), peer: evidence(), connection: "controlled",
            members: [.init(tab: "controlled", profile: "controlled", document: "controlled", browser: 1)],
            target: .chromium, settingsBaselineSHA256: String(repeating: "a", count: 64), privacy: .persistentVerified)
        guard case .stored(let initial) = await journal.create(intent) else { Issue.record("Controlled journal did not initialize"); return }
        let sourceResult = await core.recordOriginalGroupSources(journal: journal, cursor: initial.cursor, coordinator: "controlled")
        if case .unavailable = sourceResult {} else { Issue.record("Fabricated wire flags enabled original sources") }
        #expect(await journal.load(intent.id) == .stored(initial))
        #expect(server.methods == ["hello", "probe.ordinary"])
        await core.disconnect()
        #expect(await core.originalPeerSource() == .unknown)
    }
    @Test func nonexistentConfiguredExecutableCannotCreatePreparedWitness() {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/nonexistent-owned-test-helper"); child.arguments = []
        #expect(NativePeerIdentity.prepareLaunch(child) == nil)
    }
}

private final class WireFixture: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let lock = NSLock()
    private let worker = DispatchGroup()
    private var stopping = false
    private var listener: Int32 = -1, accepted: Int32 = -1
    private var seen: [String] = []
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peer-" + UUID().uuidString.prefix(10))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("wire").path
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { try? FileManager.default.removeItem(at: directory); throw Failure.setup }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { try? FileManager.default.removeItem(at: directory); throw Failure.setup }
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0, chmod(path, 0o600) == 0, listen(listener, 1) == 0 else { _ = Darwin.close(listener); listener = -1; try? FileManager.default.removeItem(at: directory); throw Failure.setup }
        worker.enter()
        DispatchQueue(label: "owned.peer.fixture").async { [self] in defer { worker.leave() }; serve() }
    }
    private enum Failure: Error { case setup }
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    func close() {
        lock.lock(); stopping = true; let active = accepted; lock.unlock()
        if active >= 0 { _ = Darwin.shutdown(active, SHUT_RDWR) }
        // Do not close/reuse descriptors while the original worker can access
        // them. A timeout is a failed owned cleanup, never a test success.
        guard worker.wait(timeout: .now() + 6) == .success else { Issue.record("Owned wire fixture worker did not stop"); return }
        lock.lock(); let old = accepted, oldListener = listener; accepted = -1; listener = -1; lock.unlock()
        if old >= 0 { _ = Darwin.close(old) }
        if oldListener >= 0 { _ = Darwin.close(oldListener) }
        try? FileManager.default.removeItem(at: directory)
    }
    private func serve() {
        lock.lock(); let ownedListener = listener; lock.unlock()
        var waiting = pollfd(fd: ownedListener, events: Int16(POLLIN), revents: 0)
        guard !stopped, poll(&waiting, 1, 5000) > 0, !stopped else { return }
        let fd = Darwin.accept(ownedListener, nil, nil)
        guard fd >= 0 else { return }
        var yes: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        lock.lock(); accepted = fd; lock.unlock()
        var input = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while !stopped {
            var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&readable, 1, 5000) > 0, !stopped else { return }
            let count = Darwin.read(fd, &buffer, buffer.count); guard count > 0 else { return }
            input.append(contentsOf: buffer.prefix(count))
            while let end = input.firstIndex(of: 10) {
                let line = Data(input[..<end]); input.removeSubrange(...end)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = request["id"] as? String, let method = request["method"] as? String else { return }
                lock.lock(); seen.append(method); lock.unlock()
                let hooks: [String: Any] = ["nativeMediaSession": true, "nativeGroupApprovals": true, "nativeGroupApprovalVersion": 1, "nativeGroupOwnerVersion": 1, "nativeGroupSnapshots": true, "nativeGroupSnapshotVersion": 1, "nativeGroupSources": true, "nativeGroupSourcesVersion": 1]
                let result: [String: Any] = method == "hello" ? ["version": 1, "eventFlow": 1, "nativeHooks": hooks] : ["ordinary": true]
                guard let response = try? JSONSerialization.data(withJSONObject: ["v": 1, "id": id, "result": result]) else { return }
                var bytes = response; bytes.append(10)
                var offset = 0
                while offset < bytes.count {
                    let wrote = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count-offset) }
                    guard wrote > 0 else { return }; offset += wrote
                }
            }
            guard input.count <= 65536 else { return }
        }
    }
}
