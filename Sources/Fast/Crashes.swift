import AppKit
import os

// When yab quits unexpectedly, macOS writes a report of it in
// ~/Library/Logs/DiagnosticReports. The next time yab opens, the reports
// it hasn't sent yet can go to the site, so the same crash on many Macs
// can be found and fixed.
//
// Only what finding the crash needs goes (trimmed): the kind of crash, the
// threads' frames, the code loaded, the version and macOS, and why: the
// message a failed check or an exception left (asi), where an exception
// AppKit caught was thrown (asiBacktraces), and the uncaught
// exception Links.watchForTrouble wrote down just before, all cleaned
// (Sanitizer: no page addresses, email addresses, names in paths or long
// hex). Not the rest of what macOS writes, the memory map with the paths of
// every file yab had open (vmSummary), the registers, the machine's own
// ids; and the home folder's path, which names you, is sent as ~. Nothing
// from the pages.
// A memory fault positively located in a stack guard keeps only that
// fact (faultInStackGuard: true), derived before its region text is removed.
//
// A report goes only with its body. One macOS is still writing waits for
// the next launch; a body JSONSerialization turns down is mended (a lone
// half of a surrogate pair, a raw control character) or, failing that,
// goes raw with the same parts taken out (scrubbed), saying so.
//
// With the reports goes the newest part of the log of the main thread's
// stalls (Watchdog): when it stopped for a second or more, doing what, and
// where it was. Nothing from the pages either.
//
// Off until you say. When there are new reports, yab asks to send them.
// Declining skips those reports; a later crash asks again. Automatic sending
// is a separate switch in Settings › About. Only a
// build that has a site sends anything (Updater.site), and only reports
// written after the first launch that could send them, never a backlog
// from before the switch existed.

enum Crashes {
    private static let log = Logger(subsystem: "dev.serafim.fast", category: "Crashes")
    static let key = "crash.send"
    private static let since = "crash.since"

    /// Automatic sending is off unless you turned it on in Settings › About.
    static var sends: Bool { Store.settings.object(forKey: key) as? Bool ?? false }

