import CryptoKit
import Foundation
import Security
import YabStore

// What an update is and how it is put in place, without a window: the feed,
// the rules for when a copy takes a release, and the swap of the bundle.
// Two processes use it: the app (Updater.swift), which checks every hour
// while it is up and says what it found, and YabUpdater, the small agent in
// the bundle that does the same while the app is closed. Both read and
// write the same settings (`Store.settings`), so a check made by one counts
// for the other.

public enum Update {
    /// Where the file lives: the YabFeed key build.sh writes into the
    /// bundle when it is given YAB_DOWNLOAD_URL. A build made without one
    /// has no feed, and then nothing here ever goes to the network, this
    /// copy is not updated from anyone's site. YAB_FEED points a test run
    /// somewhere else, and is the only way plain http is accepted. Only a
    /// test run: the browser people use reads its own feed, whatever the
    /// environment it was started with says.
    public static let feed: URL? = {
        if Store.testing, let set = ProcessInfo.processInfo.environment["YAB_FEED"], let url = URL(string: set) {
            return url
        }
        guard let set = Bundle.main.infoDictionary?["YabFeed"] as? String,
              let url = URL(string: set), url.scheme == "https"
        else { return nil }
        return url
    }()

    /// The site the feed is on, where feedback is written and crash
    /// reports are sent. None for a build with no feed.
    public static var site: URL? { feed?.deletingLastPathComponent() }

    /// macOS as a version number, the way the site counts it.
    public static var system: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Which Mac this process was built for, as the feed names it: "arm64" or
    /// "x86_64". It is the architecture of the slice that is running, so a
    /// universal build under Rosetta says x86_64. The site serves an
    /// arm64-only archive (a release goes out arm64 first, docs/release.md,
    /// "Intel Macs") to a check that says arm64 and to no other.
    public static var arch: String? {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return nil
        #endif
    }

    /// False for a build with no feed: no checks at launch, none on the hour,
    /// and Check Now answers without asking anyone.
    public static var enabled: Bool { feed != nil }

    public static var overridden: Bool {
        Store.testing && ProcessInfo.processInfo.environment["YAB_FEED"] != nil
    }

    /// What this app is: the version people read, and the build that
    /// decides whether another is newer.
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    public static var build: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// When the file was last read.
    public static let checkedKey = "update.checked"
    /// Every build, its fixes too (the site's nightly channel), rather than
    /// only the releases. Off, a copy is on Stable and is offered only what
    /// the site promoted to Stable, a manual check too: since every release
    /// is a new minor that soaks on Nightly first (2026-10-24), a Check Now
    /// that asked Nightly installed untested builds on Stable copies, as
    /// 0.43.0, held for taking every click, was on a Stable Mac (register
    /// 1689). A critical fix is put out to Stable directly.
    public static let nightlyKey = "update.nightly"
    /// When it is read again before the day is out: the moment a release
    /// waiting for this Mac's turn is due, or an hour after a critical one
    /// couldn't be put in place.
    public static let soonerKey = "update.sooner"
    /// A check an hour, so a critical fix reaches every copy that is up
    /// within one. It was a day: the copies that took 0.0.17's second build,
    /// whose window took no clicks, had just looked, and would have waited
    /// most of a day to look for its fix.
    public static let interval: TimeInterval = 60 * 60
    /// How soon a critical release that couldn't be put in place is tried
    /// again.
    public static let retry: TimeInterval = 60 * 60

    public struct Release: Equatable, Sendable, Codable {
        public let version: String
        public let build: Int
        /// The ZIP, for the updater.
        public let archive: URL
        /// The disk image, for people.
        public let dmg: URL
        /// Hex of the ZIP, when the feed gives one.
        public let sha256: String?
        public let notes: String?
        /// Where what's new in it is read, when the feed says.
        public var changelog: URL?
        public let minimumSystemVersion: String?
        /// A fix to restart for: every Mac takes it at once, never on its
        /// turn in a rollout.
        public var critical: Bool
        /// How many hours after `published` the last Macs take it; 0 for all
        /// at once.
        public var rolloutHours: Double
        /// When the site put it out.
        public var published: Date?

