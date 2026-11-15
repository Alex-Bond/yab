import WebKit

@MainActor
enum BoostApp {
    static func url(_ package: BoostPackage) -> URL? {
        guard let path = package.plugin.app else { return nil }
        return URL(string: "yab://" + package.id + ".boost/" + path)
    }
    static func package(at url: URL?, in signIn: UUID? = nil) -> BoostPackage? {
        guard let url, url.scheme == "yab", let host = url.host, host.hasSuffix(".boost") else { return nil }
        let id = String(host.dropLast(6))
        guard Boosts.shared.isEnabled(id, in: signIn), let package = Boosts.shared.packages[id], package.plugin.app != nil else { return nil }
        return package
    }
    static func resource(_ address: URL, main: URL?, in signIn: UUID? = nil) -> (Data, String)? {
        guard let package = package(at: address, in: signIn), main?.host == address.host,
              let text = package.files[String(address.path.dropFirst())] else { return nil }
        let path = String(address.path.dropFirst())
        guard BoostPackage.validPath(path), path.hasPrefix("app/") else { return nil }
        let type: String
        switch address.pathExtension {
        case "html": type = "text/html"
        case "css": type = "text/css"
        case "js": type = "text/javascript"
        case "json": type = "application/json"
        default: return nil
        }
        if type != "text/html" { return (Data(text.utf8), type) }
        // Each plugin has its own origin. No remote scripts, frames, forms or
        // credentials from browsing sessions are available to app pages.
        let policy = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        let shell = "<meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"\(policy)\"><style>:root{color-scheme:light dark;font:15px -apple-system}body{margin:24px}button,input,textarea{font:inherit}button{padding:7px 12px;border-radius:8px}</style><script>\(BoostAPI.script)</script>"
        return (Data((shell + text).utf8), type)
    }
    static func fit(_ controller: WKUserContentController, url: URL?) {
        controller.removeScriptMessageHandler(forName: "yabBoostAPI", contentWorld: .page)
        // The handler is harmless by itself: resources and every call check
        // the page's actual store. Attach it for an app kept in any profile.
        if let url, url.scheme == "yab", let host = url.host, host.hasSuffix(".boost"),
           let package = Boosts.shared.packages[String(host.dropLast(6))], package.plugin.app != nil {
            BoostAPI.shared.attachApp(controller, package: package)
        }
    }
}
