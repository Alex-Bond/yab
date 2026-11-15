import AppKit
import SwiftUI

// The words of a reply or a new mail (docs/mail.md, Writing): the system's
// own text view, rich, its marks kept to what a mail carries (MailRich).
// ⌘B, ⌘I and ⌘U mark words; ⇧⌘8 and ⇧⌘7 make lists, ⇥ and ⇧⇥ nest them, ↩
// on an empty item or ⌫ at an item's start takes it out a level; ⇧⌘9
// quotes lines. An address pasted over chosen words makes them its link.
// Words pasted or dropped from another app keep only those marks, and
// words copied from here carry their HTML. Files pasted or dropped on it,
// and a picture pasted, go to the draft as files, never into the words.

/// The reply's words, as tall as what is written; they take the keyboard
/// when asked. The draft keeps them twice: plain, and their HTML when they
/// carry a mark ("" when they don't).
struct MailWords: NSViewRepresentable {
    let body: String
    let html: String
    /// The words changed here: plain, and their HTML ("" when unmarked).
    var changed: (String, String) -> Void = { _, _ in }
    let focus: Int
    /// Where the caret stands when they take the keyboard: after Quick
    /// Quote's words, else at the start.
    var caret = 0
    let toFirst: Bool
    /// The letter in front's: the desk marks and inserts through it (⌘K's
    /// Bold, a snippet).
    var live = true
    var files: ([URL]) -> Void = { _ in }
    var picture: (Data) -> Void = { _ in }
    /// Files are being dragged over the words, or no longer.
    var dropping: (Bool) -> Void = { _ in }
    /// The caret moved, or the words changed.
    var moved: () -> Void = {}
    /// The words grew or shrank by a line: how tall they are now. The
    /// words are kept at every key without drawing what holds them again,
    /// which is told only this, and hands it back here as `tall` to have
    /// them laid out again.
    var grew: (CGFloat) -> Void = { _ in }
    var tall: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = MailWordsView.make()
        hand(view)
        view.delegate = context.coordinator
        view.words = (body, html)
        context.coordinator.kept = (body, html)
        context.coordinator.changed = changed
        context.coordinator.grew = grew
        if live { MailDesk.shared.words = view }
        return view
    }

    /// What the view does with files and pictures, and the caret's moves.
    private func hand(_ view: MailWordsView) {
        view.files = files
        view.picture = picture
        view.dropping = dropping
        view.moved = moved
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard let view = view as? MailWordsView else { return }
        hand(view)
        context.coordinator.changed = changed
        context.coordinator.grew = grew
        if live { MailDesk.shared.words = view }
        if context.coordinator.told != tall {
            context.coordinator.told = tall
            view.invalidateIntrinsicContentSize()
        }
        // Changed from elsewhere (Claude wrote them, Quick Quote, a draft
        // opened again): set anew; what was typed here comes back the same.
        if context.coordinator.kept != (body, html) {
            view.words = (body, html)
            context.coordinator.kept = (body, html)
        }
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            if !toFirst {
                let caret = caret
                DispatchQueue.main.async {
                    view.window?.makeFirstResponder(view)
                    view.setSelectedRange(NSRange(location: min(caret, (view.string as NSString).length), length: 0))
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let size = NSSize(width: width, height: .greatestFiniteMagnitude)
        if container.containerSize != size { container.containerSize = size }
        let tall = Self.tall(nsView)
        context.coordinator.tall = tall
        return CGSize(width: width, height: tall)
    }

    /// As tall as the words: three lines at least.
    static func tall(_ view: NSTextView) -> CGFloat {
        guard let container = view.textContainer, let layout = view.layoutManager else { return 63 }
        layout.ensureLayout(for: container)
        return max(63, layout.usedRect(for: container).height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var changed: (String, String) -> Void = { _, _ in }
        var grew: (CGFloat) -> Void = { _ in }
        var focus = 0
        /// The words as they were last handed in or out: what the draft has.
        var kept: (body: String, html: String) = ("", "")
        /// How tall the words were when last laid out, and when last handed back.
        var tall: CGFloat = 0
        var told: CGFloat = 0

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? MailWordsView else { return }
            let words = view.words
            kept = words
            changed(words.body, words.html)
            let now = MailWords.tall(view)
            if now != tall {
                tall = now
                grew(now)
            }
        }

        func textViewDidChangeSelection(_ note: Notification) {
            (note.object as? MailWordsView)?.moved?()
        }

        /// The words' own undo (MailWordsView.edits): their keys go with them.
        func undoManager(for view: NSTextView) -> UndoManager? {
            (view as? MailWordsView)?.edits
        }

        /// A link in the words being written is words to edit: a click puts
        /// the caret there; with ⌘ it opens, as a mail's link does.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if NSEvent.modifierFlags.contains(.command), let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) {
                MainActor.assumeIsolated { MailDesk.shared.follow(url, flags: .command) }
            } else {
                textView.setSelectedRange(NSRange(location: charIndex, length: 0))
            }
            return true
        }
    }
}