        public init(
            version: String, build: Int, archive: URL, dmg: URL, sha256: String?, notes: String?,
            changelog: URL? = nil, minimumSystemVersion: String?, critical: Bool = false,
            rolloutHours: Double = 0, published: Date? = nil
        ) {
            self.version = version
            self.build = build
            self.archive = archive
            self.dmg = dmg
            self.sha256 = sha256
            self.notes = notes
            self.changelog = changelog
            self.minimumSystemVersion = minimumSystemVersion
            self.critical = critical
            self.rolloutHours = rolloutHours
            self.published = published
        }

        /// A newer build is an update, whatever its version says: since
        /// 2026-10-24 every release is the next minor (0.40.0, 0.41.0), so
        /// the version tells nothing the build doesn't. When a copy takes
        /// it is Settle's and Rollout's: a Stable copy waits a day after its
        /// last update, a Nightly copy takes every build on its turn, and
        /// Check Now and critical fixes take it at once. Copies from before
        /// held a patch of their own minor back a day here; with counter
        /// numbering every release is a new minor for them, and only their
        /// own day from a build's first launch (on both channels) and the
        /// site's day between Stable promotions space their updates
        /// (docs/release.md, "Release cadence").
        public func isUpdate(from currentVersion: String, build currentBuild: Int, asked: Bool, now: Date = Date()) -> Bool {
            build > currentBuild
        }

        /// An older build that runs here: what a copy turned off Nightly
        /// builds on a build newer than Stable can go back to. Never an
        /// automatic update: only an explicit channel selection may install it.
        public func isBehind(build currentBuild: Int) -> Bool {
            build < currentBuild && runsHere
        }

        /// Whether this release is to take the place of `staged`, a build
        /// already swapped in and waiting for a restart: newer than it, and
        /// for this Mac. Without it, a copy that waited through a newer
        /// release restarted into the older one and at once offered the
        /// newer, an update for every release it missed (register 1365).
        public func replaces(_ staged: Release) -> Bool {
            build > staged.build && runsHere
        }

        /// A release that wants a newer macOS than this one is not newer for
        /// this Mac, and is not offered.
        public var runsHere: Bool {
            guard let need = minimumSystemVersion else { return true }
            let parts = need.split(separator: ".").map { Int($0) ?? 0 }
            let least = OperatingSystemVersion(
                majorVersion: parts.count > 0 ? parts[0] : 0,
                minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0
            )
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(least)
        }
    }

    /// Whether the file is to be read again: an hour after it last was, or
    /// sooner when something is waiting (`soonerKey`).
    public static func due(now: Date, in defaults: UserDefaults) -> Bool {
        let last = defaults.object(forKey: checkedKey) as? Date ?? .distantPast
        if now.timeIntervalSince(last) > interval { return true }
        guard let sooner = defaults.object(forKey: soonerKey) as? Date else { return false }
        return now >= sooner
    }

