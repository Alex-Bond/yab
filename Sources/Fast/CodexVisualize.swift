import AppKit

// writes a picture as an HTML fragment of its own, a file under
// ~/.codex/visualizations, and names it in its answer with a marker of
// private-use characters: U+E200, the entity's name, U+E202, its JSON
// arguments, U+E201. "visualize" is one entity; others (its citations)
// are Codex's app's own. Yab cuts every marker out of the words, makes a
// visualize one a widget step in its place, and draws its file the way
// Codex's bundled plugin does (its scripts/render.py), in Yab's look.

enum CodexVisualize {
    static let open: Unicode.Scalar = "\u{E200}"
    static let separator: Unicode.Scalar = "\u{E202}"
    static let close: Unicode.Scalar = "\u{E201}"

    /// One marker: its name and the string values of its arguments.
    struct Entity: Equatable {
        var name: String
        var arguments: [String: String]?
    }

    enum Piece: Equatable {
        case words(String)
        case entity(Entity)
    }

    static func marked(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == open || $0 == close || $0 == separator }
    }

    /// The text cut at its markers. A marker still being written (no
    /// U+E201 yet) is dropped with all after it; a stray separator or
    /// close is dropped alone. Arguments that aren't a JSON object are nil.
    static func pieces(_ text: String) -> [Piece] {
        guard marked(text) else { return text.isEmpty ? [] : [.words(text)] }
        var out: [Piece] = []
        var words = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func flush() {
            if !words.isEmpty { out.append(.words(String(words))) }
            words = String.UnicodeScalarView()
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == open {
                guard let end = scalars[(index + 1)...].firstIndex(of: close) else { break }
                let inner = scalars[(index + 1)..<end]
                let name: String, raw: String
                if let gap = inner.firstIndex(of: separator) {
                    name = String(String.UnicodeScalarView(inner[inner.startIndex..<gap]))
                    raw = String(String.UnicodeScalarView(inner[(gap + 1)...]))
                } else {
                    name = String(String.UnicodeScalarView(inner))
                    raw = ""
                }
                flush()
                out.append(.entity(Entity(name: name.trimmingCharacters(in: .whitespaces), arguments: arguments(raw))))
                index = end + 1
                continue
            }
            if scalar != close, scalar != separator { words.append(scalar) }
            index += 1
        }
        flush()
        return out
    }

    private static func arguments(_ raw: String) -> [String: String]? {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, value) in object {
            if let value = value as? String { out[key] = value }
            else if let value = value as? NSNumber { out[key] = value.stringValue }
        }
        return out
    }

    /// The words alone, every marker out: for rows, summaries, copies.
    static func stripped(_ text: String) -> String {
        guard marked(text) else { return text }
        return pieces(text).compactMap { piece -> String? in
            if case .words(let words) = piece { return words }
            return nil
        }.joined()
    }

    /// A widget a visualize marker stands for; nil for another entity, or
    /// one with no file named.
    static func widget(_ entity: Entity, id: String) -> ChatItem? {
        guard entity.name == "visualize", let path = entity.arguments?["path"], !path.isEmpty else { return nil }
        let given = (entity.arguments?["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var extra = ["widgetFile": path, "widgetKit": "codex", "widgetTitle": given.isEmpty ? title(path) : given]
        if let mode = entity.arguments?["mode"], !mode.isEmpty { extra["widgetMode"] = mode }
        return ChatItem(id: id, kind: .widget, name: "visualize", state: .done, extra: extra)
    }

    /// The file's name as a title, as render.py makes one: "google-meet-pip"
    /// reads "Google Meet Pip".
    static func title(_ path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let words = stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").split(separator: " ")
        let out = words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        return out.isEmpty ? "Visualization" : out
    }

    /// A Codex message as the chat's steps: its words, cut where it drew,
    /// a widget in each place. The first step keeps the message's id, so
    /// the words streamed under it give way; the rest are "<id>.<n>".
    /// `clean` tidies each run of words (nil when nothing is left of it).
    static func steps(_ text: String, id: String, state: ChatItem.State,
                      clean: (String) -> String?) -> [ChatItem] {
        guard marked(text) else {
            return clean(text).map { [ChatItem(id: id, kind: .message, text: $0, state: state)] } ?? []
        }
        var out: [ChatItem] = []
        var words = ""
        func next() -> String { out.isEmpty ? id : id + ".\(out.count)" }
        // Words run on over a marker that draws nothing.
        func said() {
            defer { words = "" }
            guard let kept = clean(words) else { return }
            out.append(ChatItem(id: next(), kind: .message, text: kept, state: state))
        }
        for piece in pieces(text) {
            switch piece {
            case .words(let more):
                words += more
            case .entity(let entity):
                guard widget(entity, id: "") != nil else { continue }
                said()
                if let widget = widget(entity, id: next()) { out.append(widget) }
            }
        }
        said()
        return out
    }
}

// MARK: - The plugin's kit

extension CodexVisualize {
    /// What Codex's bundled plugin wraps a fragment in (its
    /// skills/visualize/assets): the stylesheet, the inner kit (tooltips,
    /// tabs, carousel, icons), the bridge giving the fragment
    /// window.openai, the standalone shell, and the calendar element.
    struct Kit: Equatable {
        var stylesheet: String
        var inner: String
        var bridge: String
        var shell: String
        var calendar: String
        var version: String = ""
    }

    static let placeholder = "<!--__INLINE_VISUALIZATION_FRAGMENT__-->"
    static let stateMark = "__CODEX_VISUALIZATION_WIDGET_STATE__"
    static let most = 1_000_000

    /// The plugin's homes: the Codex home the fragment lives under (its
    /// "visualizations" folder's parent), then ~/.codex.
    static func homes(for fragment: String) -> [URL] {
        var out: [URL] = []
        if let range = fragment.range(of: "/visualizations/") {
            out.append(URL(fileURLWithPath: String(fragment[..<range.lowerBound])))
        }
        out.append(AgentSetup.home.appendingPathComponent(".codex"))
        return out
    }

    /// The newest installed version of the plugin's skill folder.
    static func skill(in home: URL) -> (dir: URL, version: String)? {
        let root = home.appendingPathComponent("plugins/cache/openai-bundled/visualize")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let newest = versions.filter { !$0.hasPrefix(".") }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        for version in newest.reversed() {
            let dir = root.appendingPathComponent(version).appendingPathComponent("skills/visualize")
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("assets/visualize.css").path) { return (dir, version) }
        }
        return nil
    }

    @MainActor private static var kits: [String: Kit] = [:]

    /// The kit for a fragment, read once per installed version; nil when
    /// the plugin isn't on this Mac.
    @MainActor static func kit(for fragment: String) -> Kit? {
        for home in homes(for: fragment) {
            guard let found = skill(in: home) else { continue }
            let key = found.dir.path
            if let kept = kits[key] { return kept }
            let assets = found.dir.appendingPathComponent("assets")
            func read(_ name: String) -> String? { try? String(contentsOf: assets.appendingPathComponent(name), encoding: .utf8) }
            guard let stylesheet = read("visualize.css"), let inner = read("visualize.html"),
                  let bridge = read("standalone-host-bridge.js") else { continue }
            let kit = Kit(stylesheet: stylesheet, inner: inner, bridge: bridge, shell: read("standalone-shell.js") ?? "",
                          calendar: read("calendar.js") ?? "", version: found.version)
            kits[key] = kit
            return kit
        }
        return nil
    }

    /// The fragment's words from its file: a regular file, at most 1 MB, not
    /// a whole document (render.py's rules). Nil otherwise.
    static func fragment(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= most,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard text.range(of: #"<!doctype\s|<\s*(?:html|head|body)(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return text
    }

    /// When the file was last written, to draw it again as Codex rewrites it.
    static func written(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

// MARK: - The document

extension CodexVisualize {
    /// The places a fragment may load from: the plugin's allowlist.
    static let sources = "blob: data: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://esm.sh "
        + "https://fonts.bunny.net https://fonts.googleapis.com https://fonts.gstatic.com https://unpkg.com"
    static let framePolicy = [
        "default-src 'none'",
        "script-src 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' \(sources)",
        "style-src 'unsafe-inline' \(sources)",
        "img-src \(sources)", "font-src \(sources)", "media-src \(sources)",
        "worker-src blob:", "connect-src blob: data:", "frame-src 'none'", "object-src 'none'",
        "base-uri 'none'", "form-action 'none'",
    ].joined(separator: "; ")
    /// A srcdoc frame inherits the shell's policy: the shell lets it be.
    static let shellPolicy = framePolicy.replacingOccurrences(of: "frame-src 'none'", with: "frame-src 'self'")

    /// The fragment as render.py builds it: the kit's stylesheet, bridge
    /// and inner kit round it in a sandboxed srcdoc frame, under the
    /// plugin's policy, Yab's colors laid over the kit's. In the chat
    /// (`full` false) Yab's own shell talks to the bridge, sizes the frame
    /// and says what it hears to `handler`; on the whole window the
    /// plugin's own shell does, as in a browser.
    @MainActor static func document(_ fragment: String, title: String, kit: Kit, state: String? = nil, full: Bool = false) -> String {
        let calendar = fragment.range(of: #"\bviz-calendar\b"#, options: [.regularExpression, .caseInsensitive]) == nil || kit.calendar.isEmpty
            ? "" : "<script>" + kit.calendar.replacingOccurrences(of: "</script", with: "<\\/script") + "</script>"
        let inner = kit.inner.replacingOccurrences(of: placeholder, with: calendar + fragment)
        let bridge = kit.bridge.replacingOccurrences(of: "</script", with: "<\\/script")
        let name = escaped(title)
        // In the chat the state it kept is put in now; the plugin's shell
        // puts its own in from the browser's storage.
        var globals = stateMark
        if !full {
            let saved = state.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull()
            let object: [String: Any] = ["widgetState": saved, "statePersistence": "local"]
            let json = (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            globals = json.replacingOccurrences(of: "<", with: "\\u003c")
        }
        let frame = """
        <!doctype html>
        <html lang="en" data-visualize-standalone>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="\(framePolicy)">
        <title>\(name)</title>
        <style>\(kit.stylesheet)
        html>body{padding:0}\(colors(full: full))</style>
        </head>
        <body>
        <script type="application/json" id="codex-visualization-widget-state">\(globals)</script>
        <script>\(bridge)</script>
        \(inner)
        </body>
        </html>

        """
        let shell = (full ? kit.shell : chatShell).replacingOccurrences(of: "</script", with: "<\\/script")
        let room = full
            ? "body{box-sizing:border-box;padding:1rem;background:inherit}iframe{display:block;width:100%;height:calc(100vh - 2rem);margin:0 auto;border:0}"
            : "html,body{overflow:hidden;background:transparent}iframe{display:block;width:100%;height:\(Int(ChatWidgetPage.least))px;border:0}"
        return """
        <!doctype html>
        <html lang="en" data-visualize-standalone>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="\(shellPolicy)">
        <title>\(name)</title>
        <style>:root{color-scheme:light dark;background:\(full ? "light-dark(\(ground.light),\(ground.dark))" : "transparent")}html,body{margin:0}\(room)</style>
        </head>
        <body>
        <iframe id="codex-visualization" sandbox="allow-scripts" referrerpolicy="no-referrer" title="\(name)" data-srcdoc="\(escaped(frame))"></iframe>
        <script>\(shell)</script>
        </body>
        </html>

        """
    }

    /// HTML's five, as Python's html.escape.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    @MainActor private static var ground: (light: String, dark: String) {
        (ChatWidgetPage.hex(Palette.NS.ground, dark: false), ChatWidgetPage.hex(Palette.NS.ground, dark: true))
    }

    /// Yab's palette under the names the kit takes from its host (its
    /// --color-* aliases), light and dark as the page's look says. In the
    /// chat its own ground is clear: the chat's shows through.
    @MainActor static func colors(full: Bool) -> String {
        let ns = Palette.NS.self
        func pair(_ color: NSColor) -> String {
            "light-dark(\(ChatWidgetPage.hex(color, dark: false)),\(ChatWidgetPage.hex(color, dark: true)))"
        }
        let names: [(String, NSColor)] = [
            ("--color-background-primary", ns.ground), ("--color-background-secondary", ns.ground),
            ("--color-text-primary", ns.ink), ("--color-text-secondary", ns.muted),
            ("--color-border-secondary", ns.hairline), ("--color-border-primary", ns.faint),
        ]
        let set = names.map { "\($0.0):\(pair($0.1));" }.joined()
        return ":root{\(set)}" + (full ? "" : ":root{background-color:transparent!important}")
    }

    /// Yab's shell in the chat: hands the bridge its port, sizes the frame
    /// to what it says, and passes its height, links, follow-ups and kept
    /// state on to the chat (ChatWidgetPage.handler).
    static let chatShell = #"""
    (function(){
      var frame=document.getElementById('codex-visualization');
      if(!(frame instanceof HTMLIFrameElement))return;
      var post=function(m){try{window.webkit.messageHandlers.\#(ChatWidgetPage.handler).postMessage(m)}catch(e){}};
      var channel=new MessageChannel();
      channel.port1.addEventListener('message',function(event){
        var d=event.data;
        if(typeof d!=='object'||d==null)return;
        if(d.type==='height'){
          var h=d.height;
          if(typeof h==='number'&&isFinite(h)&&h>=0&&h<=10000){h=Math.ceil(h);frame.style.height=h+'px';post({height:h})}
        }else if(d.type==='open-external'){
          if(typeof d.href==='string')post({link:d.href});
        }else if(d.type==='follow-up'){
          if(typeof d.prompt==='string')post({prompt:d.prompt});
        }else if(d.type==='widget-state-write'){
          if(!Number.isSafeInteger(d.id)||d.id<=0)return;
          var ok=typeof d.state==='string'&&d.state.length<=16384;
          if(ok)post({state:d.state});
          channel.port1.postMessage({type:'widget-state-result',id:d.id,ok:ok});
        }
      });
      channel.port1.start();
      var srcdoc=frame.dataset.srcdoc;
      if(srcdoc==null)return;
      window.addEventListener('resize',function(){channel.port1.postMessage({type:'measure'})});
      frame.addEventListener('load',function(){
        if(frame.contentWindow)frame.contentWindow.postMessage({type:'codex-visualization-initialize'},'*',[channel.port2]);
      },{once:true});
      frame.srcdoc=srcdoc;
      delete frame.dataset.srcdoc;
    })();
    """#
}
