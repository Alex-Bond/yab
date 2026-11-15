import CryptoKit
import Foundation

// What iOS hands over about a Yab that crashed or stopped answering
// (MetricKit's MXDiagnosticPayload, at the next launch), made into the crash
// report the site already reads from the Mac (fast-web's /api/crash):
// a first line that names the app, then a body shaped like macOS's .ips, so
// the site's grouping (the exception and the first of Yab's own frames) and
// scripts/crashes.mjs (symbols matched by UUID, atos) read it as they read a
// Mac's.
//
// Only what finding the crash needs goes: the kind of crash and how it
// ended, the threads' frames (the binary's name and UUID, the offset in its
// code), the versions of Yab and iOS, the iPhone model, and, for an uncaught
// Objective-C exception, its name, class and the message's format without
// its arguments. Not the region format, the process id, Low Power Mode or the
// memory around a bad address (virtualMemoryRegionInfo), the way the Mac
// leaves out its memory map. Nothing from the pages.
//
// A hang of `hangReportMs` or more (MetricKit's hang diagnostics: the main
// thread didn't answer, often the watchdog's kill that followed) is a
// report of its own in the same shape, "kind":"hang" in its first line: its
// whole call tree with the samples on each branch, and the heaviest path of
// the thread it is blamed on as that thread's frames, innermost first, so
// the site's signature and crashes.mjs read it as a crash. A shorter hang's
// stack only goes with a report (HangStacks).

/// One crash as it waits for a yes and then goes.
struct CrashReport: Codable, Equatable, Sendable {
    /// The same crash handed over twice is one report.
    var key: String
    /// The Yab that crashed, which may be older than the one sending.
    var version: String
    var build: String
    var os: String
    var device: String
    /// An uncaught Objective-C exception, in a line: the site's reason.
    var exception: String?
    /// The first line and the body, as the site stores it.
    var report: String
    var at: Date?
    /// "hang" for a hang (MXHangDiagnostic); nil for a crash.
    var kind: String? = nil

    var isHang: Bool { kind == DiagnosticReports.hangKind }
}

enum DiagnosticReports {
    static let platform = "iphone"
    /// A report's text at most: the site takes 512 KB for one request, the
    /// hang stacks that may go with it included (HangStacks.bytes).
    static let reportBytes = 256 * 1024
    /// A thread longer than this is cut: a runaway recursion says enough in
    /// its first frames.
    static let framesKept = 512
    static let hangKind = "hang"
    /// A hang this long is a report of its own: past every hitch people
    /// shrug off, and short of the watchdog's 5 to 10 s, so the hangs that
    /// end in a kill are among them.
    static let hangReportMs = 2000

    // MARK: payloads

    /// The crashes in one payload, as `MXDiagnosticPayload.jsonRepresentation()`
    /// writes it.
    static func crashes(inPayload data: Data, bundle: String) -> [CrashReport] {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let end = payload["timeStampEnd"] as? String
        return (payload["crashDiagnostics"] as? [[String: Any]] ?? []).compactMap {
            report(crash: $0, end: end, bundle: bundle)
        }
    }

