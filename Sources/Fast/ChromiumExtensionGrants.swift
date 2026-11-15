import Foundation

/// Compare the original Chrome manifest with the saved WebKit approval.
/// Optional permissions are not granted by importing the installed list.
enum ChromiumExtensionGrants {
    static func required(in manifest: [String: Any]) -> Set<String> {
        var grants = normalized(manifest["permissions"] as? [String] ?? [])
        grants.formUnion((manifest["host_permissions"] as? [String] ?? []).map { "site:" + $0 })
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            grants.formUnion((script["matches"] as? [String] ?? []).map { "site:" + $0 })
        }
        return grants
    }

    static func normalized(_ saved: [String]) -> Set<String> {
        Set(saved.map { value in
            if value.hasPrefix("site:") || value.hasPrefix("permission:") { return value }
            if value.contains("://") || value == "<all_urls>" { return "site:" + value }
            let name = value.hasPrefix("yab:") ? String(value.dropFirst(4)) : value
            return "permission:" + name
        })
    }
}

/// The install question's lines when Chrome cannot give its own warnings
/// (prebuilt CEF's management page lacks getPermissionWarningsByManifest):
/// Yab's own words for what WebKit knows, as WebKit Yab asks, then Chrome's
/// words for the permissions only Chrome grants.
enum ChromiumInstallWords {
    static let chromeOnly: [(String, String)] = [
        ("history", "Read and change your browsing history"),
        ("bookmarks", "Read and change your bookmarks"),
        ("readingList", "Read and change entries in the reading list"),
        ("topSites", "Read a list of your most frequently visited websites"),
        ("downloads", "Manage your downloads"),
        ("clipboardRead", "Read data you copy and paste"),
        ("geolocation", "Detect your physical location"),
        ("notifications", "Display notifications"),
        ("desktopCapture", "Capture content of your screen"),
        ("tabCapture", "Capture content of your screen"),
        ("privacy", "Change your privacy-related settings"),
        ("contentSettings", "Change which sites can use cookies, JavaScript, your location, camera and microphone"),
        ("management", "Manage your apps, extensions, and themes"),
        ("debugger", "Access the page debugger backend"),
        ("proxy", "Read and change every site you visit"),
    ]

    static func lines(manifest: [String: Any], yab: [String]) -> [String] {
        let declared = Set(manifest["permissions"] as? [String] ?? [])
        var out = yab
        for (name, sentence) in chromeOnly where declared.contains(name) && !out.contains(sentence) { out.append(sentence) }
        return out
    }
}