/// The words' own text view: rich, on TextKit 1, whose lines it reads to
/// draw a list's markers and a quote's bar in the room a line's blocks
/// leave on its left. Files pasted or dropped on it, and a picture pasted
/// with no words (a screenshot, Copy Image), go to the draft as files;
/// words pasted keep only a mail's marks.
final class MailWordsView: NSTextView, NSTextStorageDelegate {
    var files: (([URL]) -> Void)?
    var picture: ((Data) -> Void)?
    var dropping: ((Bool) -> Void)?
    var moved: (() -> Void)?
    /// How its words are drawn (MailRich.words, or a signature's in Settings).
    var look = MailRich.words

    /// The words as lines, each with where it starts: read whole once, then
    /// again at each edit only where it touched (a key, a mark, a paste),
    /// so a key in a long mail costs a line, not the mail.
    private struct Lines {
        var lines: [MailRich.Line]
        var starts: [Int]
        var length: Int
        /// Each line's own HTML once written (MailRich.inline); nil until then.
        var said: [String?]
    }
    private var read: Lines?
    private var fonts = MailRich.Fonts()
    /// How many lines were read, whole or again: what a key costs, for the tests.
    private(set) var linesRead = 0
    /// Where the words changed since they were last tidied.
    private var touched: NSRange?
    /// A line came or went, or stands elsewhere: a number further down may
    /// have changed with it.
    private var restacked = false

    // MARK: - its own undo

    /// The words' typing, to undo in the words, never in the window. AppKit
    /// files each key in the window's undo by default, against the view's
    /// text storage, and leaves it there when the view goes: a reply sent,
    /// closed or put away kept its keys in the window's undo after its words
    /// were freed, and ⌘Z on a page hours later sent _undoRedoTextOperation:
    /// to freed memory (0.0.9). Handed to AppKit by the delegate
    /// (MailWords.Coordinator), which AppKit asks both to file a key and on
    /// ⌘Z; a view's own undoManager is never asked on ⌘Z.
    let edits = UndoManager()

    /// A view for a mail's words, set up as a reply's are.
    static func make(look: MailRich.Look = MailRich.words) -> MailWordsView {
        let view = MailWordsView(usingTextLayoutManager: false)
        AppleWritingTools.shared.apply(to: view)
        view.look = look
        view.isRichText = true
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.allowsUndo = true
        view.drawsBackground = false
        // On the surface's own 16 pt edge, 21 pt lines as the mail's words.
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        // An address typed is its link, as Gmail makes it; one that says only
        // itself leaves the mail plain (MailRich.formatted).
        view.isAutomaticLinkDetectionEnabled = true
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        view.defaultParagraphStyle = MailRich.paragraph([], look: look)
        view.typingAttributes = MailRich.attributes(MailRich.Run(text: ""), blocks: [], look: look)
        view.textStorage?.delegate = view
        return view
    }

    // MARK: - the words in and out

    /// The words as the draft keeps them: plain, and their HTML when they
    /// carry a mark ("" when not). Set, they are drawn anew from the HTML,
    /// or from the plain words when there is none.
    var words: (body: String, html: String) {
        get {
            let doc = lines()
            guard MailRich.formatted(doc) else { return (string, "") }
            let trimmed = MailRich.trimmed(doc)
            return (MailRich.text(doc), MailRich.html(trimmed, said: said(trimmed.count)))
        }
        set {
            let doc = newValue.html.isEmpty ? MailRich.plain(newValue.body) : MailRich.doc(html: newValue.html)
            textStorage?.setAttributedString(MailRich.attributed(doc, look: look))
            typingAttributes = MailRich.attributes(MailRich.Run(text: ""), blocks: [], look: look)
            needsDisplay = true
            // Read as lines now, as they are set, not at the first key; drawn
            // and standing as they should already.
            _ = lines()
            restacked = false
            touched = nil
        }
    }