    /// The file, and whether the site answered at all (`reached`), which is
    /// when a failure said with the check has been heard. Always the saved
    /// channel's file, whoever asks: Check Now skips the waits (Settle,
    /// Rollout), never the channel.
    public static func fetch(failure: String?, again: Bool) async -> (reached: Bool, release: Release?) {
        guard let feed else { return (false, nil) }
        var request = URLRequest(url: checkURL(
            feed: feed, build: build, system: system, failure: failure, again: again,
            nightly: Store.settings.bool(forKey: nightlyKey), arch: arch
        ))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (false, nil) }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return (true, nil) }
        return (true, parse(data, allowingHTTP: overridden, architecture: arch))
    }

    /// What a check asks with: which build, on which macOS, once, why the
    /// last update couldn't be put in place, and whether this copy was
    /// counted today already (Count), on which channel, and which Mac it is
    /// (`arch`, "arm64" or "x86_64"; left out when nil, as copies from before
    /// it did). All the site counts; no id, and never the rollout's number.
    public static func checkURL(feed: URL, build: Int, system: String, failure: String?, again: Bool = false, nightly: Bool = false, arch: String? = nil) -> URL {
        var asked = URLComponents(url: feed, resolvingAgainstBaseURL: false)
        // A Nightly check must replace a channel already in the feed: the
        // site reads the first channel, so appending one would not win.
        let kept = (asked?.queryItems ?? []).filter { !nightly || $0.name != "channel" }
        var items = [URLQueryItem(name: "b", value: String(build)), URLQueryItem(name: "os", value: system)]
        if let arch { items.append(URLQueryItem(name: "arch", value: arch)) }
        if let failure { items.append(URLQueryItem(name: "fail", value: failure)) }
        if again { items.append(URLQueryItem(name: "again", value: "1")) }
        if nightly { items.append(URLQueryItem(name: "channel", value: "nightly")) }
        asked?.queryItems = kept + items
        return asked?.url ?? feed
    }

    /// The file as the site writes it (fast-web's appcast route). Anything
    /// missing or of the wrong kind in what an update needs, and there is no
    /// release; in the rest, the plain default.
    public static func parse(_ data: Data, allowingHTTP: Bool, architecture: String? = nil) -> Release? {
        func link(_ value: Any?) -> URL? {
            guard let url = (value as? String).flatMap(URL.init(string:)) else { return nil }
            guard url.scheme == "https" || (allowingHTTP && url.scheme == "http") else { return nil }
            return url
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let build = (json["build"] as? Int) ?? Int(json["build"] as? String ?? ""),
              let archive = link(json["url"]),
              let dmg = link(json["dmg"])
        else { return nil }
        // An arm64-only archive is for a copy that said arm64. If the site
        // ever names one to another Mac (a bug, a stale cache), there is no
        // release rather than an update that cannot open. The default keeps
        // the file's other readers as they were: only a check that says its
        // architecture can refuse.
        if let architecture, (json["arch"] as? String) == "arm64", architecture != "arm64" { return nil }
        let sha = (json["sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let notes = (json["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Hours, at most a month of them; nonsense is none.
        let hours = (json["rolloutHours"] as? NSNumber)?.doubleValue ?? 0
        return Release(
            version: version,
            build: build,
            archive: archive,
            dmg: dmg,
            sha256: sha.flatMap { $0.isEmpty ? nil : $0 },
            notes: notes.flatMap { $0.isEmpty ? nil : $0 },
            changelog: link(json["changelog"]),
            minimumSystemVersion: json["minimumSystemVersion"] as? String,
            critical: json["critical"] as? Bool ?? false,
            rolloutHours: hours.isFinite ? min(max(hours, 0), 24 * 30) : 0,
            published: (json["published"] as? String).flatMap(moment)
        )
    }

    /// A time as JSON writes a date, with or without its milliseconds.
    private static func moment(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// A release spread over hours. Each Mac rolls a number from 0 to 1 once
    /// and keeps it here; it never leaves the Mac. The Mac whose number is n
    /// takes the release n of the way through the hours after it came out,
    /// so half the Macs have it halfway through. Check Now and a critical
    /// release don't wait.
    public enum Rollout {
        public static let key = "update.dice"

        public static func dice(in defaults: UserDefaults) -> Double {
            if let kept = defaults.object(forKey: key) as? Double, kept >= 0, kept < 1 { return kept }
            let rolled = Double.random(in: 0 ..< 1)
            defaults.set(rolled, forKey: key)
            return rolled
        }

        /// When this Mac's turn comes, nil when it doesn't wait for one.
        public static func turn(_ release: Release, dice: Double) -> Date? {
            guard !release.critical, release.rolloutHours > 0, let published = release.published else { return nil }
            return published.addingTimeInterval(dice * release.rolloutHours * 60 * 60)
        }

        public static func due(_ release: Release, dice: Double, now: Date, asked: Bool) -> Bool {
            guard !asked, let turn = turn(release, dice: dice) else { return true }
            return now >= turn
        }
    }

    /// A day between updates on Stable. A Stable copy that took a build
    /// less than a day ago isn't offered the next one until that day is
    /// out, so even Stable builds promoted by hand the same afternoon don't
    /// ask anyone to restart twice. The day counts from when this Mac put
    /// the build it runs in place (`installedKey`, written by the swap), or,
    /// for a build it didn't swap in itself (a fresh install, a copy from
    /// before the key), from that build's first launch here. A Nightly copy
    /// takes every build at once, on its rollout turn. Check Now and a
    /// critical release don't wait on either channel.
    public enum Settle {
        public static let key = "update.settled"
        public static let buildKey = "update.settled.build"
        /// When this Mac's last update was put in place, and which build it
        /// was: the app and the closed-app agent write it after a swap.
        public static let installedKey = "update.installed"
        public static let installedBuildKey = "update.installed.build"
        public static let gap: TimeInterval = 24 * 60 * 60

        /// When this Mac started running `build`: the moment it was swapped
        /// in, else kept from its first launch.
        public static func since(build: Int, in defaults: UserDefaults, now: Date) -> Date {
            if defaults.integer(forKey: installedBuildKey) == build,
               let installed = defaults.object(forKey: installedKey) as? Date, installed <= now {
                return installed
            }
            if defaults.integer(forKey: buildKey) == build, let kept = defaults.object(forKey: key) as? Date, kept <= now {
                return kept
            }
            defaults.set(build, forKey: buildKey)
            defaults.set(now, forKey: key)
            return now
        }

        /// The swap put `build` in place now: the day before the next
        /// Stable update counts from here, not from its first launch, which
        /// may be hours later.
        public static func installed(build: Int, in defaults: UserDefaults, now: Date) {
            defaults.set(build, forKey: installedBuildKey)
            defaults.set(now, forKey: installedKey)
        }

        /// When the release may be taken, nil when now. Stable: the later of
        /// this Mac's turn in a rollout and a day after the last update.
        /// Nightly: the turn alone.
        public static func wait(_ release: Release, dice: Double, since: Date, now: Date, asked: Bool, nightly: Bool) -> Date? {
            guard !asked, !release.critical else { return nil }
            let day = nightly ? nil : since.addingTimeInterval(gap)
            let turn = [Rollout.turn(release, dice: dice), day].compactMap { $0 }.max()
            guard let turn, now < turn else { return nil }
            return turn
        }
    }

    /// Why the newer build couldn't be put in place, said once with the next
    /// check (`fail=`) and then forgotten, so the site can count what goes
    /// wrong. One word from a short list, nothing else about the Mac.
    public enum Failure {
        public static let key = "update.failed"
        /// What trying again within the hour won't change, and so the only
        /// failures that send the app to the disk image (Updater.landing).
        public static let lasting: Set<String> = [Swap.Refused.unsignedHere.rawValue, Swap.Refused.readOnly.rawValue]

        public static func reason(_ error: Error) -> String {
            if let refused = error as? Swap.Refused { return refused.rawValue }
            if error is URLError { return "network" }
            if error is CocoaError { return "files" }
            return "other"
        }

        public static func keep(_ reason: String, in defaults: UserDefaults) {
            defaults.set(reason, forKey: key)
        }

        public static func pending(in defaults: UserDefaults) -> String? {
            defaults.string(forKey: key)
        }

        /// The site has heard it: forgotten, unless another came meanwhile.
        public static func delivered(_ reason: String, in defaults: UserDefaults) {
            if defaults.string(forKey: key) == reason { defaults.removeObject(forKey: key) }
        }

        /// When to try again: within the hour for a critical release that
        /// failed for a reason that may pass, at the next day's check for
        /// the rest.
        public static func retry(_ release: Release, after reason: String, now: Date) -> Date? {
            guard release.critical, !lasting.contains(reason) else { return nil }
            return now.addingTimeInterval(Update.retry)
        }
    }

    /// The site counts copies a day by build and macOS, as when each looked
    /// once a day: after a copy's first check of the day (UTC, the site's
    /// day), its checks say `again`, and the site doesn't count those.
    public enum Count {
        public static let key = "update.counted"

        public static func day(_ date: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }

        public static func again(in defaults: UserDefaults, now: Date) -> Bool {
            defaults.string(forKey: key) == day(now)
        }

        /// The site answered, so it counted this copy today.
        public static func counted(in defaults: UserDefaults, now: Date) {
            defaults.set(day(now), forKey: key)
        }
    }
}

/// The part that touches the disk, off the main thread. Every step checks
/// before anything changes, and the only two things ever removed are the
/// scratch folder it made and the `.old` bundle it set aside.
public enum Swap {
    /// Each said to the site by its name (Update.Failure).
    public enum Refused: String, Error, CaseIterable {
        case unsignedHere, readOnly, download, hash, archive, plist, wrongApp, notNewer, unsigned, wrongTeam, move
    }

    /// Where the bundle lives, and so where the new one goes. The agent runs
    /// from inside it (Contents/MacOS), so its main bundle is the app too.
    public static var target: URL { Bundle.main.bundleURL }

    /// The bundle set aside during a swap: a sibling, so the move is a rename
    /// on the same volume and not a copy.
    static var aside: URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".old")
    }

    /// A verified download waits outside the running bundle. Chromium's
    /// sandbox grants name the bundle paths at engine startup: following a
    /// rename with an fd does not move those grants with the files.
    public struct Prepared: Codable {
        public let release: Update.Release
        public let allowDowngrade: Bool
    }

    static func preparationRoot(at place: URL) -> URL {
        place.deletingLastPathComponent().appendingPathComponent("." + place.lastPathComponent + ".update")
    }

    static func preparedApp(at place: URL) -> URL {
        preparationRoot(at: place).appendingPathComponent("incoming.app")
    }

    public static var prepared: Prepared? {
        let root = preparationRoot(at: target)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("release.json")),
              let waiting = try? JSONDecoder().decode(Prepared.self, from: data),
              let incoming = info(of: preparedApp(at: target)),
              incoming["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              Int(incoming["CFBundleVersion"] as? String ?? "") == waiting.release.build
        else { return nil }
        return waiting
    }

    /// The only transaction here replaces a previous prepared download.
    /// The installed app is never renamed, even when another release arrives.
    static func prepare(_ fresh: URL, release: Update.Release, allowDowngrade: Bool,
                        replacing staged: Int?, scratch: URL, at place: URL,
                        identifier: String?) throws {
        let files = FileManager.default
        let root = preparationRoot(at: place), incoming = preparedApp(at: place)
        guard let identifier else { throw Refused.move }
        if files.fileExists(atPath: root.path) {
            guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { throw Refused.move }
            guard files.fileExists(atPath: incoming.path) else { throw Refused.move }
        }
        if files.fileExists(atPath: incoming.path) {
            guard let previous = info(of: incoming), previous["CFBundleIdentifier"] as? String == identifier,
                  let build = Int(previous["CFBundleVersion"] as? String ?? ""), staged == nil || staged == build
            else { throw Refused.move }
        } else if staged != nil { throw Refused.move }
        // Payload and selection are one directory transaction. A failed
        // metadata write must not replace the previously ready download.
        let next = scratch.appendingPathComponent("preparing")
        try files.createDirectory(at: next, withIntermediateDirectories: true)
        let waiting = Prepared(release: release, allowDowngrade: allowDowngrade)
        try JSONEncoder().encode(waiting).write(to: next.appendingPathComponent("release.json"), options: .atomic)
        try files.moveItem(at: fresh, to: next.appendingPathComponent("incoming.app"))
        let previous = scratch.appendingPathComponent("previous-preparation")
        let existed = files.fileExists(atPath: root.path)
        if existed { try files.moveItem(at: root, to: previous) }
        do { try files.moveItem(at: next, to: root) }
        catch {
            if existed { try? files.moveItem(at: previous, to: root) }
            throw Refused.move
        }
    }

    /// Only the sealed helper, after the app and its engine have exited.
    /// Recheck the signature and exact selected build before touching the app.
    public static func completePrepared(build: Int, proceed: () -> Bool) throws {
        guard let waiting = prepared, waiting.release.build == build else { throw Refused.plist }
        guard let team = teamID(of: target) else { throw Refused.unsignedHere }
        guard let current = info(of: target), current["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let currentBuild = Int(current["CFBundleVersion"] as? String ?? "")
        else { throw Refused.plist }
        try checkBuild(build, current: currentBuild, selected: build, allowDowngrade: waiting.allowDowngrade)
        let fresh = preparedApp(at: target), root = preparationRoot(at: target)
        try verify(fresh, team: team, selected: build, allowDowngrade: waiting.allowDowngrade)
        guard proceed() else { throw Stopped() }
        try swap(fresh)
        Update.Settle.installed(build: build, in: Store.settings, now: Date())
        try? FileManager.default.removeItem(at: root)
        sweep()
    }

    /// `proceed` is asked once more just before the two renames, after the
    /// download and the checks: the agent says no if the app was opened
    /// meanwhile, and the bundle is left as it was (`Stopped`).
    ///
    /// `replacing`, the build this run already swapped in (still waiting for
    /// its restart): the new one takes that one's place, and the bundle this
    /// process runs from, set aside as `.old`, is left alone (`replace`).
    /// `allowDowngrade` is only for an explicitly confirmed channel switch;
    /// feed checks and the background agent leave it false.
    public static func install(_ release: Update.Release, replacing staged: Int? = nil, allowDowngrade: Bool = false,
                               deferUntilExit: Bool = false, proceed: () -> Bool = { true }) async throws {
        let files = FileManager.default
        // No Team ID on this build means it was signed ad hoc, a development
        // build. Nothing is ever swapped in under an app that could not be
        // told apart from anything else.
        guard let team = teamID(of: target) else { throw Refused.unsignedHere }
        // The folder the app is in has to take a rename, or nothing here can
        // be done: /Applications owned by another account, a disk image.
        guard files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Refused.readOnly
        }

        // A scratch folder on the same volume as the app, so the last move is
        // a rename too. Cleared whatever happens.
        let scratch = (try? files.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true
        )) ?? files.temporaryDirectory.appendingPathComponent("yab-update-\(release.build)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            forgetRegistration(in: scratch)
            try? files.removeItem(at: scratch)
        }

        let zip = scratch.appendingPathComponent("yab.zip")
        try await download(release.archive, to: zip)
        // No checksum, no update: the feed says what the ZIP is, or the
        // ZIP isn't taken.
        guard let expected = release.sha256, try digest(of: zip) == expected else { throw Refused.hash }
        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        try extract(zip, into: unpacked)
        guard let fresh = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw Refused.archive }
        try verify(fresh, team: team, above: staged, selected: release.build, allowDowngrade: allowDowngrade)
        // Verification can expose the unpacked app to LaunchServices.
        // It is only a staging copy, never an application to launch.
        forgetRegistration(in: fresh)
        guard proceed() else { throw Stopped() }
        if deferUntilExit {
            let place = target, identifier = Bundle.main.bundleIdentifier
            try await MainActor.run {
                try prepare(fresh, release: release, allowDowngrade: allowDowngrade,
                            replacing: staged, scratch: scratch, at: place, identifier: identifier)
            }
            return
        }
        guard let staged else { return try swap(fresh) }
        // On the main thread, where a quit is decided: a Restart pressed
        // meanwhile finds one build or the other in place, never neither.
        let place = target
        try await MainActor.run { try replace(staged, with: fresh, scratch: scratch, at: place) }
    }

    /// The swap was called off before anything moved. Not a failure: nothing
    /// is said to the site, and the next check tries again.
    public struct Stopped: Error {}

    private static func download(_ url: URL, to file: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        let (got, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            throw Refused.download
        }
        // The session's copy lasts only until this returns.
        try FileManager.default.moveItem(at: got, to: file)
    }

    private static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            sha.update(data: chunk)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// ditto, the way Archive Utility does it: permissions kept. Quarantine
    /// never comes into it, the app declares no LSFileQuarantineEnabled, so
    /// nothing it downloads carries the flag, and there is none to strip.
    /// Keep it that way: the checking is done here, in verify, not by
    /// Gatekeeper at the next launch.
    private static func extract(_ zip: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.runValidated()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Refused.archive }
    }

    /// The archive must contain precisely the build selected from the feed.
    /// Older builds remain refused unless the person explicitly chose a channel.
    static func checkBuild(_ incoming: Int, current: Int, staged: Int? = nil,
                           selected: Int, allowDowngrade: Bool = false) throws {
        guard incoming > 0, incoming == selected else { throw Refused.plist }
        guard incoming > max(current, staged ?? 0)
                || (allowDowngrade && incoming != (staged ?? current)) else { throw Refused.notNewer }
    }

    /// A bundle is not trusted because it arrived. It is trusted because it
    /// is this app at the selected build, with a Developer ID signature from the same team
    /// as the one running that holds up under the strict check, for every
    /// architecture and everything nested inside it.
    private static func verify(_ bundle: URL, team: String, above staged: Int? = nil, selected: Int, allowDowngrade: Bool) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Refused.plist }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Refused.wrongApp
        }
        try checkBuild(Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                       current: Update.build, staged: staged, selected: selected, allowDowngrade: allowDowngrade)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw Refused.unsigned
        }
        guard let identifier = Bundle.main.bundleIdentifier,
              let requirement = developerID(team: team, identifier: identifier)
        else { throw Refused.unsigned }
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess else { throw Refused.unsigned }
        guard teamID(of: bundle) == team else { throw Refused.wrongTeam }
    }

    /// What every Developer ID app of this team meets, as `codesign -d -r-`
    /// prints it for a shipped yab: Apple's anchor, the Developer ID
    /// intermediate (…6.2.6) and a Developer ID Application leaf (…6.1.13)
    /// with this team in it, for this bundle id.
    public static func developerID(team: String, identifier: String) -> SecRequirement? {
        let text = "anchor apple generic and identifier \"\(identifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The team that signed a bundle, as the system reads it, nil for an
    /// ad-hoc signature, or none.
    private static func teamID(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let signing = info as? [String: Any]
        else { return nil }
        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Two renames, and the first one undone if the second fails. The app
    /// that is running keeps its files: the kernel follows the rename, so it
    /// goes on running from `.old`, and validating as itself, which is what
    /// its keychain items are checked against, until it quits.
    private static func swap(_ fresh: URL) throws {
        let files = FileManager.default
        sweep()
        guard !files.fileExists(atPath: aside.path) else { throw Refused.move }
        try files.moveItem(at: target, to: aside)
        do {
            try files.moveItem(at: fresh, to: target)
        } catch {
            try? files.moveItem(at: aside, to: target)
            throw Refused.move
        }
        forgetRegistration(in: aside)
        registration(target, remove: false)
    }

    /// A newer build in place of the one swapped in earlier in this run.
    /// The bundle in place is checked to be that one, this app at that
    /// build, before it moves; it goes into the scratch folder, which is
    /// cleared after, and comes back if the new one can't go in. The bundle
    /// this process runs from (`.old`) is never touched.
    public static func replace(
        _ staged: Int, with fresh: URL, scratch: URL, at place: URL,
        identifier: String? = Bundle.main.bundleIdentifier,
        registrationChanged: ((URL, Bool) -> Void)? = nil
    ) throws {
        let files = FileManager.default
        guard let identifier, let info = info(of: place), info["CFBundleIdentifier"] as? String == identifier,
              Int(info["CFBundleVersion"] as? String ?? "") == staged
        else { throw Refused.move }
        // Unregister the still-existing staging bundle before moving it;
        // lsregister cannot inspect a path once its bundle has moved away.
        if let registrationChanged { registrationChanged(fresh, true) }
        else { forgetRegistration(in: fresh) }
        let old = scratch.appendingPathComponent("replaced.app")
        try files.moveItem(at: place, to: old)
        do {
            try files.moveItem(at: fresh, to: place)
        } catch {
            try? files.moveItem(at: old, to: place)
            throw Refused.move
        }
        if let registrationChanged {
            registrationChanged(old, true)
            registrationChanged(place, false)
        } else {
            // The old staging path and the replaced copy must not survive
            // in Launchpad; only the successfully installed path is kept.
            forgetRegistration(in: old)
            registration(place, remove: false)
        }
    }

    private static func info(of bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Removes the bundle a swap set aside, once nothing runs from it any
    /// more: at quit, and at the next launch in case the quit was not a
    /// clean one, and by the agent right after its own swap, since the app
    /// was closed. Only ever a `.old` that is this app, and only while this
    /// app is in place beside it, so a quit can never leave neither;
    /// nothing else is ever deleted here.
    public static func sweep() {
        sweep(aside, beside: target, identifier: Bundle.main.bundleIdentifier)
    }

    public static func sweep(_ aside: URL, beside place: URL, identifier: String?) {
        guard let identifier,
              info(of: aside)?["CFBundleIdentifier"] as? String == identifier,
              info(of: place)?["CFBundleIdentifier"] as? String == identifier
        else { return }
        forgetRegistration(in: aside)
        try? FileManager.default.removeItem(at: aside)
    }

    /// Only bundles owned by this update transaction. Never sweep another
    /// installed/dev app by identifier or reset the person's LS database.
    private static func forgetRegistration(in root: URL) {
        let files = FileManager.default
        if info(of: root) != nil { registration(root, remove: true) }
        guard let entries = files.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in entries where url.pathExtension == "app" {
            registration(url, remove: true)
        }
    }

    private static func registration(_ bundle: URL, remove: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        process.arguments = (remove ? ["-u"] : ["-f"]) + [bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // LS maintenance is best effort: failure must not undo a verified
        // update or delete the only remaining valid copy.
        try? process.runValidated()
        if process.isRunning { process.waitUntilExit() }
    }
}