    /// A little after launch, off the main thread: the window comes first.
    @MainActor
    static func sendAfterLaunch() {
        guard let site = Updater.site, !Store.testing || ProcessInfo.processInfo.environment["YAB_FEED"] != nil else { return }
        let defaults = Store.settings
        guard let last = defaults.object(forKey: since) as? Date else {
            defaults.set(Date(), forKey: since)
            return
        }
        let endpoint = site.appendingPathComponent("api/crash")
        let version = Updater.version, build = Updater.build, system = Updater.system
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let log = Store.file("crash.log")
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(20))
            let found = reports(after: last, bundle: bundle)
            guard let latest = found.last?.1 else { return }
            let allowed = await consent(through: latest, defaults: defaults) { await ask() }
            guard allowed else { return }
            let stalls = await MainActor.run { Watchdog.recent() ?? "" }
            // The hangs' stacks MetricKit gave (FieldHangs): with the first
            // report that goes, then forgotten.
            var hangs = FieldHangs.stacks()
            let hadHangs = !hangs.isEmpty
            let sent = await send(found, after: last, home: home, thrown: thrown(inLog: tail(of: log))) { report in
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // The Yab that crashed, which may be older than the one sending.
                let made = madeBy(report.text)
                var fields: [String: Any] = [
                    "version": made?.version ?? version, "build": made?.build ?? build, "os": system,
                    "report": String(report.text.prefix(500_000)),
                    "stalls": stalls, "bytes": report.bytes,
                ]
                if let parse = report.parse { fields["parse"] = parse }
                if let exception = report.exception { fields["exception"] = exception }
                if !hangs.isEmpty { fields["hangs"] = hangs }
                request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
                guard let (_, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
                hangs = []
                return true
            }
            if hadHangs, hangs.isEmpty { FieldHangs.forgetStacks() }
            await MainActor.run { if sent > last { defaults.set(sent, forKey: since) } }
        }
    }

    /// A response applies to these reports, never changes automatic sending.
    /// Advance past declined reports so the same crash doesn't ask again.
    @MainActor
    static func consent(through date: Date, defaults: UserDefaults, ask: () async -> Bool) async -> Bool {
        if defaults.bool(forKey: key) { return true }
        // A stored false only means automatic sending is off. It does not
        // establish that a crash question was ever shown or answered.
        let allowed = await ask()
        if !allowed {
            let previous = defaults.object(forKey: since) as? Date ?? .distantPast
            defaults.set(max(previous, date), forKey: since)
        }
        return allowed
    }

    @MainActor
    static func ask(using questions: Questions? = nil) async -> Bool {
        await (questions ?? .shared).ask(Question(
            title: "Share saved crash reports?",
            detail: "macOS saved crash reports from an earlier Yab session. They include what crashed and why, and the versions of Yab and macOS, never pages or anything you typed. Sharing them helps fix problems. You can turn on automatic sending in Settings › About.",
            icon: NSApp.applicationIconImage, ownIcon: true, yes: "Send", no: "Don’t Send"
        ))
    }

    /// One report as it goes: the text, how many bytes its file had, and
    /// why the body went mended or raw, when it did.
    struct Report: Equatable {
        var text: String
        var bytes: Int
        var parse: String?
        /// The uncaught exception written down just before it, cleaned.
        var exception: String?
    }

    /// An uncaught exception as Links.watchForTrouble wrote it in crash.log:
    /// when, its name and reason, its stack.
    struct Thrown: Equatable {
        var at: Date
        var text: String
    }

    /// What to do with one report now.
    enum Outcome: Equatable {
        case send(Report)
        /// Not yet: no body, or a body cut short, that may still be coming.
        /// Tried again at the next launch.
        case wait
        /// Never: a report that stayed without a body for a day.
        case skip
    }

    /// How long a report without a whole body is waited for before it goes
    /// raw as it is, or, with no body at all, is left behind.
    static let patience: TimeInterval = 24 * 60 * 60

    /// Sends the reports, oldest first, five at most, and answers how far
    /// `since` can move: past what went or was left behind, never past a
    /// report still waiting for its body or one the site didn't take.
    static func send(_ found: [(URL, Date)], after last: Date, home: String, thrown: [Thrown] = [],
                     settle: Duration = .milliseconds(1500),
                     now: () -> Date = Date.init, post: (Report) async -> Bool) async -> Date {
        var newest = last
        for (file, written) in found.prefix(5) {
            guard await settled(file, wait: settle, now: now()), let data = try? Data(contentsOf: file) else { break }
            // Bytes that aren't UTF-8 become U+FFFD rather than lose the report.
            let outcome = prepared(String(decoding: data, as: UTF8.self), home: home, bytes: data.count,
                                   age: now().timeIntervalSince(written), name: file.lastPathComponent)
            switch outcome {
            case .wait: return newest
            case .skip: newest = max(newest, written)
            case var .send(report):
                report.exception = exception(before: written, after: last, in: thrown, home: home)
                guard await post(report) else { return newest }
                newest = max(newest, written)
            }
        }
        return newest
    }

    // MARK: crash.log

    /// The end of crash.log, where the newest exceptions are: the file only
    /// grows, and an exception that ended a run is never far from its end.
    static func tail(of file: URL, limit: Int = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// The exceptions in crash.log, oldest first. Each begins with the time
    /// it was thrown, as Date writes itself ("2026-10-05 11:35:28 +0000: "),
    /// and ends with an empty line; one cut by `tail` has no time and is left out.
    static func thrown(inLog text: String) -> [Thrown] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return text.components(separatedBy: "\n\n").compactMap { entry in
            let entry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard entry.count > 27, entry.dropFirst(25).hasPrefix(": "),
                  let at = formatter.date(from: String(entry.prefix(25))) else { return nil }
            return Thrown(at: at, text: entry)
        }
    }

    /// How long before its report is written an exception can have ended
    /// the run: the report follows the abort by seconds.
    static let thrownBefore: TimeInterval = 120

    /// The exceptions that ended the run a report written at `written`
    /// describes, cleaned: thrown in the two minutes before it, and after
    /// the reports sent at an earlier launch. An exception AppKit caught and
    /// lived through, long before, is not the crash's.
    static func exception(before written: Date, after last: Date, in thrown: [Thrown], home: String) -> String? {
        let near = thrown.filter {
            $0.at > last && $0.at <= written.addingTimeInterval(5) && $0.at >= written.addingTimeInterval(-thrownBefore)
        }
        guard !near.isEmpty else { return nil }
        return String(Sanitizer.clean(near.map(\.text).joined(separator: "\n\n"), home: home).prefix(16_000))
    }

    /// A file macOS is done writing: the same size and date a moment apart,
    /// and that date more than a few seconds old.
    static func settled(_ file: URL, wait: Duration, now: Date) async -> Bool {
        func look() -> (Int, Date)? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attributes[.size] as? Int, let date = attributes[.modificationDate] as? Date
            else { return nil }
            return (size, date)
        }
        guard let first = look(), now.timeIntervalSince(first.1) > 5 else { return false }
        if wait > .zero { try? await Task.sleep(for: wait) }
        guard let second = look() else { return false }
        return first.0 == second.0 && first.1 == second.1
    }

    /// One report read whole: trimmed when its body is JSON or once mended
    /// into JSON; raw and scrubbed when it can't be; held back while it may
    /// still be being written. Never the first line alone.
    static func prepared(_ report: String, home: String, bytes: Int, age: TimeInterval, name: String = "") -> Outcome {
        let lines = report.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(lines.first ?? "")
        let body = lines.count > 1 ? String(lines[1]) : ""
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.error("\(name, privacy: .public): \(bytes) bytes, no body")
            return age < patience ? .wait : .skip
        }
        let error: NSError
        do {
            return .send(Report(text: try trimmed(head: head, body: body, home: home), bytes: bytes))
        } catch let failed {
            error = failed as NSError
        }
        log.error("\(name, privacy: .public): \(bytes) bytes, body isn't JSON: \(error.debugDescription, privacy: .public)")
        if let kept = try? trimmed(head: head, body: mended(body), home: home) {
            return .send(Report(text: kept, bytes: bytes, parse: "mended"))
        }
        if !whole(body), age < patience { return .wait }
        let detail = (error.userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
        return .send(Report(text: scrubbed(head + "\n" + body, home: home), bytes: bytes, parse: "raw: " + detail))
    }

    /// The version and build of the Yab that crashed, from the report's
    /// first line. A report can wait for a later launch, by then of a newer
    /// Yab: 0.0.8 sent a 0.0.3 crash as its own (crash #9), and the
    /// newer build's symbols didn't fit it.
    static func madeBy(_ report: String) -> (version: String, build: String)? {
        let head = report.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let fields = try? JSONSerialization.jsonObject(with: Data(head.utf8)) as? [String: Any],
              let version = fields["app_version"] as? String, !version.isEmpty,
              let build = fields["build_version"] as? String, !build.isEmpty else { return nil }
        return (version, build)
    }

    /// What of the body finding a crash needs; the rest stays on this Mac.
    static let kept: Set<String> = [
        "uptime", "procRole", "version", "modelCode", "cpuType", "procName", "procPath", "bundleInfo", "buildInfo",
        "storeInfo", "parentProc", "osVersion", "captureTime", "codeSigningID", "codeSigningTeamID", "translated",
        "isCorpse", "incident", "exception", "termination", "faultingThread", "threads", "usedImages",
        "lastExceptionBacktrace", "legacyInfo", "asi", "asiBacktraces",
    ]
    /// What of a thread: its frames and where it was, not its registers.
    static let keptOfThread: Set<String> = ["id", "triggered", "name", "queue", "frames"]

    /// Positive fault-location evidence, not a diagnosis of stack exhaustion:
    /// another bad pointer can hit a guard too. Apple's arrow marks the region
    /// containing the fault. Unknown or conflicting evidence keeps no flag.
    private static func faultInStackGuard(in report: [String: Any]) -> Bool {
        // Do not round floating-point values or turn a Boolean into an address.
        func unsigned(_ value: Any) -> UInt64? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: number.objCType))
            else { return nil }
            return UInt64(number.stringValue)
        }
        guard let exception = report["exception"] as? [String: Any],
              exception["type"] as? String == "EXC_BAD_ACCESS",
              let codes = exception["rawCodes"] as? [Any], codes.count == 2,
              unsigned(codes[0]) == 2, // KERN_PROTECTION_FAILURE
              let address = unsigned(codes[1]),
              let region = report["vmRegionInfo"] as? String else { return false }
        let arrows = region.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { $0.hasPrefix("--->") }
        guard arrows.count == 1,
              let row = arrows[0].wholeMatch(of: #/^--->[ \t]+STACK[ \t]+GUARD[ \t]+([0-9A-Fa-f]{1,16})-([0-9A-Fa-f]{1,16})(?:[ \t]+.*)?$/#),
              let start = UInt64(row.1, radix: 16), let end = UInt64(row.2, radix: 16), start < end
        else { return false }
        return address >= start && address < end
    }

    /// An .ips as sent: its first line, the little JSON that names the app,
    /// then the body cut to `kept`, the home folder written ~. Throws what
    /// JSONSerialization says when the body isn't JSON.
    static func trimmed(head: String, body: String, home: String) throws -> String {
        guard let parsed = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue,
                          userInfo: [NSDebugDescriptionErrorKey: "The body isn't an object."])
        }
        var cut = parsed.filter { kept.contains($0.key) }
        if faultInStackGuard(in: parsed) { cut["faultInStackGuard"] = true }
        if let threads = cut["threads"] as? [[String: Any]] {
            cut["threads"] = threads.map { $0.filter { keptOfThread.contains($0.key) } }
        }
        // Why it crashed, in each library's words, cleaned; anything but
        // words stays here.
        if let asi = cut["asi"] as? [String: Any] {
            let words = asi.compactMapValues { value -> [String]? in
                let lines = (value as? [Any])?.compactMap { $0 as? String } ?? (value as? String).map { [$0] }
                return lines.map { $0.map { String(Sanitizer.clean($0, home: home).prefix(4000)) } }
            }
            cut["asi"] = words.isEmpty ? nil : words
        } else {
            cut["asi"] = nil
        }
        // Where an exception AppKit caught was thrown, as macOS writes it
        // when it ends the run (+[NSApplication _crashOnException:], an
        // exception out of a view's layout): the only frames that say whose
        // it was (crash #50). Frames keep their addresses, the rest is cleaned.
        let traces = (cut["asiBacktraces"] as? [Any])?.compactMap { $0 as? String }.map { backtrace(cleaned: $0, home: home) }
        cut["asiBacktraces"] = traces?.isEmpty == false ? traces : nil
        let json = try JSONSerialization.data(withJSONObject: cut, options: [.sortedKeys])
        return homeless(head + "\n" + String(decoding: json, as: UTF8.self), home: home)
    }

    /// A backtrace macOS wrote as text, one frame a line ("5  yab  0x1011…
    /// Fast_main + 11795492"): each frame's number, library and address as
    /// they are, the code's own ids, what follows them cleaned.
    static func backtrace(cleaned text: String, home: String) -> String {
        let frame = #/^(\s*\d+\s+\S+\s+0x[0-9A-Fa-f]+)(.*)$/#
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let match = line.wholeMatch(of: frame) else { return Sanitizer.clean(String(line), home: home) }
            return String(match.1) + Sanitizer.clean(String(match.2), home: home)
        }
        return String(lines.joined(separator: "\n").prefix(16_000))
    }

    /// The home folder's path, which names you, as ~. JSON may write the
    /// slashes escaped.
    static func homeless(_ text: String, home: String) -> String {
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home, with: "~")
            .replacingOccurrences(of: home.replacingOccurrences(of: "/", with: "\\/"), with: "~")
    }

    /// A body JSONSerialization turned down, mended where a report is known
    /// to slip: half of a surrogate pair without its other half becomes
    /// U+FFFD, a control character raw in a string is escaped.
    static func mended(_ body: String) -> String {
        let scalars = Array(body.unicodeScalars)
        var out = String.UnicodeScalarView()
        var inString = false, index = 0
        /// The UTF-16 unit a `\uXXXX` at `start` names.
        func unit(at start: Int) -> UInt16? {
            guard start + 5 < scalars.count, scalars[start] == "\\", scalars[start + 1] == "u" else { return nil }
            return UInt16(String(String.UnicodeScalarView(scalars[start + 2 ..< start + 6])), radix: 16)
        }
        while index < scalars.count {
            let scalar = scalars[index]
            guard inString else {
                if scalar == "\"" { inString = true }
                out.append(scalar)
                index += 1
                continue
            }
            if scalar == "\"" {
                inString = false
                out.append(scalar)
                index += 1
            } else if scalar == "\\" {
                if let code = unit(at: index), (0xD800 ... 0xDFFF).contains(code) {
                    if code < 0xDC00, let low = unit(at: index + 6), (0xDC00 ... 0xDFFF).contains(low) {
                        out.append(contentsOf: scalars[index ..< index + 12])
                        index += 12
                    } else {
                        out.append(contentsOf: "\\uFFFD".unicodeScalars)
                        index += 6
                    }
                } else {
                    out.append(contentsOf: scalars[index ..< min(index + 2, scalars.count)])
                    index += 2
                }
            } else if scalar.value < 0x20 {
                out.append(contentsOf: String(format: "\\u%04X", scalar.value).unicodeScalars)
                index += 1
            } else {
                out.append(scalar)
                index += 1
            }
        }
        return String(out)
    }

    /// Whether every brace and bracket the body opens it also closes, and no
    /// string is left open: false for a report cut short.
    static func whole(_ body: String) -> Bool {
        var depth = 0, inString = false, escaped = false
        for scalar in body.unicodeScalars {
            if inString {
                if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString = false }
                continue
            }
            switch scalar {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
        }
        return depth == 0 && !inString
    }

    /// What never leaves raw either: the memory map, the registers, the
    /// machine's and the user's ids, or an unverified derived flag.
    static let scrubbedKeys = ["vmSummary", "vmRegionInfo", "threadState", "crashReporterKey", "sleepWakeUUID", "bootSessionUUID",
                               "deviceIdentifierForVendor", "systemID", "userID", "faultInStackGuard"]
    /// What leaves raw only cleaned (Sanitizer): the failed check's message.
    static let cleanedKeys = ["asi", "asiBacktraces"]

    /// A body that isn't JSON even mended, as it is but for `scrubbedKeys`,
    /// each one's value written null wherever it stands, `cleanedKeys`,
    /// each one's value cleaned, and the home folder as ~.
    static func scrubbed(_ report: String, home: String) -> String {
        var text = report
        for key in scrubbedKeys + cleanedKeys {
            guard let pattern = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*") else { continue }
            var from = text.startIndex
            while let match = pattern.firstMatch(in: text, range: NSRange(from..., in: text)),
                  let range = Range(match.range, in: text) {
                let start = text.distance(from: text.startIndex, to: range.upperBound)
                let value = range.upperBound ..< valueEnd(in: text, from: range.upperBound)
                let replacement = cleanedKeys.contains(key) ? Sanitizer.clean(String(text[value]), home: home) : "null"
                text.replaceSubrange(value, with: replacement)
                from = text.index(text.startIndex, offsetBy: start + replacement.count)
            }
        }
        return homeless(text, home: home)
    }

    /// Where the JSON value at `start` ends: past its closing brace, bracket
    /// or quote, or at the comma or line ending after a bare word; the end
    /// of the text when it never closes.
    private static func valueEnd(in text: String, from start: String.Index) -> String.Index {
        var index = start, depth = 0, inString = false, escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    if depth == 0 { return text.index(after: index) }
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    if depth == 0 { return index }
                    depth -= 1
                    if depth == 0 { return text.index(after: index) }
                case ",", "\n", "\r", "\r\n":
                    if depth == 0 { return index }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    /// An .ips can also describe a hang or resource usage. Only Apple's
    /// crash report type (309) establishes that the app crashed.
    /// https://developer.apple.com/documentation/xcode/interpreting-the-json-format-of-a-crash-report
    static func isCrashReport(_ header: String, bundle: String) -> Bool {
        guard !bundle.isEmpty,
              let line = header.split(separator: "\n", maxSplits: 1).first,
              let info = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return false }
        return info["bundleID"] as? String == bundle && info["bug_type"] as? String == "309"
    }

    /// yab's own crash reports written after `date`, oldest first, in the
    /// folder and in its Retired, where macOS moves the ones it has handled.
    /// Saved reports can predate an update; finding one says nothing about
    /// the most recent quit or the currently running build.
    static func reports(after date: Date, bundle: String, folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")) -> [(URL, Date)] {
        var seen = Set<String>()
        let files = [folder, folder.appendingPathComponent("Retired")].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        return files.compactMap { file -> (URL, Date)? in
            guard file.pathExtension == "ips", file.lastPathComponent.hasPrefix("yab"),
                  seen.insert(file.lastPathComponent).inserted,
                  let written = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  written > date,
                  let handle = try? FileHandle(forReadingFrom: file)
            else { return nil }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 2048)) ?? Data(), as: UTF8.self)
            guard isCrashReport(head, bundle: bundle) else { return nil }
            return (file, written)
        }
        .sorted { $0.1 < $1.1 }
    }
}