    /// The hangs in one payload: those of `hangReportMs` or more as reports,
    /// the shorter ones as HangStacks keeps them. `durations` are MetricKit's
    /// own, in milliseconds, in the payload's order; without them the
    /// metadata's words are read ("2.5 sec").
    static func hangs(inPayload data: Data, bundle: String, durations: [Int]? = nil)
        -> (reports: [CrashReport], stacks: [[String: Any]]) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
        let end = payload["timeStampEnd"] as? String
        var reports: [CrashReport] = [], stacks: [[String: Any]] = []
        for (number, hang) in (payload["hangDiagnostics"] as? [[String: Any]] ?? []).enumerated() {
            let meta = hang["diagnosticMetaData"] as? [String: Any] ?? [:]
            guard let tree = hang["callStackTree"] as? [String: Any],
                  let ms = durations.flatMap({ number < $0.count ? $0[number] : nil })
                    ?? milliseconds(meta["hangDuration"] as? String) else { continue }
            if ms >= hangReportMs, let report = report(hang: hang, milliseconds: ms, end: end, bundle: bundle) {
                reports.append(report)
            } else if let frames = HangStacks.stackOnly(tree) {
                var kept: [String: Any] = ["ms": ms, "stack": frames]
                if let build = meta["appBuildVersion"] as? String { kept["build"] = build }
                stacks.append(kept)
            }
        }
        return (reports, stacks)
    }

    // MARK: one hang

    static func report(hang: [String: Any], milliseconds ms: Int, end: String?, bundle: String) -> CrashReport? {
        guard let tree = hang["callStackTree"] as? [String: Any], let frames = HangStacks.stackOnly(tree) else { return nil }
        let meta = hang["diagnosticMetaData"] as? [String: Any] ?? [:]
        func said(_ key: String) -> String { (meta[key] as? String) ?? "" }
        let version = said("appVersion"), build = said("appBuildVersion")
        let os = said("osVersion"), device = said("deviceType")
        let arch = codeArchitecture(said("platformArchitecture"))
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        let blamed = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first ?? [:]
        var images: [[String: Any]] = [], index: [String: Int] = [:]
        let chain = innermostFirst(heaviestPath(blamed["callStackRootFrames"] as? [[String: Any]] ?? []))
        let thread: [String: Any] = ["id": 0, "triggered": true,
                                     "frames": ipsFrames(chain, arch: arch, images: &images, index: &index)]
        var keptMeta = kept(meta)
        if let duration = meta["hangDuration"] { keptMeta["hangDuration"] = duration }
        let body: [String: Any] = [
            "source": "MetricKit", "hang": ["ms": ms], "faultingThread": 0, "threads": [thread],
            "usedImages": images, "metaData": keptMeta, "callStackTree": frames,
        ]
        var head: [String: Any] = [
            "app_name": "Yab", "app_version": version, "build_version": build, "kind": hangKind,
            "bundleID": (meta["bundleIdentifier"] as? String) ?? bundle,
            "os_version": os, "platform": platform, "device": device, "source": "MetricKit",
        ]
        if let end { head["timestamp"] = end }
        if let testFlight = meta["isTestFlightApp"] as? Bool { head["testflight"] = testFlight }
        return CrashReport(key: key(hang, end: end), version: version, build: build, os: os, device: device,
                           exception: nil, report: text(head: head, body: body), at: end.flatMap(date), kind: hangKind)
    }

    /// Down a merged tree of samples, the branch with the most at each step;
    /// a plain chain is itself.
    static func heaviestPath(_ roots: [[String: Any]]) -> [[String: Any]] {
        var chain: [[String: Any]] = []
        var level = roots
        while !level.isEmpty, chain.count < framesKept {
            let heaviest = level.max { (number64($0["sampleCount"]) ?? 0) < (number64($1["sampleCount"]) ?? 0) }!
            chain.append(heaviest)
            level = heaviest["subFrames"] as? [[String: Any]] ?? []
        }
        return chain
    }

    /// A stack innermost first, as an .ips and the site's signature read it.
    /// MetricKit writes a crash's that way; a stack that starts at dyld's
    /// start (the outermost frame of every main thread) came the other way.
    static func innermostFirst(_ chain: [[String: Any]]) -> [[String: Any]] {
        (chain.first?["binaryName"] as? String) == "dyld" ? chain.reversed() : chain
    }

    /// "2.5 sec", "800 ms", "1 min" in milliseconds.
    static func milliseconds(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: " ")
        guard let first = parts.first, let value = Double(first) else { return nil }
        let unit = parts.dropFirst().first.map { $0.lowercased() } ?? "sec"
        let scale: Double = unit.hasPrefix("ms") ? 1 : unit.hasPrefix("min") ? 60_000 : unit.hasPrefix("h") ? 3_600_000 : 1000
        return Int((value * scale).rounded())
    }

    // MARK: one crash

    static func report(crash: [String: Any], end: String?, bundle: String) -> CrashReport? {
        guard let tree = crash["callStackTree"] as? [String: Any] else { return nil }
        let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]
        func said(_ key: String) -> String { (meta[key] as? String) ?? "" }
        let version = said("appVersion"), build = said("appBuildVersion")
        let os = said("osVersion"), device = said("deviceType")
        let (threads, images, faulting) = threadsAndImages(tree, architecture: said("platformArchitecture"))

        var body: [String: Any] = [
            "source": "MetricKit",
            "faultingThread": faulting,
            "threads": threads,
            "usedImages": images,
            "metaData": kept(meta),
        ]
        if let exception = exception(meta) { body["exception"] = exception }
        if let reason = meta["terminationReason"] as? String, !reason.isEmpty { body["termination"] = ["reason": reason] }
        let thrown = objectiveCException(crash: crash, meta: meta)
        if let thrown { body["objcException"] = thrown }
        if let frames = HangStacks.stackOnly(tree) { body["callStackTree"] = frames }

        var head: [String: Any] = [
            "app_name": "Yab", "app_version": version, "build_version": build,
            "bundleID": (meta["bundleIdentifier"] as? String) ?? bundle,
            "os_version": os, "platform": platform, "device": device, "source": "MetricKit",
        ]
        if let end { head["timestamp"] = end }
        if let testFlight = meta["isTestFlightApp"] as? Bool { head["testflight"] = testFlight }

        return CrashReport(key: key(crash, end: end), version: version, build: build, os: os, device: device,
                           exception: thrown.map(line), report: Self.text(head: head, body: body),
                           at: end.flatMap(date))
    }

    /// The first line, then the body, cut to `reportBytes`: the copy of
    /// MetricKit's own tree goes first, then the frames of threads that
    /// didn't crash, never the crashed thread's.
    static func text(head: [String: Any], body: [String: Any]) -> String {
        func joined(_ body: [String: Any]) -> String { json(head) + "\n" + json(body) }
        var body = body
        var out = joined(body)
        guard out.utf8.count > reportBytes else { return out }
        body["callStackTree"] = nil
        out = joined(body)
        guard out.utf8.count > reportBytes else { return out }
        let faulting = body["faultingThread"] as? Int ?? 0
        if let threads = body["threads"] as? [[String: Any]] {
            body["threads"] = threads.enumerated().map { index, thread in
                var thread = thread
                if index != faulting { thread["frames"] = [] }
                return thread
            }
        }
        return joined(body)
    }

    /// MetricKit's threads as an .ips writes them: frames innermost first,
    /// each pointing into a list of the binaries they are in. A thread's
    /// stack is one chain, each frame's first subframe its caller; the
    /// thread the crash is attributed to is the faulting one.
    static func threadsAndImages(_ tree: [String: Any], architecture: String)
        -> (threads: [[String: Any]], images: [[String: Any]], faulting: Int) {
        let arch = codeArchitecture(architecture)
        var images: [[String: Any]] = []
        var index: [String: Int] = [:]
        var threads: [[String: Any]] = []
        var faulting: Int?
        for (number, stack) in (tree["callStacks"] as? [[String: Any]] ?? []).enumerated() {
            var chain: [[String: Any]] = []
            var level = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            while let frame = level.first, chain.count < framesKept {
                chain.append(frame)
                level = frame["subFrames"] as? [[String: Any]] ?? []
            }
            let frames = ipsFrames(chain, arch: arch, images: &images, index: &index)
            var thread: [String: Any] = ["id": number, "frames": frames]
            if stack["threadAttributed"] as? Bool == true, faulting == nil {
                faulting = number
                thread["triggered"] = true
            }
            threads.append(thread)
        }
        return (threads, images, faulting ?? 0)
    }

    /// The device's architecture (arm64e on most iPhones) is not the one
    /// Yab's code is built for, and the symbols are matched by it.
    static func codeArchitecture(_ architecture: String) -> String {
        architecture.hasPrefix("arm64") || architecture.isEmpty ? "arm64" : architecture
    }

    /// MetricKit's frames as an .ips writes them, each pointing into the
    /// list of binaries, which grows as new ones are met.
    static func ipsFrames(_ chain: [[String: Any]], arch: String, images: inout [[String: Any]],
                          index: inout [String: Int]) -> [[String: Any]] {
        chain.map { frame in
            let name = frame["binaryName"] as? String ?? "???"
            let uuid = frame["binaryUUID"] as? String ?? ""
            let image: Int
            if let known = index[uuid + "/" + name] {
                image = known
            } else {
                image = images.count
                index[uuid + "/" + name] = image
                images.append(["name": name, "uuid": uuid, "arch": arch])
            }
            var out: [String: Any] = ["imageIndex": image]
            let address = number64(frame["address"])
            if let address { out["address"] = address }
            if let offset = imageOffset(address: address, offset: number64(frame["offsetIntoBinaryTextSegment"])) {
                out["imageOffset"] = offset
            }
            return out
        }
    }

    /// Where a frame is in its binary's code, as atos and crashes.mjs read
    /// it (from 0x100000000, where an iPhone app's code starts). Some
    /// systems have written the binary's load address in MetricKit's offset;
    /// no offset into code is 4 GB, so then it is the address less that.
    static func imageOffset(address: Int64?, offset: Int64?) -> Int64? {
        guard let offset, offset >= 0 else { return nil }
        if offset >= 0x1_0000_0000, let address, address >= offset { return address - offset }
        return offset
    }

    /// The Mach exception and the signal, by name as an .ips writes them,
    /// with MetricKit's numbers beside.
    static func exception(_ meta: [String: Any]) -> [String: Any]? {
        var out: [String: Any] = [:]
        if let type = number64(meta["exceptionType"]) {
            out["type"] = machException(Int(type)) ?? "EXC_\(type)"
            out["rawType"] = type
        }
        if let code = number64(meta["exceptionCode"]) {
            out["codes"] = String(format: "0x%016llx", UInt64(bitPattern: code))
            out["rawCodes"] = [code]
        }
        if let signal = number64(meta["signal"]) {
            out["signal"] = signalName(Int(signal)) ?? "SIG\(signal)"
        }
        return out.isEmpty ? nil : out
    }

    static func machException(_ type: Int) -> String? {
        let names = ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_EMULATION", "EXC_SOFTWARE",
                     "EXC_BREAKPOINT", "EXC_SYSCALL", "EXC_MACH_SYSCALL", "EXC_RPC_ALERT", "EXC_CRASH",
                     "EXC_RESOURCE", "EXC_GUARD", "EXC_CORPSE_NOTIFY"]
        return (1 ... names.count).contains(type) ? names[type - 1] : nil
    }

    static func signalName(_ signal: Int) -> String? {
        let names = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT",
                     8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE",
                     14: "SIGALRM", 15: "SIGTERM"]
        return names[signal]
    }

    /// An uncaught Objective-C exception (iOS 17 and later): its name, its
    /// class and the format of its message, never the arguments put into
    /// it, which can be anything the app held.
    static func objectiveCException(crash: [String: Any], meta: [String: Any]) -> [String: Any]? {
        let keys = ["objectiveCexceptionReason", "objectiveCExceptionReason", "exceptionReason"]
        guard let reason = keys.lazy.compactMap({ (meta[$0] ?? crash[$0]) as? [String: Any] }).first else { return nil }
        var out: [String: Any] = [:]
        for (from, to) in [("exceptionName", "name"), ("className", "className"), ("exceptionType", "type"),
                           ("formatString", "format")] {
            if let value = reason[from] as? String, !value.isEmpty { out[to] = String(value.prefix(2000)) }
        }
        return out.isEmpty ? nil : out
    }

    /// The exception in a line, as the site shows why a crash happened.
    static func line(_ exception: [String: Any]) -> String {
        let name = exception["name"] as? String ?? exception["className"] as? String ?? "Exception"
        guard let format = exception["format"] as? String else { return name }
        return name + ": " + format
    }

    /// Of the metadata, what reads the crash.
    static let keptMeta: Set<String> = [
        "appVersion", "appBuildVersion", "osVersion", "deviceType", "platformArchitecture", "isTestFlightApp",
        "exceptionType", "exceptionCode", "signal", "terminationReason",
    ]

    static func kept(_ meta: [String: Any]) -> [String: Any] {
        meta.filter { keptMeta.contains($0.key) }
    }

    // MARK: helpers

    /// The crash's own JSON and when its payload ended: the same handed over
    /// at two launches is one.
    static func key(_ crash: [String: Any], end: String?) -> String {
        let digest = SHA256.hash(data: Data((json(crash) + "|" + (end ?? "")).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func number64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    /// MetricKit's time, "2026-10-09 08:12:00 +0000".
    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: text)
    }
}
