import Foundation

/// Opt-in for new profiles. An upgrade keeps folders people already use
/// running, including empty ones and folders in spaces not opened yet.
enum LiveFolderFeature {
    static let key = "live-folders.enabled"

    static func initial(in defaults: UserDefaults, folder: URL) -> Bool {
        if let chosen = defaults.object(forKey: key) as? Bool { return chosen }
        let enabled = hasSavedFolders(in: folder)
        defaults.set(enabled, forKey: key)
        return enabled
    }

    static func hasSavedFolders(in folder: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let name = file.lastPathComponent
            guard name == "empty-folders.json" || (name.hasPrefix("session") && name.hasSuffix(".json")),
                  let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if name == "empty-folders.json", let spaces = json as? [String: [[String: Any]]] {
                if spaces.values.joined().contains(where: { $0["live"] is [String: Any] }) { return true }
            } else if let shape = json as? [String: Any], let tabs = shape["tabs"] as? [[String: Any]],
                      tabs.contains(where: { $0["folderLive"] is [String: Any] }) {
                return true
            }
        }
        return false
    }
}
