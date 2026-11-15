import Foundation
import Darwin
import Security
import CryptoKit

// One original inherited AF_UNIX endpoint supplies parent audit identity before
// CEF. No secret/authority bytes are read or written through standard input.
fileprivate final class NativeParentBootstrap: @unchecked Sendable {
    let parent: Int32, child: FileHandle
    var childClosed = false
    private let controlLock = NSLock()
    private var controlConsumed = false
    private init(parent: Int32, child: FileHandle) { self.parent = parent; self.child = child }
    static func create() -> NativeParentBootstrap? {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        guard fcntl(pair[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(pair[1], F_SETFD, FD_CLOEXEC) == 0 else {
            _ = Darwin.close(pair[0]); _ = Darwin.close(pair[1]); return nil
        }
        var yes: Int32 = 1
        guard setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
            _ = Darwin.close(pair[0]); _ = Darwin.close(pair[1]); return nil
        }
        return NativeParentBootstrap(parent: pair[0], child: FileHandle(fileDescriptor: pair[1], closeOnDealloc: false))
    }
    func closeChildParentCopy() -> Bool {
        guard !childClosed else { return false }; childClosed = true
        do { try child.close(); return true } catch { return false } // Never retry a possibly reused FD.
    }
    func releaseDiagnosticDeadline() -> Bool {
        controlLock.lock(); defer { controlLock.unlock() }
        guard !controlConsumed else { return false }; controlConsumed = true
        var control: UInt8 = 0x44 // Fault gate only; never an authentication byte.
        return Darwin.send(parent, &control, 1, 0) == 1
    }
    deinit {
        if !childClosed { childClosed = true; try? child.close() } // One attempt, never retry uncertain close.
        _ = Darwin.close(parent)
    }
}

// Actual factory result; no Codable, public constructor or caller bool.
final class NativeOriginalGroupCounterpart: @unchecked Sendable {
    let helper: NativePeerIdentity.Evidence
    let clientNonce, helperNonce, factoryOwner, groupConnection: String
    fileprivate init(helper: NativePeerIdentity.Evidence, clientNonce: String, helperNonce: String, factoryOwner: String, groupConnection: String) {
        self.helper = helper; self.clientNonce = clientNonce; self.helperNonce = helperNonce; self.factoryOwner = factoryOwner; self.groupConnection = groupConnection
    }
}

/// A diagnostic kernel/code identity, not a native CEF owner, document lease,
/// recovery authority, liveness promise or authorization to signal a process.
/// No socket/client/production integration is enabled by this component.
public struct NativePeerIdentity: Equatable, Sendable {
    public struct Evidence: Codable, Equatable, Sendable {
        public let pid: Int32, parent: UInt32, uid: UInt32
        public let startSec, startUsec: UInt64
        public let executable, argvSHA256, bootSession, auditSHA256, codeIdentifier, codeUnique: String
    }
    public struct ExpectedImage: Equatable, Sendable {
        public let executable, identifier, unique, argumentsSHA256: String
        public init?(executable: String, identifier: String, unique: String, argumentsSHA256: String) {
            guard executable.hasPrefix("/"), !executable.utf8.contains(0), !identifier.isEmpty,
                  unique.utf8.count >= 32, unique.utf8.count <= 128, unique.utf8.count % 2 == 0, unique.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            guard argumentsSHA256.utf8.count == 64, argumentsSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            self.executable = executable; self.identifier = identifier; self.unique = unique; self.argumentsSHA256 = argumentsSHA256
        }
    }
    private static let collectionLock = NSLock()
    private static var descriptorCloseUncertain = false
    public let evidence: Evidence
    private let audit: Data
    private init(evidence: Evidence, audit: Data) { self.evidence = evidence; self.audit = audit }

    /// Invoke only while the owner confines the connected fd. A CLOEXEC dup
    /// pins this socket object throughout collection; no path-based reconnect.
    public static func capture(socket fd: Int32, expected: ExpectedImage) -> NativePeerIdentity? {
        collectionLock.lock(); defer { collectionLock.unlock() }
        guard !descriptorCloseUncertain else { return nil }
        let owned = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { return nil }
        let collectedFirst = sample(owned), collectedLast = sample(owned)
        // One serialized duplicate, no retry/eviction if close is uncertain.
        guard Darwin.close(owned) == 0 else { descriptorCloseUncertain = true; return nil }
        guard let first = collectedFirst, let last = collectedLast,
              let proof = matched(first, last, expected: expected) else { return nil }
        return NativePeerIdentity(evidence: proof, audit: first.audit)
    }
    /// Exact original identity re-observation only. Failure is unknown; it is
    /// never proof this PID disappeared, or that originals were released.
    /// Prepared from the actual configured Foundation child object and its
    /// secured on-disk image BEFORE launching. Not Codable/caller evidence.
    fileprivate enum LaunchOrigin { case accepted, diagnostic }
    public final class PreparedLaunch: @unchecked Sendable {
        fileprivate let origin: LaunchOrigin
        public var isDiagnosticObservation: Bool { origin == .diagnostic }
        fileprivate let process: Process, expected: ExpectedImage, arguments: [String]
        fileprivate let bootstrap: NativeParentBootstrap
        fileprivate let lock = NSLock()
        fileprivate var consumed = false
        fileprivate init(process: Process, expected: ExpectedImage, arguments: [String], bootstrap: NativeParentBootstrap, origin: LaunchOrigin = .accepted) {
            self.origin = origin
            self.process = process; self.expected = expected; self.arguments = arguments; self.bootstrap = bootstrap
        }
        /// Invoke immediately after launching that SAME child, before await.
        /// Failure consumes the preparation; it cannot bless a later process.
        public func captureLaunched() -> LaunchWitness? {
            lock.lock(); defer { lock.unlock() }
            guard !consumed else { return nil }; consumed = true
            guard bootstrap.closeChildParentCopy() else { return nil }
            guard let original = NativePeerIdentity.launchStamp(process, expected: expected, arguments: arguments) else { return nil }
            return LaunchWitness(prepared: self, original: original)
        }
    }
    struct LaunchStamp: Equatable, Sendable {
        let pid: Int32, parent: UInt32, uid: UInt32
        let sec, usec: UInt64
        let executable, argv, boot: String
    }
    public final class LaunchWitness: @unchecked Sendable {
        fileprivate let prepared: PreparedLaunch, original: LaunchStamp
        fileprivate init(prepared: PreparedLaunch, original: LaunchStamp) { self.prepared = prepared; self.original = original }
        func bind(socket: Int32) -> NativePeerIdentity? {
            guard NativePeerIdentity.launchStamp(prepared.process, expected: prepared.expected, arguments: prepared.arguments) == original,
                  let peer = NativePeerIdentity.capture(socket: socket, expected: prepared.expected),
                  Self.matches(peer.evidence, original),
                  NativePeerIdentity.launchStamp(prepared.process, expected: prepared.expected, arguments: prepared.arguments) == original else { return nil }
            return peer
        }
        func reobserve(socket: Int32, original peer: NativePeerIdentity) -> Reobservation {
            guard let current = bind(socket: socket), current == peer else { return .unknown }
            return .current
        }
        public var isDiagnosticObservation: Bool { prepared.origin == .diagnostic }
        public var isDiagnosticImagePinned: Bool { prepared.origin == .diagnostic && NativePeerIdentity.diagnosticImagePolicyConfigured &&
            CompiledOriginalHelperImagePolicy.helperIdentifier == prepared.expected.identifier &&
            CompiledOriginalHelperImagePolicy.helperCodeDirectories.contains(prepared.expected.unique) }
        /// Writes only a fixed fault-release byte to the ACTUAL inherited parent
        /// endpoint after fresh original Process/birth/path/argv re-observation.
        /// Dispatch is not native validation, a document lease or authority.
        public func releaseDiagnosticDeadline() -> Bool {
            guard prepared.origin == .diagnostic,
                  NativePeerIdentity.launchStamp(prepared.process, expected: prepared.expected, arguments: prepared.arguments) == original else { return false }
            return prepared.bootstrap.releaseDiagnosticDeadline()
        }
        func acceptedCounterpart(socket: Int32, original peer: NativePeerIdentity, hello: JSONValue, clientNonce: String) -> NativeOriginalGroupCounterpart? {
            guard prepared.origin == .accepted, NativePeerIdentity.originalCallerAcceptedVersion == 1,
                  NativePeerIdentity.acceptedOriginalCallerHelperImages.contains(prepared.expected.unique),
                  bind(socket: socket) == peer, let caller = NativePeerIdentity.currentSelfEvidence() else { return nil }
            guard let pair = NativePeerIdentity.checkedCallerPair(hello, caller: caller, helper: peer.evidence, clientNonce: clientNonce),
                  bind(socket: socket) == peer, NativePeerIdentity.currentSelfEvidence() == caller else { return nil }
            return NativeOriginalGroupCounterpart(helper: peer.evidence, clientNonce: clientNonce, helperNonce: pair.nonce, factoryOwner: pair.owner, groupConnection: pair.connection)
        }
        static func matches(_ peer: Evidence, _ original: LaunchStamp) -> Bool {
            peer.pid == original.pid && peer.parent == original.parent && peer.uid == original.uid &&
            peer.startSec == original.sec && peer.startUsec == original.usec && peer.executable == original.executable &&
            peer.argvSHA256 == original.argv && peer.bootSession == original.boot
        }
    }
    // This predicate grants no authority and never changes the Process. It
    // prevents Objective-C stdin-setter exceptions for an already used task.
    static func canConfigureOriginalBootstrap(_ process: Process) -> Bool {
        guard process.processIdentifier == 0, !process.isRunning else { return false }
        guard let input = process.standardInput else { return true }
        guard let inherited = input as? FileHandle else { return false }
        // Foundation may represent inherited stdin by its actual standard
        // singleton. Never accept another handle just because it labels fd0.
        return inherited === FileHandle.standardInput && inherited.fileDescriptor == STDIN_FILENO
    }
    public static func prepareLaunch(_ process: Process) -> PreparedLaunch? {
        // Ordinary product/outsider routes take NO optional code/peer/bootstrap
        // work until a reviewed compiled image policy genuinely exists.
        guard originalCallerAcceptedVersion == 1, !acceptedOriginalCallerHelperImages.isEmpty else { return nil }
        guard canConfigureOriginalBootstrap(process), let executable = process.executableURL, executable.isFileURL,
              let arguments = process.arguments, arguments.count <= 16384,
              !([executable.path] + arguments).contains(where: { $0.utf8.contains(0) }) else { return nil }
        var nativeCode: SecStaticCode?, details: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &nativeCode) == errSecSuccess, let nativeCode,
              SecStaticCodeCheckValidity(nativeCode, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(nativeCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &details) == errSecSuccess,
              let row = details as? [String: Any], let securedPath = row[kSecCodeInfoMainExecutable as String] as? URL,
              securedPath.path == executable.path, let identifier = row[kSecCodeInfoIdentifier as String] as? String,
              let unique = row[kSecCodeInfoUnique as String] as? Data else { return nil }
        var encoded = Data()
        for argument in [executable.path] + arguments { encoded.append(contentsOf: argument.utf8); encoded.append(0) }
        guard encoded.count <= 1024 * 1024,
              let expected = ExpectedImage(executable: executable.path, identifier: identifier,
                  unique: unique.map { String(format: "%02x", $0) }.joined(), argumentsSHA256: hash(encoded)) else { return nil }
        guard acceptedOriginalCallerHelperImages.contains(expected.unique),
              // Repeat immediately before mutation, after potentially slow
              // static-code work; configured tasks must not be concurrently run.
              canConfigureOriginalBootstrap(process),
              let bootstrap = NativeParentBootstrap.create() else { return nil }
        process.standardInput = bootstrap.child
        return PreparedLaunch(process: process, expected: expected, arguments: arguments, bootstrap: bootstrap)
    }
    /// Explicit observation only. This origin can NEVER become an accepted
    /// counterpart, even in a future qualified production build.
    public enum DiagnosticLaunchResult: Sendable {
        case prepared(PreparedLaunch), helperImageRefused, unavailable
    }
    /// Compiled diagnostic image input only, never a production accepted flag.
    public static var diagnosticImagePolicyConfigured: Bool {
        let policy = CompiledOriginalHelperImagePolicy.self
        func hex(_ value: String, _ count: Int) -> Bool { value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        return policy.version == 1 && !policy.candidateIdentifier.isEmpty && !policy.helperIdentifier.isEmpty &&
            policy.helperCodeDirectories.count == 1 && policy.helperCodeDirectories.allSatisfy { value in
                (32...128).contains(value.utf8.count) && value.utf8.count % 2 == 0 && hex(value,value.utf8.count)
            } && hex(policy.helperLeafSHA256,64)
    }
    public static func prepareDiagnosticLaunch(_ process: Process) -> PreparedLaunch? {
        guard case .prepared(let prepared) = prepareDiagnosticLaunchResult(process) else { return nil }
        return prepared
    }
    public static func prepareDiagnosticLaunchResult(_ process: Process) -> DiagnosticLaunchResult {
        guard canConfigureOriginalBootstrap(process), let executable = process.executableURL, executable.isFileURL,
              let arguments = process.arguments, arguments.count <= 16384,
              !([executable.path] + arguments).contains(where: { $0.utf8.contains(0) }) else { return .unavailable }
        var nativeCode: SecStaticCode?, details: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &nativeCode) == errSecSuccess, let nativeCode,
              SecStaticCodeCheckValidity(nativeCode, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(nativeCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &details) == errSecSuccess,
              let row = details as? [String: Any], let securedPath = row[kSecCodeInfoMainExecutable as String] as? URL,
              securedPath.path == executable.path, let identifier = row[kSecCodeInfoIdentifier as String] as? String,
              let unique = row[kSecCodeInfoUnique as String] as? Data else { return .unavailable }
        var encoded = Data()
        for argument in [executable.path] + arguments { encoded.append(contentsOf: argument.utf8); encoded.append(0) }
        guard encoded.count <= 1024 * 1024,
              let expected = ExpectedImage(executable: executable.path, identifier: identifier,
                  unique: unique.map { String(format: "%02x", $0) }.joined(), argumentsSHA256: hash(encoded)) else { return .unavailable }
        let policy = CompiledOriginalHelperImagePolicy.self
        if policy.version != 0 {
            guard diagnosticImagePolicyConfigured else { return .unavailable }
            guard policy.helperIdentifier == expected.identifier,
                  policy.helperCodeDirectories.contains(expected.unique) else { return .helperImageRefused }
            guard let certificates = row[kSecCodeInfoCertificates as String] as? [SecCertificate],
                  let leaf = certificates.first else { return .unavailable }
            let leafBytes = SecCertificateCopyData(leaf) as Data
            guard policy.helperLeafSHA256 == hash(leafBytes) else { return .helperImageRefused }
        }
        guard // Observation is NEVER accepted image admission.
              // Repeat immediately before mutation, after potentially slow
              // static-code work; configured tasks must not be concurrently run.
              canConfigureOriginalBootstrap(process),
              let bootstrap = NativeParentBootstrap.create() else { return .unavailable }
        process.standardInput = bootstrap.child
        return .prepared(PreparedLaunch(process: process, expected: expected, arguments: arguments, bootstrap: bootstrap, origin: .diagnostic))
    }
    private static func launchStamp(_ process: Process, expected: ExpectedImage, arguments expectedArguments: [String]) -> LaunchStamp? {
        guard process.isRunning, process.executableURL?.path == expected.executable, process.arguments == expectedArguments else { return nil }
        let pid = process.processIdentifier
        guard pid > 0, let first = birth(pid), first.pbi_ppid == UInt32(getpid()),
              let executable = path(pid), executable == expected.executable,
              let argv = arguments(pid), argv == expected.argumentsSHA256, let boot = boot(),
              let last = birth(pid), first.pbi_pid == last.pbi_pid, first.pbi_ppid == last.pbi_ppid,
              first.pbi_start_tvsec == last.pbi_start_tvsec, first.pbi_start_tvusec == last.pbi_start_tvusec,
              path(pid) == executable, self.arguments(pid) == argv, self.boot() == boot,
              process.isRunning, process.processIdentifier == pid else { return nil }
        return LaunchStamp(pid: pid, parent: last.pbi_ppid, uid: last.pbi_uid, sec: last.pbi_start_tvsec,
            usec: last.pbi_start_tvusec, executable: executable, argv: argv, boot: boot)
    }
    private static let originalCallerAcceptedVersion = 0
    private static let acceptedOriginalCallerHelperImages: Set<String> = []
    fileprivate static func currentSelfEvidence() -> Evidence? {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let wanted = count
        let status = withUnsafeMutablePointer(to: &token) { raw in
            raw.withMemoryRebound(to: integer_t.self, capacity: Int(wanted)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        guard status == KERN_SUCCESS, count == wanted else { return nil }
        let audit = withUnsafeBytes(of: &token) { Data($0) }, pid = getpid()
        guard let first = birth(pid), let path = path(pid), let argv = arguments(pid), let boot = boot(), let code = code(audit), code.0 == path,
              let last = birth(pid), first.pbi_start_tvsec == last.pbi_start_tvsec, first.pbi_start_tvusec == last.pbi_start_tvusec,
              first.pbi_ppid == last.pbi_ppid, self.path(pid) == path, self.arguments(pid) == argv, self.boot() == boot else { return nil }
        return Evidence(pid: pid, parent: last.pbi_ppid, uid: last.pbi_uid, startSec: last.pbi_start_tvsec, startUsec: last.pbi_start_tvusec,
            executable: path, argvSHA256: argv, bootSession: boot, auditSHA256: hash(audit), codeIdentifier: code.1, codeUnique: code.2)
    }
    struct CheckedCallerPair: Equatable { let nonce, owner, connection: String }
    // Controlled parser seam only; this metadata value cannot create the
    // counterpart without private actual kernel/accepted-image factory checks.
    static func checkedCallerPair(_ hello: JSONValue, caller: Evidence, helper: Evidence, clientNonce: String) -> CheckedCallerPair? {
        let proof = hello["nativeOriginalCaller"]
        guard let client = UUID(uuidString: clientNonce), client.uuidString.lowercased() == clientNonce,
              proof["version"] == .number(1), proof["status"] == .string("observed"), proof["acceptedVersion"] == .number(1),
              proof["clientNonce"] == .string(clientNonce),
              let nonce = proof["helperNonce"].string, let uuid = UUID(uuidString: nonce), uuid.uuidString.lowercased() == nonce,
              sameCallerFields(proof["initialParent"], caller), sameCallerFields(proof["caller"], caller), sameCallerFields(proof["helper"], helper),
              let owner = proof["factoryOwner"].string, !owner.isEmpty, owner.utf8.count <= 128,
              let connection = proof["groupConnection"].string, !connection.isEmpty, connection.utf8.count <= 128,
              hello["nativeGroupSource"]["helperOwner"] == .string(owner), hello["nativeGroupSource"]["connection"] == .string(connection),
              hello["nativeHooks"]["nativeOriginalCallerAuthenticated"] == .bool(true), hello["nativeHooks"]["nativeOriginalCallerVersion"] == .number(1) else { return nil }
        return CheckedCallerPair(nonce: nonce, owner: owner, connection: connection)
    }
    static func sameCallerFields(_ row: JSONValue, _ expected: Evidence) -> Bool {
        row["pid"] == .number(Double(expected.pid)) && row["parent"] == .number(Double(expected.parent)) && row["uid"] == .number(Double(expected.uid)) &&
        row["startSec"] == .string(String(expected.startSec)) && row["startUsec"] == .number(Double(expected.startUsec)) &&
        row["executable"] == .string(expected.executable) && row["argvSHA256"] == .string(expected.argvSHA256) && row["bootSession"] == .string(expected.bootSession) &&
        row["auditSHA256"] == .string(expected.auditSHA256) && row["codeIdentifier"] == .string(expected.codeIdentifier) && row["codeUnique"] == .string(expected.codeUnique)
    }
    public enum Reobservation: Equatable, Sendable { case current, unknown }
    public func reobserve(socket fd: Int32, expected: ExpectedImage) -> Reobservation {
        guard let now = Self.capture(socket: fd, expected: expected) else { return .unknown }
        return now.audit == audit && now.evidence == evidence ? .current : .unknown
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // Internal boundary seam yields diagnostic Evidence only. It cannot create
    // NativePeerIdentity, which has no Codable/public receipt constructor.
    struct Sample: Equatable {
        var pid: Int32, parent: UInt32, uid: UInt32
        var startSec, startUsec: UInt64
        var executable, argvSHA256, bootSession, codeIdentifier, codeUnique: String
        var audit: Data
    }
    static func matched(_ first: Sample, _ last: Sample, expected: ExpectedImage) -> Evidence? {
        guard first == last, first.pid > 0, first.parent > 0, first.uid == getuid(),
              first.startSec > 0, first.startUsec < 1_000_000, !first.audit.isEmpty,
              first.audit.count == MemoryLayout<audit_token_t>.size,
              first.argvSHA256.utf8.count == 64, first.argvSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let boot = UUID(uuidString: first.bootSession), boot.uuidString == first.bootSession,
              first.argvSHA256 == expected.argumentsSHA256, first.executable == expected.executable, first.codeIdentifier == expected.identifier, first.codeUnique == expected.unique else { return nil }
        return Evidence(pid: first.pid, parent: first.parent, uid: first.uid, startSec: first.startSec, startUsec: first.startUsec,
            executable: first.executable, argvSHA256: first.argvSHA256, bootSession: first.bootSession,
            auditSHA256: hash(first.audit), codeIdentifier: first.codeIdentifier, codeUnique: first.codeUnique)
    }
    private static func token(_ fd: Int32) -> Data? {
        var token = audit_token_t(), size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }
    private static func peer(_ fd: Int32) -> (Int32, UInt32)? {
        var pid: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, size == socklen_t(MemoryLayout<Int32>.size),
              pid > 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return nil }
        return (pid, uid)
    }
    private static func birth(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5,
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { return nil }
        return info
    }
    private static func path(_ pid: Int32) -> String? {
        // libproc defines PROC_PIDPATHINFO_MAXSIZE as (4 * MAXPATHLEN);
        // that expression macro is not exposed by the Swift importer.
        let capacity = UInt32(MAXPATHLEN) * 4
        var bytes = [CChar](repeating: 0, count: Int(capacity))
        let size = proc_pidpath(pid, &bytes, capacity)
        guard size > 0, let zero = bytes.firstIndex(of: 0), zero > 0 else { return nil }
        return String(bytes: bytes[..<zero].map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
    private static func boot() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size <= 128 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
              let zero = bytes.firstIndex(of: 0), let raw = String(bytes: bytes[..<zero].map { UInt8(bitPattern: $0) }, encoding: .utf8),
              let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString
    }
    private static func arguments(_ pid: Int32) -> String? {
        var maximum: Int32 = 0, maximumSize = MemoryLayout<Int32>.size
        var limit: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limit, 2, &maximum, &maximumSize, nil, 0) == 0,
              maximum > Int32(MemoryLayout<Int32>.size), maximum <= 1024 * 1024 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = Int(maximum)
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= bytes.count else { return nil }
        return argumentsDigest(Data(bytes.prefix(size)))
    }
    static func argumentsDigest(_ bytes: Data) -> String? {
        guard bytes.count > MemoryLayout<Int32>.size, bytes.count <= 1024 * 1024 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 16384 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func string() -> Data? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            let result = Data(bytes[cursor..<end]); cursor = end + 1; return result
        }
        guard let kernelPath = string(), !kernelPath.isEmpty else { return nil }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var canonical = Data()
        for index in 0..<Int(count) {
            guard let argument = string(), index != 0 || !argument.isEmpty else { return nil }
            canonical.append(argument); canonical.append(0)
        }
        return hash(canonical) // Never expose argv/environment to the journal/log.
    }
    private static func code(_ audit: Data) -> (String, String, String)? {
        var dynamic: SecCode?
        let attributes = [kSecGuestAttributeAudit: audit] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCheckValidity(dynamic, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?, details: CFDictionary?
        guard SecCodeCopyStaticCode(dynamic, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &details) == errSecSuccess,
              let row = details as? [String: Any], let executable = row[kSecCodeInfoMainExecutable as String] as? URL,
              let identifier = row[kSecCodeInfoIdentifier as String] as? String, !identifier.isEmpty,
              let unique = row[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty, unique.count <= 64,
              SecCodeCheckValidity(dynamic, [], nil) == errSecSuccess else { return nil }
        return (executable.path, identifier, unique.map { String(format: "%02x", $0) }.joined())
    }
    private static func sample(_ fd: Int32) -> Sample? {
        guard let audit = token(fd), let peer = peer(fd), let first = birth(peer.0),
              let path = path(peer.0), let argv = arguments(peer.0), let boot = boot(),
              let code = code(audit), code.0 == path, let last = birth(peer.0),
              first.pbi_pid == last.pbi_pid, first.pbi_ppid == last.pbi_ppid, first.pbi_uid == last.pbi_uid,
              first.pbi_start_tvsec == last.pbi_start_tvsec, first.pbi_start_tvusec == last.pbi_start_tvusec,
              self.path(peer.0) == path, token(fd) == audit, let finalPeer = self.peer(fd), finalPeer.0 == peer.0, finalPeer.1 == peer.1 else { return nil }
        return Sample(pid: peer.0, parent: last.pbi_ppid, uid: peer.1, startSec: last.pbi_start_tvsec, startUsec: last.pbi_start_tvusec,
            executable: path, argvSHA256: argv, bootSession: boot, codeIdentifier: code.1, codeUnique: code.2, audit: audit)
    }
}
