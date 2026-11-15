import AppKit
import PDFKit
import WebKit

// A page as a file of its own, for "save this page as a PDF" (or as HTML,
// a web archive, Markdown, text, one picture): the agent's save_page, and
// pdf, which is save_page as a PDF. The file lands in the task's folder
// (AgentFiles.folder), and the chat shows it under the answer
// (ChatFileCard), so the answer is the file, not the steps to make it.
//
// A PDF is printed, as ⌘P's Save as PDF makes it: pages of Letter, the
// site's print styles, no line cut in two. When printing gives nothing
// (a view with no window to print from), the whole page drawn as one PDF
// is cut into pages of the same size instead.

/// Paginated output produced by an engine's native print pipeline. Distinct
/// from PageHandle.pdf's drawn document and from an original PDF resource.
@MainActor
protocol PagePrintedPDF: AnyObject {
    func savePrintedPDF(to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void)
}

extension ChromiumPage: PagePrintedPDF { }

@MainActor
enum PageSave {
    /// The formats save_page takes, as their files end.
    static let formats = ["pdf", "html", "webarchive", "md", "txt", "png", "csv", "xlsx"]

    /// A format as an agent or a person may say it, or nil for none Yab makes.
    nonisolated static func format(_ said: String?) -> String? {
        let words = (said ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")).replacingOccurrences(of: " ", with: "")
        switch words {
        case "", "pdf": return "pdf"
        case "html", "htm": return "html"
        case "webarchive", "archive", "safari": return "webarchive"
        case "md", "markdown": return "md"
        case "txt", "text", "plaintext": return "txt"
        case "png", "image", "picture", "screenshot": return "png"
        case "csv": return "csv"
        case "xlsx", "excel", "spreadsheet", "xls", "sheet", "sheets": return "xlsx"
        default: return nil
        }
    }

    /// A file named for the page, in `folder`, that isn't there yet.
    nonisolated static func file(title: String, host: String, format: String, in folder: URL) -> URL {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var base = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if base.isEmpty { base = host.isEmpty ? "Page" : host }
        var url = folder.appendingPathComponent("\(base).\(format)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(format)")
            n += 1
        }
        return url
    }

