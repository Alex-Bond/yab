import Foundation
import CryptoKit

/// This decoder yields metadata, never a live task right, CEF owner or phase.
/// Logical processId/routingId are tree keys. They are NEVER OS signal targets.
struct NativeOriginalSourceMetadata: Sendable, Equatable {
    struct Process: Codable, Sendable, Equatable {
        let launchIncarnation: String
        let osPID: Int32
        let pidVersion: UInt32
        let birthSec: String
        let birthUsec: UInt32
        let boot, executable, argvDigest, codeUnique, signingID, auditDigest: String
    }
    struct Frame: Codable, Sendable, Equatable {
        let browserId, processId, routingId: Int32
        let document, nativeContext: String
        let main: Bool
        let parentProcessId, parentRoutingId: Int32?
        let originalProcess: Process
    }
    let sourceReceipt: String
    let treeSequence, phaseSequence, operationSequence: String
    let frames: [Frame]
    let frameTreeSHA256: String
    let processes: [Process]
    // All values are observations at the original native callback, not a
    // durable image/task/document lease that can be replayed after helper loss.
    private init(sourceReceipt: String, tree: String, phase: String, operation: String, frames: [Frame], digest: String, processes: [Process]) {
        self.sourceReceipt = sourceReceipt; treeSequence = tree; phaseSequence = phase; operationSequence = operation
        self.frames = frames; frameTreeSHA256 = digest; self.processes = processes
    }
    static func decodeMetadata(_ value: JSONValue, members: [NativeSwitchJournal.Member]) -> Self? {
        guard value["version"] == .number(1), value["nativeSourcesVersion"] == .number(1),
              value["status"] == .string("observed"), value["available"] == .bool(true),
              value["nativeSourcesCurrentAtReply"] == .bool(true), value["fullImageLease"] == .bool(false),
              value["commitAvailable"] == .bool(false), value["nativeAtomicSwitchCommit"] == .bool(false),
              let receipt = value["sourceReceipt"].string, opaque(receipt),
              let tree = sequence(value["nativeTreeSequence"]), let phase = sequence(value["nativePhaseSequence"]),
              let operation = sequence(value["nativeOperationSequence"]),
              case .array(let rows) = value["frames"], !rows.isEmpty, rows.count <= 4096,
              !members.isEmpty, members.count <= 256,
              Set(members.map(\.browser)).count == members.count else { return nil }
        let intended = Dictionary(uniqueKeysWithValues: members.map { ($0.browser, $0) })
        var frames: [Frame] = [], keyed: [String: Int] = [:], mains = Set<Int32>()
        var processes: [Int32: Process] = [:], nativeContexts: [Int32: String] = [:]
        var incarnations: [String: Int32] = [:]
        var osProcessOwners: [Int32: Int32] = [:]
        for row in rows {
            guard let browser = integer(row["browserId"], minimum: 1), let member = intended[browser],
                  let process = integer(row["processId"]), let routing = integer(row["routingId"]),
                  let document = row["document"].string, opaque(document),
                  let context = row["nativeContext"].string, opaque(context),
                  case .bool(let main) = row["main"], let source = processMetadata(row["originalProcess"]) else { return nil }
            let parentProcess = integer(row["parentProcessId"]), parentRouting = integer(row["parentRoutingId"])
            if main {
                guard row["parentProcessId"] == .null, row["parentRoutingId"] == .null,
                      member.document == document, mains.insert(browser).inserted else { return nil }
            } else {
                guard parentProcess != nil, parentRouting != nil else { return nil }
            }
            let key = frameKey(process, routing)
            guard keyed[key] == nil else { return nil }
            if let old = processes[process], old != source { return nil }
            if let old = nativeContexts[browser], old != context { return nil }
            if let old = incarnations[source.launchIncarnation], old != process { return nil }
            // A current whole tree cannot contain two logical RPH instances
            // claiming the same OS PID, even with conflicting birth/incarnation.
            // This is malformed-metadata refusal, NEVER PID signal authority.
            if let old = osProcessOwners[source.osPID], old != process { return nil }
            osProcessOwners[source.osPID] = process
            processes[process] = source; nativeContexts[browser] = context; incarnations[source.launchIncarnation] = process
            keyed[key] = frames.count
            frames.append(Frame(browserId: browser, processId: process, routingId: routing, document: document,
                nativeContext: context, main: main, parentProcessId: parentProcess, parentRoutingId: parentRouting, originalProcess: source))
        }
        guard mains == Set(intended.keys), processes.count <= 256 else { return nil } // Fail whole, never truncate.
        for frame in frames where !frame.main {
            var current = frame, visited = Set<String>()
            while !current.main {
                guard let process = current.parentProcessId, let routing = current.parentRoutingId,
                      let index = keyed[frameKey(process, routing)], visited.insert(frameKey(process, routing)).inserted else { return nil }
                let parent = frames[index]
                guard parent.browserId == frame.browserId, parent.nativeContext == frame.nativeContext else { return nil }
                current = parent
            }
        }
        let sorted = frames.sorted { $0.processId == $1.processId ? $0.routingId < $1.routingId : $0.processId < $1.processId }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(sorted), bytes.count <= 3 * 1024 * 1024 else { return nil }
        return Self(sourceReceipt: receipt, tree: tree, phase: phase, operation: operation, frames: sorted,
            digest: hash(bytes), processes: processes.keys.sorted().compactMap { processes[$0] })
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func sequence(_ value: JSONValue) -> String? {
        guard let text = value.string, let number = UInt64(text), number > 0, String(number) == text else { return nil }; return text
    }
    static func opaque(_ text: String, maximum: Int = 256) -> Bool {
        !text.isEmpty && text.utf8.count <= maximum && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func integer(_ value: JSONValue, minimum: Double = 0) -> Int32? {
        guard let number = value.number, number.isFinite, number >= minimum, number <= Double(Int32.max), number.rounded(.towardZero) == number else { return nil }
        return Int32(number)
    }
    private static func uint32(_ value: JSONValue, maximum: Double = Double(UInt32.max)) -> UInt32? {
        guard let number = value.number, number.isFinite, number >= 0, number <= maximum, number.rounded(.towardZero) == number else { return nil }
        return UInt32(number)
    }
    // Native0062 uses Chromium base::HexEncode, preserving uppercase bytes.
    private static func hex(_ text: String, count: ClosedRange<Int>) -> Bool {
        count.contains(text.utf8.count) && text.utf8.count % 2 == 0 && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }
    private static func frameKey(_ process: Int32, _ routing: Int32) -> String { "\(process):\(routing)" }
    private static func processMetadata(_ value: JSONValue) -> Process? {
        guard value["version"] == .number(1), value["imageIdentityObservedAtAcquisition"] == .bool(true),
              value["fullImageLease"] == .bool(false),
              let incarnation = value["launchIncarnation"].string, opaque(incarnation),
              let pid = integer(value["osPID"], minimum: 1), let version = uint32(value["pidVersion"]),
              let seconds = sequence(value["birthSec"]), let microseconds = uint32(value["birthUsec"], maximum: 999999),
              let boot = value["boot"].string, UUID(uuidString: boot) != nil,
              let executable = value["executable"].string, executable.hasPrefix("/"), opaque(executable, maximum: 4096),
              value["argvDigestEncoding"] == .string("sha256-lengthdecimal-colon-arg-nul"),
              let argv = value["argvDigest"].string, hex(argv, count: 64...64),
              let unique = value["codeUnique"].string, hex(unique, count: 32...128),
              let signing = value["signingID"].string, opaque(signing),
              let audit = value["auditDigest"].string, hex(audit, count: 64...64) else { return nil }
        return Process(launchIncarnation: incarnation, osPID: pid, pidVersion: version, birthSec: seconds, birthUsec: microseconds,
            boot: boot, executable: executable, argvDigest: argv, codeUnique: unique, signingID: signing, auditDigest: audit)
    }
}

/// Accepted native-source image policy has no issuer yet. Diagnostic compiled
/// helper pins cannot populate it. A future exact source-qualified signed image
/// needs actual SDK sources tests + both-sided parent/helper acceptance first.
enum NativeOriginalSourcesPolicy {
    static let version = 0
    static let helperCodeDirectories: Set<String> = []
    static let sdkFrameworkSHA256 = ""
    static let nativeSourceManifestSHA256 = ""
}