    /// Words put in where the caret is, as if typed or pasted (a paste, a
    /// snippet, free times), with their own marks: the first line joins the
    /// line the caret is on and stands where it does, unless that line is
    /// empty; the rest stand where they say.
    func insert(_ doc: MailRich.Doc) {
        guard !doc.isEmpty else { return }
        let range = selectedRange()
        let here = (string as NSString).paragraphRange(for: range)
        var doc = doc
        if content(of: here).length > 0 || doc.count == 1 { doc[0].blocks = blocks(of: here) }
        // Its marks are the pasted words', not the ones about to be typed.
        insertText(MailRich.attributed(doc, look: look), replacementRange: range)
    }

    /// Plain words put in where the caret is, as typed: a snippet, free times.
    func insert(_ text: String) { insert(MailRich.plain(text)) }

    // MARK: - the lines kept

    /// The words as lines (MailRich.doc), from what is kept.
    func lines() -> MailRich.Doc {
        guard let storage = textStorage else { return [] }
        if let read, read.length == storage.length, storage.delegate === self { return read.lines }
        let all = MailRich.lines(of: storage, from: 0, until: storage.length + 1, fonts: &fonts)
        linesRead += all.count
        read = Lines(lines: all.map(\.line), starts: all.map(\.start), length: storage.length, said: Array(repeating: nil, count: all.count))
        return read?.lines ?? []
    }

    /// The first lines' own HTML, each written once after it was read.
    private func said(_ count: Int) -> [String] {
        guard let kept = read?.lines, kept.count >= count else { return lines().prefix(count).map { MailRich.inline($0.runs) } }
        var out: [String] = []
        out.reserveCapacity(count)
        for at in 0..<count {
            if let one = read?.said[at] ?? nil {
                out.append(one)
            } else {
                let one = MailRich.inline(kept[at].runs)
                read?.said[at] = one
                out.append(one)
            }
        }
        return out
    }

