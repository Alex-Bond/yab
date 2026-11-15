import Foundation
import UniformTypeIdentifiers
import WebKit

/// Test pages from inside the app, never the internet: `yab-page://<stem>`
/// is Pages/<stem>.html in the app (Phone/Resources/Pages). Inside a page,
/// relative addresses resolve under its stem: `yab-page://<stem>/Favicons/x.png`
/// is the app's Favicons/x.png, anything else Pages/<path>.
/// A query is the page's own (blank.html reads its words from it).
@MainActor
final class PageSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "yab-page"

    /// Where the app keeps its resource folders: Yab.app itself.
    nonisolated static var resources: URL? { Bundle.main.resourceURL }

    /// The page for a stem, if the app carries it.
    nonisolated static func hasPage(_ stem: String) -> Bool {
        guard let url = resources?.appendingPathComponent("Pages/\(stem).html") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Where a yab-page address's file is.
    nonisolated static func file(for url: URL) -> URL? {
        guard let resources, let stem = url.host(percentEncoded: false), !stem.isEmpty else { return nil }
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative: String
        if path.isEmpty {
            relative = "Pages/\(stem).html"
        } else if path.hasPrefix("Favicons/") {
            relative = path
        } else {
            relative = "Pages/\(path)"
        }
        // Nothing outside the app's own folders, whatever the path says.
        let file = resources.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(resources.standardizedFileURL.path) else { return nil }
        return file
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url ?? URL(string: "\(Self.scheme)://blank")!
        guard let file = Self.file(for: url), let data = try? Data(contentsOf: file) else {
            let missing = Data("<!doctype html><meta charset=utf-8><title>Missing</title><p>No test page for \(url.absoluteString)</p>".utf8)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
            task.didReceive(missing)
            task.didFinish()
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let mime = type.hasPrefix("text/") ? type + "; charset=utf-8" : type
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": mime, "Content-Length": String(data.count),
                                                       "Cache-Control": "no-store"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

extension Tab {
    /// The address its page loads from: its test page, else blank.html in the
    /// site's look, its words in the query.
    var pageURL: URL {
        if let page, PageSchemeHandler.hasPage(page) {
            return URL(string: "\(PageSchemeHandler.scheme)://\(page)")!
        }
        var parts = URLComponents()
        parts.scheme = PageSchemeHandler.scheme
        parts.host = "blank"
        parts.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "site", value: site),
                            URLQueryItem(name: "icon", value: icon)]
        return parts.url!
    }
}
