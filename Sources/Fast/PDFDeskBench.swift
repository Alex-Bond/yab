import AppKit
import PDFKit

// `./bench pdf …`, test runs only: Fill & Sign driven the way a person
// does it, for evals/pdf. With no act, what the tab's PDF and the mode are.
// Acts: start (the plate pressed; memory keeps signatures out of the
// keychain), near (the pointer by the page's foot), mode, focus, type,
// enter, tab, backtab, toggle, write (a line of text), sheet (the
// signature sheet, with a way, a name, a hand or ink), sheetDone, sign (at a
// point or in a box), ghost, pick, move, delete, undo, redo, done, leave
// (esc), discard, origin (a mail it came from), reply, and read (a saved
// PDF opened with PDFKit: its boxes, its notes and its words, page by page).

extension Bench {
    func pdfCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "pdf only works on a --test run"]) }
        let act = request["act"] as? String ?? ""
        if act == "quit" {
            answer(["ok": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }
        if act == "read" {
            guard let path = request["path"] as? String else { return answer(["error": "read: path"]) }
            var result = Self.readPDF(URL(fileURLWithPath: path))
            if let bounds = request["ink"] as? [Double], bounds.count == 4,
               let page = PDFDocument(url: URL(fileURLWithPath: path))?.page(at: request["page"] as? Int ?? 0) {
                result["ink"] = Self.pdfInk(CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]), on: page)
            }
            return answer(result)
        }
        if act == "forget" {
            for kept in PDFPaper.memory.all() { PDFPaper.memory.forget(kept.id) }
            return answer(["forgot": true])
        }
        guard let tab = browser.active else { return answer(["error": "no tab"]) }
        let paper = tab.paper
        let desk = paper.desk
        func number(_ key: String) -> CGFloat? { (request[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        func box(_ name: String?) -> Int? {
            guard let desk, let name else { return nil }
            return desk.boxes.firstIndex { $0.name == name || $0.label == name }
        }
        func reply() { answer(Self.pdfState(tab)) }
        switch act {
        case "":
            return reply()
        case "start":
            if request["memory"] as? Bool == true { Store.settings.set(true, forKey: "pdf.memory") }
            browser.fillSign(tab)
            let limit = Date().addingTimeInterval(15)
            func wait() {
                if paper.desk != nil || Date() > limit {
                    // A frame for the view to come up and settle.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reply() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait() }
                }
            }
            return wait()
        case "near":
            paper.near = request["on"] as? Bool ?? true
            return reply()
        case "origin":
            paper.cameFrom(PDFMailOrigin(account: request["account"] as? String ?? "mira@example.com",
                                         thread: request["thread"] as? String ?? "thread", message: request["message"] as? String ?? "message"))
            return reply()
        case "reply":
            paper.reply(browser)
            return reply()
        default:
            break
        }
        guard let desk else { return answer(["error": "the mode isn't on"]) }
        switch act {
        case "ink":
            guard let stamp = (0..<desk.document.pageCount).flatMap({ desk.document.page(at: $0)?.annotations ?? [] }).compactMap({ $0 as? PDFSignatureStamp }).first,
                  let page = stamp.page else { return answer(["ink": false]) }
            return answer(["ink": Self.pdfInk(stamp.bounds, on: page), "page": desk.document.index(for: page),
                           "bounds": [stamp.bounds.minX, stamp.bounds.minY, stamp.bounds.width, stamp.bounds.height]])
        case "mode":
            desk.set(PDFDeskMode(rawValue: request["mode"] as? String ?? "") ?? .fill)
        case "focus":
            desk.focus(box(request["box"] as? String))
        case "type":
            desk.draft = request["text"] as? String ?? ""
        case "enter":
            desk.enter()
        case "tab":
            desk.step(1)
        case "backtab":
            desk.step(-1)
        case "toggle":
            if let at = box(request["box"] as? String) { desk.toggle(at) }
        case "write":
            desk.write(on: request["page"] as? Int ?? 0, at: CGPoint(x: number("x") ?? 72, y: number("y") ?? 400))
            desk.note = request["text"] as? String ?? ""
            if request["commit"] as? Bool == true { desk.commitNote() }
        case "sheet":
            desk.openSheet(initials: request["initials"] as? Bool ?? false)
            if let way = (request["way"] as? String).flatMap(SignatureWay.init(rawValue:)) { desk.pad.way = way }
            if let name = request["name"] as? String { desk.pad.name = name }
            if let hand = request["hand"] as? String { desk.pad.hand = hand }
            if let points = request["ink"] as? [[Double]] {
                var ink = PenInk()
                var t: TimeInterval = 0
                for (n, point) in points.enumerated() where point.count >= 2 {
                    let p = CGPoint(x: point[0], y: point[1])
                    // A point of [-1, -1] lifts the pen.
                    if point[0] < 0 { ink.strokes.append([]); continue }
                    if n == 0 || ink.strokes.last?.isEmpty != false { ink.begin(p, at: t) } else { ink.add(p, at: t) }
                    t += 0.012
                }
                ink.strokes.removeAll { $0.isEmpty }
                desk.pad.ink = ink
            }
        case "sheetDone":
            desk.finishSheet()
        case "sheetClose":
            desk.sheet = false
        case "sign":
            if let at = box(request["box"] as? String) {
                let b = desk.boxes[at]
                desk.set(.sign)
                desk.sign(on: b.page, at: CGPoint(x: b.bounds.midX, y: b.bounds.midY))
            } else {
                desk.sign(on: request["page"] as? Int ?? 0, at: CGPoint(x: number("x") ?? 300, y: number("y") ?? 200))
            }
        case "ghost":
            if let x = number("x"), let y = number("y") {
                let page = request["page"] as? Int ?? 0, at = CGPoint(x: x, y: y)
                // Where a person's pointer could be: above the bar.
                if let signature = desk.signature { desk.bring?(page, signature.standing(at: at)) }
                desk.ghost = (page, at)
            } else {
                desk.ghost = nil
            }
        case "pick":
            let placed = (0..<desk.document.pageCount).flatMap { desk.document.page(at: $0)?.annotations ?? [] }.filter(PDFDesk.ours)
            desk.pick(request["none"] as? Bool == true ? nil : placed.last)
        case "move":
            if let picked = desk.selected {
                let before = picked.bounds
                var r = before.offsetBy(dx: number("dx") ?? 0, dy: number("dy") ?? 0)
                if let scale = number("scale") { r = CGRect(x: r.minX, y: r.maxY - r.height * scale, width: r.width * scale, height: r.height * scale) }
                desk.drag(picked, to: r)
                desk.moved(picked, from: before)
            }
        case "delete":
            desk.deleteSelected()
        case "undo":
            desk.undo()
        case "redo":
            desk.redo()
        case "done":
            let saved = paper.done(tab, browser: browser)
            var out = Self.pdfState(tab)
            out["saved"] = saved?.path ?? ""
            return answer(out)
        case "leave":
            paper.leave(tab)
        case "discard":
            paper.discard()
        case "flush":
            desk.flushWorking(wait: true)
        case "viewport":
            desk.position?(request["page"] as? Int ?? 0, number("x") ?? 0, number("y") ?? 700, number("scale") ?? 1)
        default:
            return answer(["error": "pdf: start, near, mode, focus, type, enter, tab, backtab, toggle, write, sheet, sheetDone, sign, ghost, pick, move, delete, undo, redo, done, leave, discard, origin, reply, read"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { reply() }
    }

    static func pdfState(_ tab: Tab) -> [String: Any] {
        let paper = tab.paper
        var out: [String: Any] = [
            "pdf": paper.pdf, "fillable": paper.fillable, "near": paper.near, "plate": paper.plateShown,
            "starting": paper.starting, "on": paper.desk != nil, "signed": paper.signed?.path ?? "", "tabID": tab.id.uuidString,
            "mail": paper.mail != nil, "metrics": paper.metrics, "title": tab.title, "label": tab.label, "url": tab.address?.absoluteString ?? "",
        ]
        if let mail = paper.mail { out["mailOrigin"] = ["account": mail.account, "thread": mail.thread, "message": mail.message] }
        if let desk = paper.desk { out["desk"] = desk.report }
        return out
    }

    /// Raster evidence for signature persistence, test worlds only.
    private static func pdfInk(_ rect: CGRect, on page: PDFPage) -> Bool {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width), height = Int(box.height)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !clipped.isNull, !clipped.isEmpty else { return false }
        for y in Int(clipped.minY)..<Int(clipped.maxY) {
            for x in Int(clipped.minX)..<Int(clipped.maxX) {
                let at = ((height - 1 - y) * width + x) * 4
                let r = Int(pixels[at]), g = Int(pixels[at + 1]), b = Int(pixels[at + 2])
                if b > 100, b > r + 40, b > g + 20 { return true }
            }
        }
        return false
    }

    /// A PDF as PDFKit reads it back: what a saved file holds.
    static func readPDF(_ url: URL) -> [String: Any] {
        guard let document = PDFDocument(url: url) else { return ["error": "not a PDF", "exists": FileManager.default.fileExists(atPath: url.path)] }
        var pages: [[String: Any]] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            pages.append([
                "text": page.string ?? "",
                "widgets": page.annotations.filter { $0.type == "Widget" }.map { ["name": $0.fieldName ?? "", "value": $0.widgetStringValue ?? ""] },
                "annotations": page.annotations.map { $0.type ?? "" },
            ])
        }
        return ["pages": pages, "count": document.pageCount, "size": (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0]
    }
}
