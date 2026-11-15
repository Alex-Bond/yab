import Foundation

/// The host files password managers and other desktop apps leave for
/// Chrome, Edge, Brave or Arc, found where WebKit Yab finds them
/// (ExtensionNative.folders) and registered in CEF's user-data root for the
/// installed extensions they name, so a Chromium tab's extension reaches the
/// same app. Nothing is launched here; the app may still ask the user to
/// allow Yab (1Password: Settings › Browser › Add Browser).
enum ChromiumNativeHosts {
    static let adoptedList = ".yab-adopted.json"

    /// Registers every valid host allowing one of `installed`. A host Yab
    /// copied before is refreshed when its app changed it; one placed by
    /// hand (registerNativeHost) is never replaced.
    @discardableResult
    static func adopt(installed: Set<String>, dataRoot: URL, folders: [URL]) -> [String] {
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
                if adopted.contains(name), let old = try? Data(contentsOf: destination), old != data {
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
        let installed = Set(items.filter(\.enabled).map(\.id))
        guard !installed.isEmpty, installed != hostsAdoptedFor else { return }
        hostsAdoptedFor = installed
        let root = Store.file("Chromium")
        Task.detached(priority: .utility) {
            ChromiumNativeHosts.adopt(installed: installed, dataRoot: root, folders: ChromiumNativeHosts.folders())
        }
    }
}

extension ChromiumNativeHosts {
    static func folders() -> [URL] {
        if #available(macOS 15.4, *) { return ExtensionNative.folders }
        return []
    }
}
