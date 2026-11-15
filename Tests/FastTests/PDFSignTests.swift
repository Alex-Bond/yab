import AppKit
import Foundation
import PDFKit
import Testing
@testable import Fast

// Fill and sign a PDF in its tab (docs/pdf-sign.md): a contract's form read
// box by box, what Yab offers for each, every step undone by ⌘Z, the
// signature put in its box, and the file Done makes, read back with PDFKit.
@MainActor
struct PDFSignTests {
    static let sam: Profile = {
        var p = Profile()
        p.name = "Sam Rivera"
        p.role = "Founder"
        p.company = "Yab Labs"
        return p
    }()

    static let address: StreetAddress = {
        var a = StreetAddress(id: "home")
        a.name = "Sam Rivera"
        a.email = "sam@example.com"
        a.phone = "+1 415 555 0100"
        return a
    }()

    /// October 20, 2026, noon in San Francisco.
    static let day = Date(timeIntervalSince1970: 1_792_522_800)

    // MARK: fixtures

    /// The last page of a contract, as the frames draw it: a title, words,
    /// and a label over each line to sign on. With `form`, a box on each
    /// line, a signature box, a tick and a box the profile must not fill.
    static func contract(form: Bool = true) -> PDFDocument {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &media, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        func text(_ words: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 10, bold: Bool = false) {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont(name: "Helvetica", size: size)!
            NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: NSColor.black]).draw(at: CGPoint(x: x, y: y))
        }
        text("Master Services Agreement", 72, 720, size: 18, bold: true)
        text("Acme Inc. and Yab Labs", 72, 700)
        text("IN WITNESS WHEREOF, the parties have signed this Agreement as of the date written below.", 72, 470)
        text("Name", 72, 432)
        text("Title", 72, 380)
        text("Date", 72, 328)
        text("Signature", 72, 276)
        text("Company size", 400, 432)
        text("I agree", 420, 360)
        for (y, w) in [(426.0, 300.0), (374.0, 300.0), (322.0, 300.0), (270.0, 300.0)] {
            context.setFillColor(NSColor.gray.cgColor)
            context.fill(CGRect(x: 72, y: y - 22, width: w, height: 0.8))
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        let document = PDFDocument(data: data as Data)!
        guard form, let page = document.page(at: 0) else { return document }
        func widget(_ name: String, _ rect: CGRect, _ type: PDFAnnotationWidgetSubtype, check: Bool = false) {
            let w = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
            w.widgetFieldType = type
            if check { w.widgetControlType = .checkBoxControl }
            w.fieldName = name
            w.font = NSFont(name: "Helvetica", size: 12)
            page.addAnnotation(w)
        }
        widget("Name", CGRect(x: 72, y: 404, width: 300, height: 22), .text)
        widget("Title", CGRect(x: 72, y: 352, width: 300, height: 22), .text)
        widget("Date", CGRect(x: 72, y: 300, width: 300, height: 22), .text)
        widget("Signature", CGRect(x: 72, y: 224, width: 300, height: 46), .signature)
        widget("size", CGRect(x: 400, y: 404, width: 140, height: 22), .text)
        widget("Agree", CGRect(x: 400, y: 358, width: 14, height: 14), .button, check: true)
        // Written and read again, as a PDF that came over the wire is.
        return PDFDocument(data: document.dataRepresentation()!)!
    }

    static func desk(_ document: PDFDocument? = nil, shelf: SignatureShelf? = nil) -> PDFDesk {
        PDFDesk(document: document ?? contract(), source: URL(string: "https://acme.example/Acme-MSA.pdf"), profile: sam,
                address: address, today: day, shelf: shelf ?? SignatureMemory())
    }

    static func index(_ desk: PDFDesk, _ name: String) -> Int {
        desk.boxes.firstIndex { $0.name == name }!
    }

    static func signature() -> Data {
        var ink = PenInk()
        ink.begin(CGPoint(x: 10, y: 20), at: 0)
        for i in 1...40 { ink.add(CGPoint(x: 10 + Double(i) * 6, y: 20 + sin(Double(i) / 3) * 14), at: Double(i) * 0.012) }
        return Signature.picture(of: ink)!
    }

    // MARK: the form

    @Test func readsTheBoxesInReadingOrderWithTheirLabels() {
        let boxes = PDFFill.boxes(Self.contract())
        #expect(boxes.map(\.name) == ["Name", "size", "Title", "Agree", "Date", "Signature"])
        #expect(boxes.map(\.kind) == [.text, .text, .text, .check, .text, .signature])
        let labels = Dictionary(uniqueKeysWithValues: boxes.map { ($0.name, $0.label) })
        #expect(labels["Name"] == "Name")
        #expect(labels["Title"] == "Title")
        #expect(labels["Date"] == "Date")
        #expect(labels["size"] == "Company size")
        #expect(PDFFill.fillable(Self.contract()))
        #expect(!PDFFill.fillable(Self.contract(form: false)))
    }

    @Test func offersWhatFormRulesAllow() {
        let boxes = PDFFill.boxes(Self.contract())
        func hint(_ name: String) -> String? {
            PDFFill.hint(for: boxes.first { $0.name == name }!, profile: Self.sam, address: Self.address, today: Self.day)
        }
        #expect(hint("Name") == "Sam Rivera")
        #expect(hint("Title") == "Founder")
        #expect(hint("Date") == "October 20, 2026")
        // "Company size" is never your company.
        #expect(hint("size") == nil)
        #expect(hint("Signature") == nil)
        #expect(hint("Agree") == nil)
    }

    @Test func offersMailPhoneAndNameParts() {
        func box(_ label: String) -> PDFBox {
            let w = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 100, height: 20), forType: .widget, withProperties: nil)
            w.widgetFieldType = .text
            w.fieldName = "f"
            return PDFBox(annotation: w, page: 0, kind: .text, name: "f", label: label)
        }
        func hint(_ label: String) -> String? { PDFFill.hint(for: box(label), profile: Self.sam, address: Self.address, today: Self.day) }
        #expect(hint("Email") == "sam@example.com")
        #expect(hint("Phone number") == "+1 415 555 0100")
        #expect(hint("First name") == "Sam")
        #expect(hint("Last name") == "Rivera")
        #expect(hint("Company") == "Yab Labs")
        #expect(hint("Company name") == "Yab Labs")
        #expect(hint("Date of birth") == nil)
        #expect(hint("Passport number") == nil)
        #expect(hint("Initials") == nil)
    }

    // MARK: Fill, step by step

    @Test func startsInTheFirstEmptyBoxAndReturnTakesTheHint() {
        let desk = Self.desk()
        #expect(desk.mode == .fill)
        #expect(desk.current == Self.index(desk, "Name"))
        #expect(desk.ghostWords == "Sam Rivera")
        desk.enter()
        #expect(desk.boxes[Self.index(desk, "Name")].value == "Sam Rivera")
        // Tab goes on to the next box words go in: past the tick.
        #expect(desk.current == Self.index(desk, "size"))
        #expect(desk.ghostWords == nil)
        desk.step(1)
        #expect(desk.current == Self.index(desk, "Title"))
        desk.enter()
        #expect(desk.current == Self.index(desk, "Date"))
        #expect(desk.ghostWords == "October 20, 2026")
        desk.enter()
        #expect(desk.boxes[Self.index(desk, "Date")].value == "October 20, 2026")
        #expect(desk.steps.count == 3)
        // ⇧Tab back.
        desk.focus(Self.index(desk, "Date"))
        desk.step(-1)
        #expect(desk.current == Self.index(desk, "Title"))
    }

    @Test func undoTakesBackOneStepAtATime() {
        let desk = Self.desk()
        desk.draft = "Mira"
        desk.enter()
        desk.focus(Self.index(desk, "Title"))
        desk.draft = "CEO"
        desk.enter()
        desk.toggle(Self.index(desk, "Agree"))
        #expect(desk.boxes[Self.index(desk, "Agree")].value == "on")
        #expect(desk.steps.count == 3)

        desk.undo()
        #expect(desk.boxes[Self.index(desk, "Agree")].value == "")
        desk.undo()
        #expect(desk.boxes[Self.index(desk, "Title")].value == "")
        #expect(desk.boxes[Self.index(desk, "Name")].value == "Mira")
        desk.undo()
        #expect(desk.boxes[Self.index(desk, "Name")].value == "")
        #expect(!desk.changed)
        desk.redo()
        #expect(desk.boxes[Self.index(desk, "Name")].value == "Mira")
        #expect(desk.changed)
    }

    @Test func undoFirstDropsWhatIsBeingTyped() {
        let desk = Self.desk()
        desk.draft = "Half typ"
        desk.undo()
        #expect(desk.draft == "")
        #expect(desk.steps.isEmpty)
    }

    // MARK: Text

    @Test func aLineOfTextIsOneStep() {
        let desk = Self.desk(Self.contract(form: false))
        #expect(desk.mode == .text)
        let note = desk.write(on: 0, at: CGPoint(x: 300, y: 455))!
        desk.note = "Initialed by both parties"
        desk.commitNote()
        #expect(note.contents == "Initialed by both parties")
        #expect(desk.document.page(at: 0)!.annotations.contains(note))
        #expect(desk.steps.map(\.name) == ["Add Text"])
        // As big as the words around it: 10 here.
        #expect(note.font?.pointSize == 10)
        desk.undo()
        #expect(!desk.document.page(at: 0)!.annotations.contains(note))
        desk.redo()
        #expect(desk.document.page(at: 0)!.annotations.contains(note))
        // A line left empty is no step at all.
        desk.write(on: 0, at: CGPoint(x: 100, y: 100))
        desk.commitNote()
        #expect(desk.steps.count == 1)
        #expect(desk.document.page(at: 0)!.annotations.filter(PDFDesk.ours).count == 1)
    }

    // MARK: Sign

    @Test func theFirstSignOpensTheSheetAndTheSignatureFitsItsBox() {
        let shelf = SignatureMemory()
        let desk = Self.desk(shelf: shelf)
        desk.set(.sign)
        #expect(desk.sheet)
        #expect(desk.pad.name == "Sam Rivera")
        desk.pad.way = .mouse
        desk.pad.ink = { var ink = PenInk(); ink.begin(CGPoint(x: 20, y: 40), at: 0); for i in 1...30 { ink.add(CGPoint(x: 20 + Double(i) * 8, y: 40 + Double(i % 5) * 6), at: Double(i) * 0.01) }; return ink }()
        desk.finishSheet()
        #expect(!desk.sheet)
        #expect(shelf.all().map(\.id) == ["Yab Signature 1"])
        let box = desk.boxes[Self.index(desk, "Signature")]
        let stamp = desk.sign(on: 0, at: CGPoint(x: box.bounds.midX, y: box.bounds.midY))!
        #expect(box.bounds.insetBy(dx: -1, dy: -1).contains(stamp.bounds))
        #expect(stamp.bounds.height > box.bounds.height * 0.5)
        #expect(desk.selected === stamp)
        desk.deleteSelected()
        #expect(!desk.document.page(at: 0)!.annotations.contains(stamp))
        desk.undo()
        #expect(desk.document.page(at: 0)!.annotations.contains(stamp))
        desk.undo()
        #expect(!desk.document.page(at: 0)!.annotations.contains(stamp))
    }

    @Test func aSignatureWithNoBoxStandsWhereTheClickWas() {
        let shelf = SignatureMemory()
        shelf.keep(Self.signature(), initials: false)
        let desk = Self.desk(Self.contract(form: false), shelf: shelf)
        desk.set(.sign)
        #expect(!desk.sheet)
        let stamp = desk.sign(on: 0, at: CGPoint(x: 300, y: 150))!
        #expect(abs(stamp.bounds.midX - 300) <= 1)
        #expect(abs(stamp.bounds.midY - 150) <= 1)
        #expect(stamp.bounds.height == 36)
        // Moved and resized, one step each.
        let before = stamp.bounds
        desk.drag(stamp, to: before.offsetBy(dx: 20, dy: -10))
        desk.moved(stamp, from: before)
        #expect(desk.steps.map(\.name) == ["Sign", "Move Signature"])
        desk.undo()
        #expect(stamp.bounds == before)
    }

    @Test func aTypedSignatureIsAPicture() {
        let png = Signature.picture(typing: "Sam Rivera", hand: SignatureInk.hands[0])
        #expect(png != nil)
        let signature = Signature(id: "Yab Signature 1", png: png!)
        #expect(signature.size.width > signature.size.height * 2)
        #expect(SignatureSheetModel.initials(of: "Sam Rivera") == "S.R.")
    }

    @Test func inkThinsAsItSpeedsUp() {
        #expect(PenInk.width(speed: 0, base: 2.6) == 2.6)
        #expect(PenInk.width(speed: 5000, base: 2.6) < 1.3)
        var ink = PenInk()
        ink.begin(CGPoint(x: 0, y: 0), at: 0)
        ink.add(CGPoint(x: 10, y: 10), at: 0.1)
        ink.add(CGPoint(x: 20, y: 0), at: 0.2)
        let line = PenInk.smooth(ink.strokes[0], base: 2.6)
        #expect(line.count == 13)
        #expect(line.first?.0 == CGPoint(x: 0, y: 0))
        #expect(line.last?.0 == CGPoint(x: 20, y: 0))
        // A picture with nothing behind the ink.
        let picture = Signature(id: "s", png: Signature.picture(of: ink)!).image!
        #expect(picture.alphaInfo == .premultipliedLast || picture.alphaInfo == .last)
    }

    // MARK: Done

    @Test func doneMakesAFileWithEverythingPressedIn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Acme-MSA.pdf")
        try Self.contract().dataRepresentation()!.write(to: original)
        let before = try Data(contentsOf: original)

        let shelf = SignatureMemory()
        shelf.keep(Self.signature(), initials: false)
        let desk = PDFDesk(document: PDFDocument(url: original)!, source: original, profile: Self.sam, address: Self.address,
                           today: Self.day, shelf: shelf)
        desk.enter() // Name
        desk.step(1) // past Company size
        desk.enter() // Title
        desk.enter() // Date
        desk.set(.sign)
        let box = desk.boxes[Self.index(desk, "Signature")]
        let stamp = desk.sign(on: 0, at: CGPoint(x: box.bounds.midX, y: box.bounds.midY))!
        desk.set(.text)
        desk.write(on: 0, at: CGPoint(x: 72, y: 180))
        desk.note = "Countersigned"
        let data = try #require(desk.finish())

        let signed = folder.appendingPathComponent(PDFFill.signedName(for: original))
        #expect(signed.lastPathComponent == "Acme-MSA signed.pdf")
        try data.write(to: signed)
        let back = try #require(PDFDocument(url: signed))
        let page = try #require(back.page(at: 0))
        // No form left to change.
        #expect(page.annotations.isEmpty)
        let words = page.string ?? ""
        #expect(words.contains("Sam Rivera"))
        #expect(words.contains("Founder"))
        #expect(words.contains("October 20, 2026"))
        #expect(words.contains("Countersigned"))
        #expect(words.contains("Master Services Agreement"))
        // The signature's ink where it was put.
        #expect(Self.blue(in: stamp.bounds, of: page))
        #expect(!Self.blue(in: CGRect(x: 400, y: 224, width: 100, height: 40), of: page))
        // The PDF it came from as it was.
        #expect(try Data(contentsOf: original) == before)
        let untouched = try #require(PDFDocument(url: original)?.page(at: 0))
        #expect(untouched.annotations.filter { $0.type == "Widget" && $0.widgetFieldType == .text }.allSatisfy { ($0.widgetStringValue ?? "").isEmpty })
    }

    @Test func signedNames() {
        #expect(PDFFill.signedName(for: URL(string: "https://acme.example/docs/Acme-MSA.pdf")) == "Acme-MSA signed.pdf")
        #expect(PDFFill.signedName(for: URL(string: "https://acme.example/Lease%202026.pdf")) == "Lease 2026 signed.pdf")
        #expect(PDFFill.signedName(for: URL(string: "https://acme.example/download")) == "download signed.pdf")
        #expect(PDFFill.signedName(for: nil, suggested: "Offer.PDF") == "Offer signed.pdf")
        #expect(PDFFill.signedName(for: URL(fileURLWithPath: "/tmp/Acme-MSA signed.pdf")) == "Acme-MSA signed.pdf")
    }

    /// Whether the page drawn has the signature's blue ink inside `rect`.
    static func blue(in rect: CGRect, of page: PDFPage) -> Bool {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width), height = Int(box.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                // Rows from the top in memory.
                let at = ((height - 1 - y) * width + x) * 4
                let r = Int(pixels[at]), g = Int(pixels[at + 1]), b = Int(pixels[at + 2])
                if b > 100, b > r + 40, b > g + 20 { return true }
            }
        }
        return false
    }
}
