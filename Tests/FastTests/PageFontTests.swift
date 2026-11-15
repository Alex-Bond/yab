import AppKit
import JavaScriptCore
import Testing
import WebKit
@testable import Fast

struct PageFontTests {
    // These fixture names contain no commas or escapes. Ignore optional CSS
    // quotes while preserving every family name and its position in the list.
    static func fixtureFamilies(_ value: String?) -> [String]? {
        value.map { value in
            value.split(separator: ",", omittingEmptySubsequences: false).map { part in
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                    return String(name.dropFirst().dropLast())
                }
                return name
            }
        }
    }

    @Test func customFamiliesKeepTheirTextFaceAndSystemEmojiBeforeTheGeneric() {
        for fallback in ["serif", "sans-serif", "monospace"] {
            #expect(PageFonts.family("Example Text", fallback: fallback)
                    == "\"Example Text\", \"Yab Emoji\", \(fallback)")
            #expect(PageFonts.family("", fallback: fallback).isEmpty)
        }
        #expect(PageFonts.family("A\"B\\C\nD\rE", fallback: "serif")
                == "\"A\\\"B\\\\C D E\", \"Yab Emoji\", serif")
    }

    @Test func allCustomDefaultsUseTheSameFamilyBuilder() {
        #expect(PageFonts().css.isEmpty)
        var fonts = PageFonts()
        fonts.standard = "Georgia"
        fonts.serif = "Palatino"
        fonts.sans = "Helvetica"
        fonts.fixed = "Menlo"
        #expect(fonts.css == """
        \(PageFonts.emojiFace)
        :where(html, body) { font-family: "Georgia", "Yab Emoji", serif; }
        :where(input, button, select, textarea) { font-family: "Helvetica", "Yab Emoji", sans-serif; }
        :where(pre, code, kbd, samp) { font-family: "Menlo", "Yab Emoji", monospace; }
        """)
        fonts.standard = ""
        #expect(fonts.css.contains("\n:where(html, body) { font-family: \"Palatino\", \"Yab Emoji\", serif; }\n"))
        fonts.size = 100
        #expect(fonts.css.hasPrefix(PageFonts.emojiFace + "\n:where(html) { font-size: 72px; }"))
        fonts.size = 1
        #expect(fonts.css.contains("\n:where(html) { font-size: 9px; }\n"))
        // Size alone names no family, so it needs no emoji face.
        var sized = PageFonts()
        sized.size = 20
        #expect(sized.css == ":where(html) { font-size: 20px; }")
        for keep in [\PageFonts.standard, \.serif, \.sans, \.fixed] {
            var one = PageFonts()
            one[keyPath: keep] = "Georgia"
            #expect(one.css.hasPrefix(PageFonts.emojiFace + "\n"))
        }
    }

    // Apple Color Emoji has ©, ®, ™, arrows, ‼, ⁉, ℹ, the digits, # and *
    // for keycaps; drawn from it they turn into color pictures. The face Yab
    // names covers emoji and their sequence pieces, never these.
    @Test func theEmojiFaceLeavesTextSymbolsToTheTextFonts() throws {
        let face = PageFonts.emojiFace
        #expect(face.hasPrefix("@font-face { font-family: \"Yab Emoji\"; src: local(\"Apple Color Emoji\")"))
        #expect(!face.contains("url("))
        let ranges = try PageFonts.emojiRange.components(separatedBy: ", ").map { part -> ClosedRange<UInt32> in
            #expect(part.hasPrefix("U+"))
            let bounds = part.dropFirst(2).split(separator: "-").map { UInt32($0, radix: 16) }
            let low = try #require(bounds.first ?? nil)
            let high = try #require(bounds.last ?? nil)
            #expect(low <= high)
            return low...high
        }
        func covered(_ scalar: UInt32) -> Bool { ranges.contains { $0.contains(scalar) } }
        let text: [UInt32] = [0x20, 0x23, 0x2A] + Array(0x30...0x39) + Array(0x41...0x7A)
            + [0xA9, 0xAE, 0x203C, 0x2049, 0x2122, 0x2139] + Array(0x2190...0x21FF)
            + [0x24C2, 0x25AA, 0x25AB, 0x25B6, 0x25C0, 0x2600, 0x2611, 0x263A, 0x2660, 0x2665,
               0x2714, 0x2716, 0x2733, 0x2764, 0x27A1, 0x2934, 0x2935, 0x2B05, 0x3030, 0x303D,
               0xFE0E, 0x1F170, 0x1F171, 0x1F17E, 0x1F17F, 0x1F202, 0x1F237]
        for scalar in text { #expect(!covered(scalar), "U+\(String(scalar, radix: 16, uppercase: true))") }
        let emoji: [UInt32] = [0x200D, 0x20E3, 0xFE0F, 0x231A, 0x23F0, 0x2614, 0x26A1, 0x2705,
                               0x2728, 0x274C, 0x2B50, 0x1F004, 0x1F1FA, 0x1F308, 0x1F389, 0x1F3FD,
                               0x1F44D, 0x1F600, 0x1F642, 0x1F680, 0x1F7E2, 0x1F929, 0x1FAE0, 0xE007F]
        for scalar in emoji { #expect(covered(scalar), "U+\(String(scalar, radix: 16, uppercase: true))") }
    }

    // Force the document-start case where WebKit has not made <html> yet.
    private func context(root: Bool) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        globalThis.location = {protocol:'https:'};
        globalThis.listeners = {};
        globalThis.observers = [];
        class HTMLElement {
          constructor(family = 'serif') {
            this.family = family;
            this.isConnected = true;
            this.values = new Map();
            this.style = {
              getPropertyValue: name => this.values.get(name) || '',
              getPropertyPriority: () => '',
              setProperty: (name, value) => this.values.set(name, value),
              removeProperty: name => this.values.delete(name)
            };
          }
          querySelectorAll() { return []; }
          prepend(style) { document.sheet = style; }
        }
        globalThis.HTMLElement = HTMLElement;
        globalThis.getComputedStyle = node => ({fontFamily:node.values.get('font-family') || node.family});
        globalThis.MutationObserver = class {
          constructor(callback) { this.callback = callback; this.active = false; observers.push(this); }
          observe(target) { this.active = true; this.target = target; }
          disconnect() { this.active = false; }
        };
        globalThis.document = {
          documentElement: \(root ? "new HTMLElement()" : "null"), readyState:'loading', sheet:null,
          getElementById: () => document.sheet,
          createElement: () => ({textContent:'', remove() { document.sheet = null; }}),
          addEventListener: (name, callback) => { listeners[name] = callback; }
        };
        """)
        try #require(context.exception == nil)
        return context
    }

    @Test func defaultsInstallWhenTheRootArrivesWithoutWaitingForDOMContentLoaded() throws {
        let context = try context(root: false)
        var fonts = PageFonts()
        fonts.standard = "Georgia"
        context.evaluateScript(PageAppearance.script(fonts))
        try #require(context.exception == nil)
        #expect(context.evaluateScript("document.sheet === null && observers[0].active")?.toBool() == true)
        context.evaluateScript("document.documentElement = new HTMLElement(); observers[0].callback([]);")
        try #require(context.exception == nil)
        #expect(context.evaluateScript("document.sheet.textContent")?.toString() == fonts.css)
        #expect(context.evaluateScript("document.readyState === 'loading' && !observers[0].active")?.toBool() == true)
        #expect(context.evaluateScript("__yabPageDefaults.rootObserver === null")?.toBool() == true)
    }

    @Test func resettingBeforeTheRootArrivesCancelsTheOldDefaults() throws {
        let context = try context(root: false)
        var fonts = PageFonts()
        fonts.standard = "Georgia"
        context.evaluateScript(PageAppearance.script(fonts))
        context.evaluateScript(PageAppearance.script(PageFonts()))
        context.evaluateScript("document.documentElement = new HTMLElement(); observers[0].callback([]);")
        try #require(context.exception == nil)
        #expect(context.evaluateScript("document.sheet === null && !observers[0].active")?.toBool() == true)
    }

    @Test func genericRemappingUsesTheEscapedStackAndRestoresTheOriginal() throws {
        let context = try context(root: true)
        var fonts = PageFonts()
        fonts.serif = "Example \"Text\""
        context.evaluateScript(PageAppearance.script(fonts))
        try #require(context.exception == nil)
        #expect(context.evaluateScript("document.documentElement.style.getPropertyValue('font-family')")?.toString()
                == PageFonts.family(fonts.serif, fallback: "serif"))
        context.evaluateScript(PageAppearance.script(PageFonts()))
        try #require(context.exception == nil)
        #expect(context.evaluateScript("document.documentElement.style.getPropertyValue('font-family')")?.toString() == "")
    }

    @MainActor @Test func documentStartDefaultsPreserveAuthorTypeAndSize() async throws {
        var fonts = PageFonts()
        fonts.standard = "Georgia"
        fonts.serif = "Palatino"
        fonts.fixed = "Menlo"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let script = PageScripts.fonts(fonts)
        #expect(script.injectionTime == .atDocumentStart)
        #expect(!script.isForMainFrameOnly)
        configuration.userContentController.addUserScript(script)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        web.loadHTMLString("""
        <!doctype html><head><script>
        window.earlyFont = getComputedStyle(document.documentElement).fontFamily;
        window.earlyState = document.readyState;
        </script><style>#authored { font: 11px Helvetica; }</style></head><body>
        <p id=plain>Ordinary text \u{1F600} \u{1F44D}\u{1F3FD} \u{1F469}\u{200D}\u{1F4BB}</p>
        <p id=authored>Site text</p><pre id=code>Code \u{1F600}</pre>
        <p id=generic style="font-family:serif">Generic text \u{1F600}</p>
        </body>
        """, baseURL: URL(string: "https://fonts.example.test/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('#generic')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await web.evaluateJavaScript("window.earlyState") as? String == "loading")
        let early = try #require(try await web.evaluateJavaScript("window.earlyFont") as? String)
        #expect(Self.fixtureFamilies(early) == ["Georgia", PageFonts.emojiFamily, "serif"])
        let styled = try #require(try await web.evaluateJavaScript("""
        ['plain','authored','code','generic'].map(id => {
          const s = getComputedStyle(document.getElementById(id));
          return {size:s.fontSize, font:s.fontFamily};
        })
        """) as? [[String: String]])
        #expect(styled[0]["font"] == early)
        #expect(styled[0]["size"] == "16px")
        #expect(styled[1]["font"] == "Helvetica")
        #expect(styled[1]["size"] == "11px")
        #expect(Self.fixtureFamilies(styled[2]["font"]) == ["Menlo", PageFonts.emojiFamily, "monospace"])
        #expect(Self.fixtureFamilies(styled[3]["font"]) == ["Palatino", PageFonts.emojiFamily, "serif"])
        try await web.evaluateJavaScript(PageAppearance.script(PageFonts()), in: nil, contentWorld: Web.world)
        #expect(try await web.evaluateJavaScript("document.getElementById('generic').style.fontFamily") as? String == "serif")
    }

    static let textSymbols = ["\u{A9}", "\u{AE}", "\u{2122}", "\u{2192}", "\u{2190}", "\u{2194}", "\u{203C}",
                              "\u{2049}", "\u{2139}", "\u{25B6}", "\u{263A}", "\u{2714}", "\u{2660}", "7", "#"]
    static let emoji = ["\u{1F642}", "\u{1F389}", "\u{1F44D}\u{1F3FD}", "\u{1F469}\u{200D}\u{1F4BB}",
                        "\u{1F1FA}\u{1F1F8}", "\u{26A1}", "\u{2705}", "\u{2764}\u{FE0F}"]
    // Kept in the picture and the record: the presentation selector asks for
    // emoji; whether WebKit honors it is its own fallback.
    static let selected = ["\u{A9}\u{FE0F}", "\u{2194}\u{FE0F}", "\u{263A}\u{FE0F}", "1\u{FE0F}\u{20E3}"]

    /// Georgia lacks ↔, ‼, ▶, ☺ and more. Drawn by stock WebKit, the
    /// 0.42.0 list (Apple Color Emoji named second), and Yab's own defaults:
    /// text symbols stay text as in stock WebKit, emoji are color pictures. With
    /// YAB_FARM_OUT set, the picture and each glyph's colored pixels.
    @MainActor @Test(.timeLimit(.minutes(1))) func customFontsKeepTextSymbolsAsTextAndEmojiInColor() async throws {
        var fonts = PageFonts()
        fonts.standard = "Georgia"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(PageScripts.fonts(fonts))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1560, height: 280), configuration: configuration)
        web.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -1200, y: -1200))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let glyphs = Self.textSymbols + Self.emoji + Self.selected
        let cells = glyphs.map { "<span class=c>\($0)</span>" }.joined()
        let rows = [("stock", "Safari, Georgia", "font-family: \"Georgia\", serif"),
                    ("shipped", "0.42.0", "font-family: \"Georgia\", \"Apple Color Emoji\", serif"),
                    ("yab", "This fix", "")]
        web.loadHTMLString("""
        <!doctype html><meta name=color-scheme content=light><style>
        html { background:#fff; color:#000; } body { margin:12px; }
        .row { white-space:nowrap; font-size:30px; line-height:64px; }
        .row b { display:inline-block; width:120px; font:600 13px -apple-system; }
        .c { display:inline-block; min-width:44px; padding:0 4px; text-align:center; }
        </style><body>
        <div style="font:13px -apple-system">Settings › Websites › Fonts: Georgia (register 1430)</div>
        \(rows.map { "<div class=row id=\($0.0) style='\($0.2)'><b>\($0.1)</b>\(cells)</div>" }.joined(separator: "\n"))
        </body>
        """, baseURL: URL(string: "https://fonts.example.test/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('#yab')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let face = try await web.callAsyncJavaScript("""
        await document.fonts.ready;
        return [...document.fonts].filter(f => f.family.replace(/"/g, '') === family).map(f => f.status).join();
        """, arguments: ["family": PageFonts.emojiFamily], in: nil, contentWorld: .page) as? String
        #expect(face == "loaded")
        let rects = try #require(try await web.evaluateJavaScript("""
        ['stock','shipped','yab'].map(id => [...document.querySelectorAll('#' + id + ' .c')].map(c => {
          const r = c.getBoundingClientRect(); return [r.x, r.y, r.width, r.height];
        }))
        """) as? [[[Double]]])
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            web.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
        let picture = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = picture.width, height = picture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        let scale = Double(width) / web.bounds.width
        // Pixels whose channels differ widely: a color picture, not gray text.
        func colored(_ rect: [Double]) -> Int {
            let x0 = max(0, Int(rect[0] * scale)), y0 = max(0, Int(rect[1] * scale))
            let x1 = min(width, Int((rect[0] + rect[2]) * scale)), y1 = min(height, Int((rect[1] + rect[3]) * scale))
            var count = 0
            for y in y0..<max(y0, y1) {
                for x in x0..<max(x0, x1) {
                    let i = (y * width + x) * 4
                    let channels = [pixels[i], pixels[i + 1], pixels[i + 2]]
                    if Int(channels.max()!) - Int(channels.min()!) > 48 { count += 1 }
                }
            }
            return count
        }
        try #require(rects.count == 3 && rects.allSatisfy { $0.count == glyphs.count })
        let counts = rects.map { $0.map(colored) }
        let isColor = counts.map { $0.map { $0 > 12 } }
        let (stock, yab) = (isColor[0], isColor[2])
        for (index, glyph) in glyphs.enumerated() {
            let name = glyph.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
            if index < Self.textSymbols.count {
                #expect(yab[index] == stock[index], "\(name) as stock WebKit draws it")
                if index < 5 { #expect(!yab[index], "\(name) stays text") }
            } else if index < Self.textSymbols.count + Self.emoji.count {
                #expect(yab[index], "\(name) is a color emoji")
            }
        }

        guard let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] else { return }
        let folder = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = try #require(NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("1430-emoji-symbols.png"))
        for (row, name) in [(1, "1430-before-0.42.0.png"), (2, "1430-after.png")] {
            let top = Int((rects[row][0][1] - 6) * scale)
            let strip = try #require(picture.cropping(to: CGRect(x: 0, y: top, width: width, height: Int(76 * scale))))
            let data = try #require(NSBitmapImageRep(cgImage: strip).representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent(name))
        }
        let record = glyphs.enumerated().map { index, glyph -> [String: Any] in
            ["glyph": glyph,
             "scalars": glyph.unicodeScalars.map { String($0.value, radix: 16, uppercase: true) }.joined(separator: " "),
             "stock": counts[0][index], "shipped": counts[1][index], "yab": counts[2][index]]
        }
        let json = try JSONSerialization.data(withJSONObject: ["face": face ?? "", "glyphs": record],
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: folder.appendingPathComponent("1430-emoji-symbols.json"))
    }
}
