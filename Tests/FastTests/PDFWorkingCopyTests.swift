import AppKit
import PDFKit
import Testing
@testable import Fast

@MainActor
struct PDFWorkingCopyTests {
    @MainActor
    struct Fixture {
        let root: URL
        let original: Data
        let source: URL
        let owner = UUID()
        let copy: PDFWorkingCopy
        init(pages: Int = 1) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-working-" + UUID().uuidString)
            let document = PDFSignTests.contract()
            for _ in 1..<max(1, pages) { document.insert(PDFSignTests.contract(form: false).page(at: 0)!, at: 0) }
            original = document.dataRepresentation()!
            source = root.appendingPathComponent("Contract.pdf")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try original.write(to: source)
            copy = PDFWorkingCopy(original: original, source: source, owner: owner, root: root.appendingPathComponent("working"))
        }
        func desk(restoring: Bool = false) -> PDFDesk {
            let desk = PDFSignTests.desk(PDFDocument(data: original)!)
            desk.keepWorking(in: copy, restoring: restoring ? copy.load() : nil)
            return desk
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func nativeViewportRestoresAcrossPageGapAfterLayout() async throws {
        let fixture = try Fixture(pages: 3)
        defer { fixture.clean() }
        let first = fixture.desk()
        first.set(.text)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1180, height: 740),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let firstView = PDFDeskView(desk: first)
        window.contentView = firstView
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); first.discardWorkingCopy(); fixture.copy.discard(wait: true) }
        let ready = try await Loaded.until(4) { first.viewport != nil }
        try #require(ready)
        first.position?(1, 0, 16.15, 1.25)
        func actual(_ desk: PDFDesk) -> PDFWorkingState.Viewport? {
            guard let shown = desk.shownViewport?(), let page = shown["page"] as? Int,
                  let x = shown["x"] as? CGFloat, let y = shown["y"] as? CGFloat,
                  let scale = shown["scale"] as? CGFloat else { return nil }
            return .init(page: page, point: CGPoint(x: x, y: y), scale: scale)
        }
        var previous: PDFWorkingState.Viewport?
        var lastChange = Date()
        let stable = try await Loaded.until(4) {
            let now = actual(first)
            if now != previous { previous = now; lastChange = Date() }
            return now != nil && Date().timeIntervalSince(lastChange) >= 0.7
        }
        try #require(stable)
        let before = try #require(actual(first))
        first.flushWorking(wait: true)
        let persisted = try #require(fixture.copy.load()?.viewport)
        #expect(persisted.page == before.page && abs(persisted.point.y - before.point.y) < 0.1 && abs(persisted.scale - before.scale) < 0.01,
                "The flush must persist the latest actual native viewport")
        let restored = fixture.desk(restoring: true)
        defer { restored.discardWorkingCopy() }
        let restoredView = PDFDeskView(desk: restored)
        window.contentView = restoredView
        var matchedAt: Date?
        let matches = try await Loaded.until(3) {
            guard let shown = restored.shownViewport?(), let page = shown["page"] as? Int,
                  let y = shown["y"] as? CGFloat, let scale = shown["scale"] as? CGFloat else { return false }
            let same = page == before.page && abs(y - before.point.y) < 5 && abs(scale - before.scale) < 0.01
            if !same { matchedAt = nil; return false }
            if matchedAt == nil { matchedAt = Date() }
            return Date().timeIntervalSince(matchedAt!) >= 0.7
        }
        #expect(matches, "Reopening must restore the actual native viewport, including a point in the gap above the last page")

        // Use PDFKit's own navigation to produce valid native positions at
        // both document ends; restoring must neither shift nor overscroll.
        var edgeDesk = restored
        var edgeView = restoredView
        var edgeCopies: [PDFDesk] = []
        defer { for copy in edgeCopies { copy.discardWorkingCopy() } }
        for pageIndex in [0, 2] {
            let page = try #require(edgeDesk.document.page(at: pageIndex))
            edgeView.pdf.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: pageIndex == 0 ? page.bounds(for: .mediaBox).maxY : 0)))
            var last: PDFWorkingState.Viewport?
            var changedAt = Date()
            let settled = try await Loaded.until(4) {
                let now = actual(edgeDesk)
                if now != last { last = now; changedAt = Date() }
                return now?.page == pageIndex && Date().timeIntervalSince(changedAt) >= 0.7
            }
            try #require(settled)
            let expected = try #require(actual(edgeDesk))
            edgeDesk.flushWorking(wait: true)
            let copy = fixture.desk(restoring: true)
            edgeCopies.append(copy)
            let view = PDFDeskView(desk: copy)
            window.contentView = view
            var edgeMatchedAt: Date?
            let same = try await Loaded.until(3) {
                guard let shown = actual(copy) else { return false }
                let matches = shown.page == expected.page && abs(shown.point.x - expected.point.x) < 5
                    && abs(shown.point.y - expected.point.y) < 5 && abs(shown.scale - expected.scale) < 0.01
                if !matches { edgeMatchedAt = nil; return false }
                if edgeMatchedAt == nil { edgeMatchedAt = Date() }
                return Date().timeIntervalSince(edgeMatchedAt!) >= 0.7
            }
            #expect(same, "Document end \(pageIndex) must roundtrip without overscroll: expected \(expected), actual \(String(describing: actual(copy)))")
            edgeDesk = copy
            edgeView = view
        }
    }

    @Test func fieldsTextSignatureAndPendingDraftSurviveIndependentDocuments() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let desk = fixture.desk()
        let origin = PDFMailOrigin(account: "fixture@example.test", thread: "fixture-thread", message: "fixture-message")
        desk.mailOrigin = origin
        desk.focus(PDFSignTests.index(desk, "Name"))
        desk.draft = "Persisted name"
        desk.commitField()
        desk.toggle(PDFSignTests.index(desk, "Agree"))
        desk.set(.text)
        desk.write(on: 0, at: CGPoint(x: 160, y: 540))
        desk.note = "Editable note"
        desk.commitNote()
        desk.adopt(PDFSignTests.signature())
        let signed = try #require(desk.sign(on: 0, at: CGPoint(x: 180, y: 245)))
        desk.set(.fill)
        desk.focus(PDFSignTests.index(desk, "Title"))
        desk.draft = "Still typing"
        desk.flushWorking(wait: true)

        let restored = fixture.desk(restoring: true)
        #expect(restored.document !== desk.document)
        #expect(restored.mailOrigin == origin)
        #expect(restored.restored && restored.changed && restored.steps.isEmpty)
        #expect(restored.boxes[PDFSignTests.index(restored, "Name")].value == "Persisted name")
        #expect(restored.boxes[PDFSignTests.index(restored, "Agree")].value == "on")
        #expect(restored.draft == "Still typing")
        #expect(restored.boxes[PDFSignTests.index(restored, "Title")].value == "")
        let page = try #require(restored.document.page(at: 0))
        #expect(page.annotations.contains { PDFDesk.ours($0) && $0.contents == "Editable note" })
        #expect(page.annotations.contains { ($0 as? PDFSignatureStamp)?.png == PDFSignTests.signature() })
        #expect(PDFSignTests.blue(in: signed.bounds, of: page))
        // Restoring never committed pending typing. New committed edits Undo
        // back to restored values, and the pending draft itself still undoes.
        restored.undo()
        #expect(restored.draft == "")
        restored.focus(PDFSignTests.index(restored, "Name"))
        restored.draft = "New edit"
        restored.commitField()
        restored.undo()
        #expect(restored.boxes[PDFSignTests.index(restored, "Name")].value == "Persisted name")
        restored.redo()
        #expect(restored.boxes[PDFSignTests.index(restored, "Name")].value == "New edit")
        let final = try #require(restored.finish().flatMap { PDFDocument(data: $0) })
        #expect(final.page(at: 0)?.annotations.isEmpty == true)
        #expect(final.string?.contains("Editable note") == true)
        #expect(PDFSignTests.blue(in: signed.bounds, of: try #require(final.page(at: 0))))
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(try Data(contentsOf: fixture.copy.folder.appendingPathComponent("original.pdf")) == fixture.original)
        desk.discardWorkingCopy()
        restored.discardWorkingCopy()
        fixture.copy.discard(wait: true)
    }

    @Test func unfinishedFreeTextIsRestoredWithoutChangingItsCommittedWords() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let desk = fixture.desk()
        desk.set(.text)
        let note = try #require(desk.write(on: 0, at: CGPoint(x: 180, y: 550)))
        desk.note = "Before"
        desk.commitNote()
        desk.rewrite(note)
        desk.note = "Unfinished rewrite"
        desk.flushWorking(wait: true)
        let restored = fixture.desk(restoring: true)
        #expect(restored.note == "Unfinished rewrite")
        #expect(restored.writing?.contents == "Before")
        #expect(restored.writing?.shouldDisplay == false)
        #expect(restored.steps.isEmpty && restored.changed)
        restored.commitNote()
        restored.undo()
        #expect(restored.document.page(at: 0)?.annotations.contains { $0.contents == "Before" } == true)
        restored.redo()
        #expect(restored.document.page(at: 0)?.annotations.contains { $0.contents == "Unfinished rewrite" } == true)
        desk.discardWorkingCopy()
        restored.discardWorkingCopy()
        fixture.copy.discard(wait: true)
    }

    @Test func typingCoalescesAndViewportOnlyWritesReuseContent() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let desk = fixture.desk()
        for index in 0..<100 { desk.draft = "Burst \(index)" }
        #expect(desk.snapshots == 0)
        let saved = try await Loaded.until(4) { desk.snapshots == 1 && fixture.copy.load()?.draft == "Burst 99" }
        #expect(saved)
        for index in 0..<100 {
            desk.movedViewport(.init(page: 0, point: CGPoint(x: index, y: 700), scale: 1.7))
        }
        let moved = try await Loaded.until(4) { fixture.copy.load()?.viewport?.point.x == 99 }
        #expect(moved && desk.snapshots == 1)
        #expect(desk.steps.isEmpty && desk.boxes[PDFSignTests.index(desk, "Name")].empty)
        desk.discardWorkingCopy()
        fixture.copy.discard(wait: true)
    }

    @Test func contentIdentityAndOwnerPreventFalseRestoresAndRetainOldDraft() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let desk = fixture.desk()
        desk.draft = "Recoverable"
        desk.flushWorking(wait: true)
        let otherOwner = PDFWorkingCopy(original: fixture.original, source: fixture.source, owner: UUID(), root: fixture.root.appendingPathComponent("working"))
        #expect(otherOwner.load() == nil)
        let different = PDFWorkingCopy(original: fixture.original + Data("\n% changed".utf8), source: fixture.source, owner: fixture.owner, root: fixture.root.appendingPathComponent("working"))
        #expect(different.load() == nil && different.folder != fixture.copy.folder)
        #expect(fixture.copy.load()?.draft == "Recoverable")
        var fragment = URLComponents(url: fixture.source, resolvingAgainstBaseURL: false)!
        fragment.fragment = "page=2"
        let same = PDFWorkingCopy(original: fixture.original, source: fragment.url, owner: fixture.owner, root: fixture.root.appendingPathComponent("working"))
        #expect(same.load()?.draft == "Recoverable")
        try Data("tampered".utf8).write(to: fixture.copy.folder.appendingPathComponent("original.pdf"))
        #expect(fixture.copy.load() == nil)
        desk.discardWorkingCopy()
        fixture.copy.discard(wait: true)
    }

    @Test func discardCannotBeResurrectedByAlreadyQueuedOrLaterSaves() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let desk = fixture.desk()
        desk.draft = "First"
        desk.flushWorking()
        desk.draft = "Pending"
        desk.discardWorkingCopy()
        desk.draft = "After discard"
        desk.flushWorking(wait: true)
        #expect(fixture.copy.load() == nil)
        fixture.copy.discard(wait: true)
    }

    @Test func finalizationStaysInactiveAndCleanModeDoesNotAutoReopen() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let desk = fixture.desk()
        desk.flushWorking(wait: true)
        #expect(fixture.copy.load()?.active == false)
        desk.draft = "Signed name"
        _ = desk.finish()
        desk.flushWorking(wait: true, active: false)
        desk.flushWorking(wait: true) // the termination notification's flush
        let state = try #require(fixture.copy.load())
        #expect(!state.active && state.changed)
        let reopened = fixture.desk(restoring: true)
        #expect(reopened.boxes[PDFSignTests.index(reopened, "Name")].value == "Signed name")
        #expect(reopened.changed)
        desk.discardWorkingCopy()
        reopened.discardWorkingCopy()
        fixture.copy.discard(wait: true)
    }

    @Test func failedStateEncodingKeepsTheLastGoodDraft() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let desk = fixture.desk()
        desk.draft = "Last good"
        desk.flushWorking(wait: true)
        var state = try #require(fixture.copy.load())
        state.draft = "Bad snapshot"
        state.viewport = .init(page: 0, point: .zero, scale: .nan)
        var failed = false
        fixture.copy.save(state, wait: true) { failed = $0 != nil }
        #expect(failed && fixture.copy.load()?.draft == "Last good")
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        desk.discardWorkingCopy()
        fixture.copy.discard(wait: true)
    }
}