    /// Every edit of the words, as it is made: the lines it touched read
    /// again, with one more on each side for a CR and an LF that join or
    /// part, the ones after it moved along.
    nonisolated func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange,
                                 changeInLength delta: Int) {
        MainActor.assumeIsolated { edited(storage, range: range, delta: delta) }
    }

    private func edited(_ storage: NSTextStorage, range: NSRange, delta: Int) {
        if let was = touched {
            let end = max(NSMaxRange(was) + (NSMaxRange(was) > range.location ? max(delta, 0) : 0), NSMaxRange(range))
            let start = min(was.location, range.location)
            touched = NSRange(location: start, length: min(end, storage.length) - min(start, storage.length))
        } else {
            touched = range
        }
        guard var kept = read, kept.length == storage.length - delta, !kept.starts.isEmpty else {
            read = nil
            restacked = true
            return
        }
        // Changed in place, not copied: nothing else holds them meanwhile.
        read = nil
        // The last line starting at a place, or before it.
        func line(at place: Int) -> Int {
            var low = 0, high = kept.starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if kept.starts[middle] <= place { low = middle } else { high = middle - 1 }
            }
            return low
        }
        let first = max(0, line(at: range.location) - 1)
        let last = min(kept.starts.count - 1, line(at: NSMaxRange(range) - delta) + 1)
        let until = last + 1 < kept.starts.count ? kept.starts[last + 1] + delta : storage.length + 1
        let again = MailRich.lines(of: storage, from: kept.starts[first], until: until, fonts: &fonts)
        linesRead += again.count
        if again.count != last - first + 1 || !zip(again, kept.lines[first...last]).allSatisfy({ $0.line.blocks == $1.blocks }) {
            restacked = true
        }
        kept.lines.replaceSubrange(first...last, with: again.map(\.line))
        kept.starts.replaceSubrange(first...last, with: again.map(\.start))
        kept.said.replaceSubrange(first...last, with: Array(repeating: nil, count: again.count))
        for at in (first + again.count)..<kept.starts.count { kept.starts[at] += delta }
        kept.length = storage.length
        read = kept
    }

    // MARK: - marks

    /// A mark on the words chosen, or off when they all have it already;
    /// with none chosen, on or off for what is typed next. A list or a
    /// quote on every line the choice touches.
    func apply(_ mark: MailRich.Mark) {
        switch mark {
        case .bold, .italic, .underline: toggle(mark)
        case .bullets: list(.bullet)
        case .numbers: list(.number)
        case .quote:
            let lines = paragraphs(for: selectedRange())
            let quoted = lines.allSatisfy { blocks(of: $0).first == .quote }
            change(lines, mark.title) { blocks in quoted ? blocks.filter { $0 != .quote } : blocks.first == .quote ? blocks : [.quote] + blocks }
        }
    }

    private func toggle(_ mark: MailRich.Mark) {
        let range = selectedRange()
        guard let storage = textStorage else { return }
        guard range.length > 0 else {
            typingAttributes = Self.marked(typingAttributes, mark, on: !Self.has(typingAttributes, mark))
            return
        }
        var all = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if !Self.has(attributes, mark) { all = false; stop.pointee = true }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, part, _ in
            storage.setAttributes(Self.marked(attributes, mark, on: !all), range: part)
        }
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(mark.title)
    }

    private static func has(_ attributes: [NSAttributedString.Key: Any], _ mark: MailRich.Mark) -> Bool {
        switch mark {
        case .bold, .italic:
            guard let font = attributes[.font] as? NSFont else { return false }
            let traits = MailRich.traits(font)
            return mark == .bold ? traits.bold : traits.italic
        case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
        default: return false
        }
    }

    private static func marked(_ attributes: [NSAttributedString.Key: Any], _ mark: MailRich.Mark, on: Bool) -> [NSAttributedString.Key: Any] {
        var out = attributes
        switch mark {
        case .bold, .italic:
            let font = attributes[.font] as? NSFont ?? MailRich.words.font
            let traits = MailRich.traits(font)
            out[.font] = MailRich.font(font, bold: mark == .bold ? on : traits.bold, italic: mark == .italic ? on : traits.italic)
        case .underline:
            out[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        default: break
        }
        return out
    }

    /// ⇧⌘8, ⇧⌘7: the lines chosen a list of this kind; again, plain lines.
    /// Lines in the other kind of list change kind.
    private func list(_ kind: MailRich.Block) {
        let lines = paragraphs(for: selectedRange())
        let all = lines.allSatisfy { blocks(of: $0).last == kind }
        change(lines, kind == .bullet ? MailRich.Mark.bullets.title : MailRich.Mark.numbers.title) { blocks in
            var blocks = blocks
            if all {
                blocks.removeLast()
            } else if let last = blocks.last, last.list {
                blocks[blocks.count - 1] = kind
            } else {
                blocks.append(kind)
            }
            return blocks
        }
    }

    // MARK: - lines

    /// The lines a range touches, each with its newline; and the empty
    /// last one when the range ends there, which has no characters (what
    /// stands there is the typing attributes').
    private func paragraphs(for range: NSRange) -> [NSRange] {
        let text = string as NSString
        var out: [NSRange] = []
        var at = range.location
        repeat {
            let line = text.paragraphRange(for: NSRange(location: min(at, text.length), length: 0))
            out.append(line)
            guard NSMaxRange(line) > at else { break }
            at = NSMaxRange(line)
        } while at < NSMaxRange(range)
        if NSMaxRange(range) == text.length, text.length > 0, text.character(at: text.length - 1) == 10,
           out.last.map(NSMaxRange) == text.length, out.last?.length != 0 {
            out.append(NSRange(location: text.length, length: 0))
        }
        return out
    }

    /// A line without its newline.
    private func content(of line: NSRange) -> NSRange {
        let text = string as NSString
        var length = line.length
        while length > 0, [10, 13, 0x2028, 0x2029].contains(text.character(at: line.location + length - 1)) { length -= 1 }
        return NSRange(location: line.location, length: length)
    }

    /// Where a line stands: its first character's say, or the typing
    /// attributes' for the empty last line.
    private func blocks(of line: NSRange) -> [MailRich.Block] {
        guard line.length > 0, let storage = textStorage, line.location < storage.length else {
            return MailRich.blocks(typingAttributes[MailRich.blocksKey])
        }
        return MailRich.blocks(storage.attribute(MailRich.blocksKey, at: line.location, effectiveRange: nil))
    }

    /// Lines stood somewhere else, in one step to undo: their blocks and
    /// their room on the left; the caret's typing attributes with them.
    private func change(_ lines: [NSRange], _ name: String, _ transform: ([MailRich.Block]) -> [MailRich.Block]) {
        guard let storage = textStorage, !lines.isEmpty else { return }
        let caret = (string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        let whole = lines.dropFirst().reduce(lines[0]) { NSUnionRange($0, $1) }
        var typed: [MailRich.Block]?
        if whole.length > 0 {
            guard shouldChangeText(in: whole, replacementString: nil) else { return }
            storage.beginEditing()
            for line in lines where line.length > 0 {
                let blocks = MailRich.order(transform(blocks(of: line)))
                storage.addAttribute(.paragraphStyle, value: MailRich.paragraph(blocks, look: look), range: line)
                if let value = MailRich.value(blocks) {
                    storage.addAttribute(MailRich.blocksKey, value: value, range: line)
                } else {
                    storage.removeAttribute(MailRich.blocksKey, range: line)
                }
                if NSIntersectionRange(line, caret).length > 0 || line.location == caret.location { typed = blocks }
            }
            storage.endEditing()
        }
        // The empty last line, or the caret's: what is typed next stands there too.
        if let last = lines.last, last.length == 0 { typed = MailRich.order(transform(blocks(of: last))) }
        if let typed {
            var attributes = typingAttributes
            attributes[.paragraphStyle] = MailRich.paragraph(typed, look: look)
            attributes[MailRich.blocksKey] = MailRich.value(typed)
            typingAttributes = attributes
        }
        if whole.length > 0 {
            didChangeText()
            undoManager?.setActionName(name)
        } else {
            // Nothing in the words changed but where the next line stands: the draft hears it all the same.
            delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
        }
        needsDisplay = true
    }

    /// ↩ on an empty item or an empty quoted line: out a level, not a new one.
    override func insertNewline(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0 {
            let line = (string as NSString).paragraphRange(for: range)
            if content(of: line).length == 0, !blocks(of: line).isEmpty {
                change([line], "Typing") { Array($0.dropLast()) }
                return
            }
        }
        super.insertNewline(sender)
    }

    /// ⌫ at the start of an item or a quoted line: out a level, its words kept.
    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0 {
            let line = (string as NSString).paragraphRange(for: range)
            if range.location == line.location, !blocks(of: line).isEmpty {
                change([line], "Typing") { Array($0.dropLast()) }
                return
            }
        }
        super.deleteBackward(sender)
    }

    /// ⇥ in a list: its lines a level deeper, the same kind of list.
    override func insertTab(_ sender: Any?) {
        let lines = paragraphs(for: selectedRange())
        guard lines.allSatisfy({ blocks(of: $0).last?.list == true }) else { return super.insertTab(sender) }
        change(lines, "Indent") { blocks in blocks.count < MailRich.deepest ? blocks + [blocks[blocks.count - 1]] : blocks }
    }

    /// ⇧⇥ in a list: a level up.
    override func insertBacktab(_ sender: Any?) {
        let lines = paragraphs(for: selectedRange())
        guard lines.allSatisfy({ blocks(of: $0).last?.list == true }) else { return super.insertBacktab(sender) }
        change(lines, "Outdent") { Array($0.dropLast()) }
    }

    /// A line's characters all stand where its first does: words typed or
    /// pasted into it, two lines made one by ⌫.
    override func didChangeText() {
        tidy()
        super.didChangeText()
        // A number further down may have changed with a line here.
        if restacked { needsDisplay = true }
        restacked = false
    }

    /// The lines changed since the last time, each standing where its first
    /// character does.
    private func tidy() {
        defer { touched = nil }
        guard let storage = textStorage, storage.length > 0 else { return }
        let text = storage.mutableString
        let span = touched.map { NSIntersectionRange($0, NSRange(location: 0, length: text.length)) } ?? NSRange(location: 0, length: text.length)
        var at = min(span.location, text.length - 1)
        var fixes: [(NSRange, [MailRich.Block])] = []
        while at < text.length {
            let line = text.paragraphRange(for: NSRange(location: at, length: 0))
            var effective = NSRange()
            let first = storage.attribute(MailRich.blocksKey, at: line.location, longestEffectiveRange: &effective, in: line) as? String
            if NSMaxRange(effective) < NSMaxRange(line) { fixes.append((line, MailRich.blocks(first))) }
            at = max(NSMaxRange(line), at + 1)
            if at > NSMaxRange(span) { break }
        }
        guard !fixes.isEmpty else { return }
        storage.beginEditing()
        for (line, blocks) in fixes {
            storage.addAttribute(.paragraphStyle, value: MailRich.paragraph(blocks, look: look), range: line)
            if let value = MailRich.value(blocks) {
                storage.addAttribute(MailRich.blocksKey, value: value, range: line)
            } else {
                storage.removeAttribute(MailRich.blocksKey, range: line)
            }
        }
        storage.endEditing()
    }

    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            super.typingAttributes = newValue
            // The empty last line's marker follows what is typed next.
            let text = textStorage?.mutableString
            let length = text?.length ?? 0
            if length == 0 || text?.character(at: length - 1) == 10 { needsDisplay = true }
        }
    }

    // MARK: - markers and bars

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawBlocks(in: rect)
    }

    /// Each list item's marker ("•", "◦", "▪" as it nests, or its number)
    /// in the room its list leaves, on its first line's baseline; a quote's
    /// bar down every line it holds.
    private func drawBlocks(in rect: NSRect) {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        let text = storage.mutableString
        var lines: [(range: NSRange, blocks: [MailRich.Block])] = []
        var at = 0
        while at < text.length {
            let line = text.paragraphRange(for: NSRange(location: at, length: 0))
            lines.append((line, MailRich.blocks(storage.attribute(MailRich.blocksKey, at: line.location, effectiveRange: nil))))
            at = max(NSMaxRange(line), at + 1)
        }
        if text.length == 0 || text.character(at: text.length - 1) == 10 {
            lines.append((NSRange(location: text.length, length: 0), MailRich.blocks(typingAttributes[MailRich.blocksKey])))
        }
        guard lines.contains(where: { !$0.blocks.isEmpty }) else { return }
        let numbers = MailRich.numbers(lines.map { MailRich.Line($0.blocks, []) })
        let origin = textContainerOrigin
        // The characters drawn here: lines elsewhere aren't looked at again.
        let shown = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRectWithoutAdditionalLayout: rect.offsetBy(dx: -origin.x, dy: -origin.y),
                                                                            in: container), actualGlyphRange: nil)
        // Where a line's baseline stands below its top: as its words', or as an empty line's would.
        let empty = (look.line - layout.defaultLineHeight(for: look.font)) + layout.defaultBaselineOffset(for: look.font)
        let marker: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: look.font.pointSize, weight: .regular),
                                                     .foregroundColor: look.color]
        for (n, line) in lines.enumerated() where !line.blocks.isEmpty {
            if line.range.length > 0, NSMaxRange(line.range) < shown.location || line.range.location > NSMaxRange(shown) { continue }
            let top: NSRect, bottom: NSRect
            var baseline = empty
            if line.range.length == 0 {
                top = layout.extraLineFragmentRect
                bottom = top
                guard !top.isEmpty else { continue }
            } else {
                let first = layout.glyphIndexForCharacter(at: line.range.location)
                let last = layout.glyphIndexForCharacter(at: NSMaxRange(line.range) - 1)
                top = layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil)
                bottom = layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
                baseline = layout.location(forGlyphAt: first).y
            }
            let y = top.minY + origin.y, height = bottom.maxY - top.minY
            guard NSRect(x: rect.minX, y: y, width: rect.width, height: height).intersects(rect) else { continue }
            var x = origin.x
            for block in line.blocks {
                if block == .quote {
                    NSColor.tertiaryLabelColor.setFill()
                    NSRect(x: x + 1, y: y, width: 2, height: height).fill()
                }
                x += block == .quote ? MailRich.quoteIndent : MailRich.listIndent
            }
            guard let kind = line.blocks.last, kind.list else { continue }
            let depth = line.blocks.filter(\.list).count
            let said = kind == .number ? "\(numbers[n] ?? 1)." : ["•", "◦", "▪"][(depth - 1) % 3]
            let size = (said as NSString).size(withAttributes: marker)
            let font = marker[.font] as? NSFont ?? look.font
            (said as NSString).draw(at: NSPoint(x: x - 6 - size.width, y: y + baseline - font.ascender), withAttributes: marker)
        }
    }

    // MARK: - keys of its own

    /// The marks' keys where mail's own keys don't reach (a signature in
    /// Settings › Mail): as Settings › Shortcuts has them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let mark = MailRich.Mark.allCases.first(where: { Keymap.shared.matches(event, $0.action) }) {
            apply(mark)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - pasting and dropping

    /// Files on a pasteboard: files only, never a link.
    static func files(on board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// A picture on a pasteboard that has no words.
    static func picture(on board: NSPasteboard) -> Data? {
        guard board.string(forType: .string) == nil else { return nil }
        return board.data(forType: .png) ?? board.data(forType: .tiff)
    }

    /// Paste is on for files and a picture too, not only for words.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, files != nil,
           !MailWordsView.files(on: .general).isEmpty || MailWordsView.picture(on: .general) != nil { return true }
        return super.validateMenuItem(item)
    }

    override func paste(_ sender: Any?) {
        if !take(from: .general) { super.paste(sender) }
    }

    /// ⌥⇧⌘V: the words alone, marked as what is typed next.
    override func pasteAsPlainText(_ sender: Any?) {
        guard let words = NSPasteboard.general.string(forType: .string) else { return super.pasteAsPlainText(sender) }
        insertText(words.replacingOccurrences(of: "\r\n", with: "\n"), replacementRange: selectedRange())
    }

    /// Files or a picture on a pasteboard, to the draft: false when it has
    /// neither, and the words take what it has.
    func take(from board: NSPasteboard) -> Bool {
        let urls = MailWordsView.files(on: board)
        if !urls.isEmpty, let files {
            files(urls)
            return true
        }
        if let data = MailWordsView.picture(on: board), let picture {
            picture(data)
            return true
        }
        return false
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let mine: [NSPasteboard.PasteboardType] = [.html, .rtfd, .rtf, .string]
        return mine + super.readablePasteboardTypes.filter { !mine.contains($0) }
    }

    /// Words pasted or dropped: an address over chosen words makes them its
    /// link; anything else comes in with a mail's marks only (MailRich).
    override func readSelection(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if link(from: board) { return true }
        guard let doc = MailRich.doc(from: board) else { return super.readSelection(from: board, type: type) }
        insert(doc)
        return true
    }

    /// Words copied carry their HTML too: pasted here again they come back
    /// as they were, and a mail or a page elsewhere takes their marks.
    override func writeSelection(to board: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let wrote = super.writeSelection(to: board, types: types)
        let range = selectedRange()
        guard wrote, range.length > 0, let storage = textStorage else { return wrote }
        board.addTypes([.html], owner: nil)
        board.setString(MailRich.html(MailRich.doc(storage.attributedSubstring(from: range))), forType: .html)
        return true
    }

    /// An address pasted over chosen words: the words become its link.
    private func link(from board: NSPasteboard) -> Bool {
        let range = selectedRange()
        guard range.length > 0, let words = board.string(forType: .string), let link = MailRich.address(words),
              !(string as NSString).substring(with: range).contains("\n") else { return false }
        guard shouldChangeText(in: range, replacementString: nil) else { return true }
        textStorage?.addAttribute(.link, value: URL(string: link) ?? link, range: range)
        didChangeText()
        undoManager?.setActionName("Add Link")
        return true
    }

    /// Files dragged here from elsewhere, not words dragged within.
    private func dragged(_ info: NSDraggingInfo) -> [URL] {
        guard info.draggingSource as AnyObject? !== self else { return [] }
        return MailWordsView.files(on: info.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !dragged(sender).isEmpty else { return super.draggingEntered(sender) }
        dropping?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragged(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropping?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragged(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = dragged(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        dropping?(false)
        files?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, !dragged(sender).isEmpty { return }
        super.concludeDragOperation(sender)
    }
}
