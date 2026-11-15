import AppKit
import YabCoreClient

/// The native editor's bounded UTF-16 snapshot, with AppKit's annotations.
/// Annotations never supply text or selection: the renderer remains the source
/// of both, and a different focused editor gets a different checking document.
@MainActor
final class ChromiumTextCheckingSnapshot {
    let focus: String
    let offset: Int
    let text: NSMutableAttributedString
    let selection: NSRange

    init?(state: [String: JSONValue]?) {
        guard let focus = ChromiumNativeTextInput.focusToken(state),
              let selection = ChromiumNativeTextInput.range(state?["selection"]) else { return nil }
        self.focus = focus
        self.selection = selection
        if let surrounding = state?["surrounding"]?.string,
           let offset = state?["surroundingOffset"]?.string.flatMap(Int.init),
           offset >= 0, offset <= Int.max - surrounding.utf16.count {
            self.offset = offset
            text = NSMutableAttributedString(string: surrounding)
        } else { return nil }
    }

    /// AppKit's standard range adjustment, limited to the available native
    /// window. Avoid adding an untrusted range's length to its location.
    func localRange(_ proposed: NSRange) -> NSRange? {
        if proposed.location == NSNotFound { return NSRange(location: 0, length: text.length) }
        guard proposed.location >= 0, proposed.length >= 0 else { return nil }
        let start = max(proposed.location, offset)
        let end = offset + text.length
        guard start <= end else { return nil }
        let skipped = start - proposed.location
        guard skipped <= proposed.length else { return nil }
        return NSRange(location: start - offset, length: min(proposed.length - skipped, end - start))
    }

    func documentRange(_ local: NSRange) -> NSRange {
        NSRange(location: offset + local.location, length: local.length)
    }

    /// Unlike annotation reads, an edit cannot truncate an unknown part of a
    /// document to the surrounding window: its replacement string describes
    /// the entire proposed range, not just the part we happen to have cached.
    func mutationRange(_ proposed: NSRange) -> NSRange? {
        guard proposed.location != NSNotFound, let local = localRange(proposed),
              documentRange(local) == proposed else { return nil }
        return proposed
    }
}

@MainActor
extension ChromiumPage {
    func syncNativeTextChecking(active: Bool) {
        guard active, let next = ChromiumTextCheckingSnapshot(state: nativeText) else {
            nativeTextChecking?.invalidate()
            nativeTextChecking = nil
            nativeTextCheckingSnapshot = nil
            return
        }
        let previous = nativeTextCheckingSnapshot
        let changedDocument = previous?.focus != next.focus
        let changedText = previous?.offset != next.offset || previous?.text.string != next.text.string
        if changedDocument {
            nativeTextChecking?.invalidate()
            nativeTextChecking = nil
        }
        // Preserve annotations only while their native text coordinates agree.
        if changedText || changedDocument { nativeTextCheckingSnapshot = next }
        else if let previous {
            next.text.setAttributedString(previous.text)
            nativeTextCheckingSnapshot = next
        }
        if nativeTextChecking == nil { nativeTextChecking = NSTextCheckingController(client: self) }
        if changedText {
            nativeTextChecking?.didChangeText(in: NSRange(location: next.offset, length: next.text.length))
        }
        if previous?.selection != next.selection || changedDocument {
            nativeTextChecking?.didChangeSelectedRange()
        }
    }

    override func annotatedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard nativeInputEligible, let snapshot = nativeTextCheckingSnapshot,
              let local = snapshot.localRange(range) else { return nil }
        // AppKit asks for paragraph context; the native surrounding window is
        // also the maximum paragraph length we can truthfully provide.
        let paragraph = (snapshot.text.string as NSString).paragraphRange(for: local)
        actualRange?.pointee = snapshot.documentRange(paragraph)
        return snapshot.text.attributedSubstring(from: paragraph)
    }

    override func setAnnotations(_ annotations: [NSAttributedString.Key: String], range: NSRange) {
        guard let snapshot = nativeTextCheckingSnapshot, let local = snapshot.localRange(range) else { return }
        snapshot.text.setAttributes(annotations, range: local)
    }

    override func addAnnotations(_ annotations: [NSAttributedString.Key: String], range: NSRange) {
        guard let snapshot = nativeTextCheckingSnapshot, let local = snapshot.localRange(range) else { return }
        snapshot.text.addAttributes(annotations, range: local)
    }

    override func removeAnnotation(_ name: NSAttributedString.Key, range: NSRange) {
        guard let snapshot = nativeTextCheckingSnapshot, let local = snapshot.localRange(range) else { return }
        snapshot.text.removeAttribute(name, range: local)
    }

    override func replaceCharacters(in range: NSRange, withAnnotatedString text: NSAttributedString) {
        guard nativeInputEligible, let snapshot = nativeTextCheckingSnapshot,
              let replacement = snapshot.mutationRange(range) else { return }
        // The existing native-edit route validates focus/lifetime and retains
        // AppKit's replacement range. Never turn a checking result into keys.
        insertText(text, replacementRange: replacement)
    }

    override func selectAndShow(_ range: NSRange) {
        guard nativeInputEligible, let snapshot = nativeTextCheckingSnapshot,
              let selection = snapshot.mutationRange(range) else { return }
        input("textSelection", ChromiumNativeTextInput.replacementFields(selection))
    }

    override func view(for range: NSRange, firstRect: NSRectPointer?, actualRange: NSRangePointer?) -> NSView? {
        guard nativeInputEligible, let snapshot = nativeTextCheckingSnapshot,
              let local = snapshot.localRange(range), let window else { return nil }
        let available = snapshot.documentRange(local)
        let screen = nativeFirstRect(available)
        guard !screen.isEmpty else { return nil }
        firstRect?.pointee = convert(window.convertFromScreen(screen), from: nil)
        actualRange?.pointee = available
        return self
    }

}
