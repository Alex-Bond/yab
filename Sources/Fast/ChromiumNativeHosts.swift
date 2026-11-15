import Foundation

/// The host files password managers and other desktop apps leave for
/// Chrome, Edge, Brave or Arc, found where WebKit Yab finds them
/// (ExtensionNative.folders) and registered in CEF's user-data root for the
/// installed extensions they name, so a Chromium tab's extension reaches the
/// same app. Nothing is launched here; the app may still ask the user to
/// allow Yab (1Password: Settings › Browser › Add Browser).
enum ChromiumNativeHosts {
    static let adoptedList = ".yab-adopted.json"
    static let onePasswordName = "com.1password.1password"
    static let onePasswordIDs: Set<String> = ["aeblfdkhhhdcdjpifhhbdiojplfjncoa", "khgocmkkpikpnmmkgmdnfckapcdkgfaf"]
    static let onePasswordHelper = URL(fileURLWithPath: "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport")

    /// Repair only our previously adopted Apple and 1Password entries before
    /// CEF starts its persisted workers: their wrappers name this app's path,
    /// and 1Password's of 0.46.24 and older still launches straight from
    /// YabCore. A hand-registered host is not ours to rewrite.
    static func refreshAppleBeforeLaunch(dataRoot: URL) {
        let ledger = dataRoot.appendingPathComponent("NativeMessagingHosts/" + adoptedList)
        let known = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: ledger))) ?? []
        var installed: Set<String> = []
        if known.contains(ChromiumNativeHostLauncher.apple) { installed.formUnion(["pejdijmoenmkgeppbflobdenhhabjlaj", "mfbcdcnpokpoajjciilocoachedjkima"]) }
        if known.contains(onePasswordName) { installed.formUnion(onePasswordIDs) }
        guard !installed.isEmpty else { return }
        adopt(installed: installed, dataRoot: dataRoot, folders: folders())
    }

    /// Registers every valid host allowing one of `installed`. A host Yab
    /// copied before is refreshed when its app changed it; one placed by
    /// hand (registerNativeHost) is never replaced.
    @discardableResult
    static func adopt(installed: Set<String>, dataRoot: URL, folders: [URL], onePasswordHelper: URL? = ChromiumNativeHosts.onePasswordHelper) -> [String] {
        let files = FileManager.default
        let target = dataRoot.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        let ledger = target.appendingPathComponent(adoptedList)
        var adopted = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: ledger))) ?? [])
        var done: [String] = []
        var seen = Set<String>()
        for folder in folders {
            guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in names.sorted() where file.hasSuffix(".json") {
                let source = folder.appendingPathComponent(file)
                let name = String(file.dropLast(5))
                // The first folder that has a name wins, as Chromium's own order.
                guard !seen.contains(name) else { continue }
                // Chromium finds a host only by its own name's file.
                guard let data = try? Data(contentsOf: source), data.count <= 1024 * 1024,
                      (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String == name else { continue }
                let destination = target.appendingPathComponent(file)
                // A copy Yab made follows its app's file, and the wrapper
                // a routed host now needs (1Password before 0.46.25).
                if adopted.contains(name), let old = try? Data(contentsOf: destination),
                   old != ChromiumNativeMessaging.expected(manifestAt: source, dataRoot: dataRoot) {
                    try? files.removeItem(at: destination)
                }
                if let registration = try? ChromiumNativeMessaging.register(manifestAt: source, dataRoot: dataRoot, installed: installed),
                   registration.name == name {
                    seen.insert(name)
                    adopted.insert(name)
                    done.append(name)
                }
            }
        }
        // Like WebKit's ExtensionNative.host: the desktop app may be installed
        // without another browser ever writing its host manifest. Only the
        // vendor's two store extensions can use this known helper. An existing
        // source manifest (even a refusal/malformed one) remains authoritative,
        // and a hand-registered destination is never replaced. Its manifest
        // is kept beside the wrappers: the routed wrapper reads it again at
        // every launch (ChromiumNativeHostLauncher.program).
        let placed = target.appendingPathComponent(onePasswordName + ".json")
        let kept = target.appendingPathComponent(".yab-launchers/" + onePasswordName + ".json")
        if !installed.isDisjoint(with: onePasswordIDs),
           !folders.contains(where: { files.fileExists(atPath: $0.appendingPathComponent(onePasswordName + ".json").path) }),
           let helper = onePasswordHelper, helper.path.hasPrefix("/"),
           files.isExecutableFile(atPath: helper.path) {
            do {
                let manifest: [String: Any] = ["name": onePasswordName, "description": "1Password desktop app",
                    "type": "stdio", "path": helper.path,
                    "allowed_origins": onePasswordIDs.sorted().map { "chrome-extension://" + $0 + "/" }]
                let data = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
                if let old = try? Data(contentsOf: placed) {
                    // Placed by hand, or already Yab's and current: left as it is.
                    let current = (try? Data(contentsOf: kept)) == data
                        && old == ChromiumNativeMessaging.expected(manifestAt: kept, dataRoot: dataRoot)
                    guard adopted.contains(onePasswordName), !current else { throw CocoaError(.fileWriteFileExists) }
                    try files.removeItem(at: placed)
                }
                try files.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if (try? Data(contentsOf: kept)) != data { try data.write(to: kept, options: .atomic) }
                let registration = try ChromiumNativeMessaging.register(manifestAt: kept, dataRoot: dataRoot, installed: installed)
                adopted.insert(registration.name)
                done.append(registration.name)
            } catch {
                // Discovery is best effort, as it is for the on-disk manifests.
            }
        }
        if !done.isEmpty, let data = try? JSONEncoder().encode(adopted.sorted()) {
            try? data.write(to: ledger, options: .atomic)
        }
        return done
    }
}

@MainActor
extension ChromiumExtensions {
    /// After the installed list changes, at most once per set.
    func adoptNativeHosts() {
        ChromiumExtensions.hearOnePassword()
        let installed = Set(items.filter(\.enabled).map(\.id))
        guard !installed.isEmpty, installed != hostsAdoptedFor else { return }
        hostsAdoptedFor = installed
        let root = Store.file("Chromium")
        Task.detached(priority: .utility) {
            ChromiumNativeHosts.adopt(installed: installed, dataRoot: root, folders: ChromiumNativeHosts.folders())
        }
    }
}

@MainActor
extension ChromiumExtensions {
    private static var hearing = false

    /// 1Password's app refusing or answering a Chromium tab's extension, as
    /// the routed launcher hears it (ChromiumNativeHostLauncher.Frames): the
    /// same row in Settings › Passwords and the same card, once, as on
    /// WebKit tabs (Extensions.appUnreached).
    static func hearOnePassword() {
        guard !hearing else { return }
        hearing = true
        let center = DistributedNotificationCenter.default()
        for (name, refused) in [(ChromiumNativeHostLauncher.refusedNotice, true), (ChromiumNativeHostLauncher.answeredNotice, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let id = note.object as? String, ChromiumNativeHosts.onePasswordIDs.contains(id) else { return }
                MainActor.assumeIsolated {
                    guard #available(macOS 15.4, *) else { return }
                    if refused { Extensions.here.appUnreached(id, host: ChromiumNativeHosts.onePasswordName) }
                    else { Extensions.here.appReached(id, host: ChromiumNativeHosts.onePasswordName) }
                }
            }
        }
    }
}

extension ChromiumNativeHosts {
    static func folders() -> [URL] {
        if #available(macOS 15.4, *) { return ExtensionNative.folders }
        return []
    }
}