    /// Saves the tab's page as `format` into `folder`; the file, or why not.
    static func save(_ tab: Tab, as format: String, in folder: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let file = Self.file(title: tab.title, host: tab.address?.host() ?? "", format: format, in: folder)
        let write: (Data) -> Void = { data in
            do { try data.write(to: file); done(.success(file)) } catch { done(.failure(error)) }
        }
        switch format {
        case "pdf":
            pdfPage(tab.page, to: file, done: done)
        case "webarchive":
            guard let web = tab.webKitOnly("Web archive export") else { done(.failure(Failure("Web archives are not available on this engine yet"))); return }
            web.createWebArchiveData { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let data): write(data)
                    case .failure(let error): done(.failure(error))
                    }
                }
            }
        case "png":
            tab.page.pdf(rect: nil) { result in
                MainActor.assumeIsolated {
                    guard case .success(let data) = result else {
                        if case .failure(let error) = result { done(.failure(error)) }
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let png = picture(data)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let png else { return done(.failure(Failure("Couldn’t draw the page as a picture"))) }
                                write(png)
                            }
                        }
                    }
                }
            }
        default:
            let body = format == "html" ? html : format == "md" ? markdown : text
            AgentPage.run(tab, body) { result in
                switch result {
                case .success(let value):
                    guard let words = value as? String, !words.isEmpty else { return done(.failure(Failure("The page gave nothing to save"))) }
                    write(Data(words.utf8))
                case .failure(let error):
                    done(.failure(error))
                }
            }
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ words: String) { errorDescription = words }
    }

    // MARK: - PDF

    /// Letter, as the print sheet starts.
    nonisolated static let sheet = CGSize(width: 612, height: 792)

    static func pdfPage(_ page: any PageHandle, to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        if let printed = page as? any PagePrintedPDF { return printed.savePrintedPDF(to: file, done: done) }
        if let web = page.webKit { return pdf(web, to: file, done: done) }
        page.pdf(rect: nil) { result in
            do { try result.get().write(to: file); done(.success(file)) }
            catch { done(.failure(error)) }
        }
    }

    static func pdf(_ web: WKWebView, to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = sheet
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        for side in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: side] = 36 }
        let job = web.printOperation(with: info)
        job.showsPrintPanel = false
        job.showsProgressPanel = false
        job.view?.frame = web.bounds
        let printed: @MainActor (Bool) -> Void = { ok in
            if ok, readable(file) { return done(.success(file)) }
            try? FileManager.default.removeItem(at: file)
            cut(web, to: file, done: done)
        }
        // WebKit prints a page only modally, over its window; with none
        // (a view kept out of every window), the whole page cut into pages.
        guard let window = web.window, web.bounds.width > 0 else { return cut(web, to: file, done: done) }
        let waiter = PrintWaiter(printed)
        job.runModal(for: window, delegate: waiter, didRun: #selector(PrintWaiter.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    /// A PDF with pages and words in it: printing a page WebKit hadn't
    /// drawn gives blank pages.
    nonisolated static func readable(_ file: URL) -> Bool {
        guard let document = PDFDocument(url: file), document.pageCount > 0 else { return false }
        return !(document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The whole page drawn as one PDF, cut into pages.
    private static func cut(_ web: WKWebView, to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        web.createPDF { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let data):
                    guard let paged = pages(data) else { return done(.failure(Failure("Couldn’t make pages of the page"))) }
                    do { try paged.write(to: file); done(.success(file)) } catch { done(.failure(error)) }
                case .failure(let error):
                    done(.failure(error))
                }
            }
        }
    }

    /// One tall PDF page as pages of `sheet` cut where `breaks` say (in
    /// the page's own units, from its top, `height` of them in all), a
    /// margin round each, so no line or picture is cut in two.
    nonisolated static func pages(_ tall: Data, breaks: [CGFloat], height: CGFloat, margin: CGFloat) -> Data? {
        guard let provider = CGDataProvider(data: tall as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0, height > 0 else { return nil }
        let k = box.height / height
        let scale = (sheet.width - 2 * margin) / box.width
        let out = NSMutableData()
        var media = CGRect(origin: .zero, size: sheet)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        var from: CGFloat = 0
        for to in breaks + [height] where to > from {
            let top = box.maxY - from * k, bottom = box.maxY - to * k
            context.beginPDFPage(nil)
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: margin / scale - box.minX, y: (sheet.height - margin) / scale - top)
            context.clip(to: CGRect(x: box.minX, y: bottom, width: box.width, height: top - bottom))
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
            from = to
        }
        context.closePDF()
        return out as Data
    }

    /// Where to cut a page `height` tall into pieces at most `room` tall:
    /// at the last place before each limit that no span (a line of text, a
    /// picture) crosses, or at the limit when one span is taller than half
    /// a page.
    nonisolated static func breaks(spans: [(CGFloat, CGFloat)], height: CGFloat, room: CGFloat) -> [CGFloat] {
        guard room > 0 else { return [] }
        let sorted = spans.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var out: [CGFloat] = []
        var start: CGFloat = 0
        while start + room < height {
            let limit = start + room
            var cut = limit
            var moved = true
            while moved {
                moved = false
                for span in sorted where span.0 < cut && span.1 > cut && span.0 > start {
                    cut = span.0
                    moved = true
                }
            }
            if cut - start < room / 2 { cut = limit }
            out.append(cut)
            start = cut
        }
        return out
    }

    /// One tall PDF page as pages of `sheet`, its width across each, its
    /// words still words.
    nonisolated static func pages(_ tall: Data) -> Data? {
        guard let provider = CGDataProvider(data: tall as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = sheet.width / box.width
        let slice = sheet.height / scale
        let count = max(1, Int((box.height / slice).rounded(.up)))
        let out = NSMutableData()
        var media = CGRect(origin: .zero, size: sheet)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        for i in 0..<count {
            context.beginPDFPage(nil)
            context.saveGState()
            let bottom = box.maxY - CGFloat(i + 1) * slice
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -bottom)
            context.clip(to: CGRect(x: box.minX, y: max(bottom, box.minY), width: box.width, height: slice))
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return out as Data
    }

    /// The whole page as one PNG: twice its width, kept under 32,000
    /// pixels tall.
    nonisolated static func picture(_ pdf: Data) -> Data? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let width = max(1, Int(min(box.width * 2, 32_000 * box.width / box.height)))
        guard let image = CaptureArt.raster(pdf: pdf, width: width) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: - words

    /// The page as it is now, its addresses still reaching the site.
    static let html = """
    const copy = document.documentElement.cloneNode(true);
    const head = copy.querySelector('head');
    if (head && !head.querySelector('base')) {
      const base = document.createElement('base');
      base.href = location.href;
      head.prepend(base);
    }
    const kind = document.doctype ? '<!DOCTYPE ' + document.doctype.name + '>\\n' : '<!DOCTYPE html>\\n';
    return kind + copy.outerHTML;
    """

    static let text = """
    return document.title + '\\n' + location.href + '\\n\\n' + (document.body ? document.body.innerText : '');
    """

    /// The page's reading part (its article, its main, else the body) as
    /// Markdown: headings, paragraphs, links, lists, quotes, code, tables,
    /// pictures. Nothing a person can't see, no menus or forms.
    static let markdown = """
    const root = document.querySelector('article') || document.querySelector('main') || document.body;
    if (!root) return '';
    const BLOCK = new Set(['P','DIV','SECTION','ARTICLE','MAIN','HEADER','H1','H2','H3','H4','H5','H6','UL','OL','LI','PRE',
      'BLOCKQUOTE','TABLE','FIGURE','FIGCAPTION','HR','DL','DT','DD','ASIDE','DETAILS','SUMMARY']);
    const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','CANVAS','IFRAME','NAV','FOOTER','FORM','BUTTON',
      'INPUT','SELECT','TEXTAREA','DIALOG']);
    const abs = (u) => { try { return new URL(u, location.href).href; } catch (e) { return u; } };
    const gone = (n) => SKIP.has(n.tagName) || n.hidden || n.getAttribute('aria-hidden') === 'true'
      || (n.checkVisibility && !n.checkVisibility());
    const inline = (n) => {
      if (n.nodeType === 3) return n.textContent.replace(/\\s+/g, ' ');
      if (n.nodeType !== 1 || gone(n)) return '';
      const t = n.tagName;
      if (t === 'BR') return '  \\n';
      if (t === 'IMG') return n.getAttribute('src') ? '![' + (n.alt || '') + '](' + abs(n.getAttribute('src')) + ')' : '';
      if (t === 'CODE') return '`' + n.textContent + '`';
      const inner = Array.from(n.childNodes).map(inline).join('');
      const said = inner.trim();
      if (!said) return inner;
      if (t === 'A' && n.getAttribute('href') && !n.getAttribute('href').startsWith('javascript:')) return '[' + said + '](' + abs(n.getAttribute('href')) + ')';
      if (t === 'STRONG' || t === 'B') return '**' + said + '**';
      if (t === 'EM' || t === 'I') return '*' + said + '*';
      return inner;
    };
    const blocks = (el, out, depth) => {
      let run = [];
      const flush = () => {
        const said = run.map(inline).join('').replace(/[ \\t]+/g, ' ').replace(/ *\\n */g, '\\n').trim();
        if (said) out.push(said);
        run = [];
      };
      for (const n of el.childNodes) {
        if (n.nodeType === 1 && gone(n)) continue;
        if (n.nodeType === 1 && BLOCK.has(n.tagName)) { flush(); one(n, out, depth); } else run.push(n);
      }
      flush();
    };
    const one = (n, out, depth) => {
      const t = n.tagName;
      if (/^H[1-6]$/.test(t)) {
        const said = inline(n).replace(/\\s+/g, ' ').trim();
        if (said) out.push('#'.repeat(+t[1]) + ' ' + said);
      } else if (t === 'PRE') {
        out.push('```\\n' + n.innerText.replace(/\\n+$/, '') + '\\n```');
      } else if (t === 'HR') {
        out.push('---');
      } else if (t === 'UL' || t === 'OL') {
        let i = 1;
        const items = [];
        for (const li of n.children) {
          if (li.tagName !== 'LI' || gone(li)) continue;
          const inner = [];
          blocks(li, inner, depth + 1);
          items.push('  '.repeat(depth) + (t === 'OL' ? (i++) + '. ' : '- ') + inner.join('\\n'));
        }
        if (items.length) out.push(items.join('\\n'));
      } else if (t === 'BLOCKQUOTE') {
        const inner = [];
        blocks(n, inner, depth);
        if (inner.length) out.push(inner.join('\\n\\n').split('\\n').map((l) => '> ' + l).join('\\n'));
      } else if (t === 'TABLE') {
        const rows = Array.from(n.querySelectorAll('tr')).map((tr) =>
          '| ' + Array.from(tr.children).map((c) => inline(c).replace(/\\s+/g, ' ').replace(/\\|/g, '\\\\|').trim()).join(' | ') + ' |');
        if (rows.length) {
          const cells = n.querySelector('tr').children.length;
          rows.splice(1, 0, '|' + ' --- |'.repeat(cells));
          out.push(rows.join('\\n'));
        }
      } else {
        blocks(n, out, depth);
      }
    };
    const out = [];
    blocks(root, out, 0);
    const title = document.title.trim();
    const head = out.length && out[0].replace(/^#+ /, '') === title ? [] : (title ? ['# ' + title] : []);
    return head.concat(['<' + location.href + '>'], out).join('\\n\\n') + '\\n';
    """
}

/// What a print run over a window says when it is over.
private final class PrintWaiter: NSObject {
    private var then: (@MainActor (Bool) -> Void)?
    private var keep: PrintWaiter?

    init(_ then: @escaping @MainActor (Bool) -> Void) {
        self.then = then
        super.init()
        keep = self
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let then = self.then
        self.then = nil
        keep = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { then?(success) } }
    }
}
