import SwiftUI
import WebKit

/// WebKit renders SVG and raster manifest images using the site's cookie store.
/// Script stays disabled in these small, inert image documents.
struct DevApplicationImage: NSViewRepresentable {
    var url: String
    var origin: String
    var store: WKWebsiteDataStore
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.processPool = Web.pool; config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.source != url + origin else { return }; context.coordinator.source = url + origin
        guard let image = URL(string: url), ["http", "https", "data", "blob"].contains(image.scheme ?? "") else { return }
        let escaped = image.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        view.loadHTMLString("<!doctype html><meta name=viewport content='width=device-width'><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}img{width:100%;height:100%;object-fit:contain}</style><img alt='Manifest image' src=\"" + escaped + "\">", baseURL: URL(string: origin))
    }
    final class Coordinator { var source = "" }
}
