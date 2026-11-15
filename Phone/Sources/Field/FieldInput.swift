import SwiftUI
import UIKit

/// An opt-in appearance for the desktop-sized tablet field. Phone inputs keep
/// their body font, blue selection, and caret unless this is supplied.
struct FieldInputStyle {
    let fontSize: CGFloat
    let ink: UIColor
    let selection: UIColor
    let caret: UIColor
    let placeholder: UIColor
}

/// The field's text, a UITextField of our own: SwiftUI's TextField can't
/// select the address on open, can't name the return key after the top row
/// while the keyboard is up, and can't keep the keyboard from rising and
/// falling between surfaces.
struct FieldInput: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    /// The address shows: selected whole, the way ⌘L shows it.
    let selected: Bool
    /// The best row's address after the words, written on in the field
    /// selected ("net" + "flix.com"); nil for none.
    var completion: String? = nil
    let placeholder: String
    var style: FieldInputStyle? = nil
    var compactPlaceholder = "Search…"
    var accessibilityPurpose: String?
    let dark: Bool
    let key: WordRow.Key
    let focusRequest: Int
    let blurRequest: Int
    let typed: (String) -> Void
    /// A finger put the cursor inside the selected address: edit it in place.
    var editAddress: () -> Void = {}
    let submit: () -> Void
    let escape: () -> Void
    /// The tablet's result list owns plain up/down; other inputs keep UIKit's keys.
    var moveSelection: ((Int) -> Void)? = nil
    var allowsEmptySubmit = false
    var fontSizeChanged: (CGFloat) -> Void = { _ in }
    /// The keyboard's top row: New Tab's capsule of spaces, nil elsewhere.
    var accessory: UIView? = nil
    /// Opened without the keyboard (the plate swiped up): a new input waits
    /// for a tap instead of taking the keyboard on its own.
    var waits = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> YabTextField {
        let field = YabTextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.useBodyFont(pointSize: style?.fontSize)
        field.fontSizeChanged = { [weak coordinator = context.coordinator] in
            coordinator?.parent.fontSizeChanged($0)
        }
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        // Safari's address bar keyboard: a "." beside the space bar for
        // addresses, the space bar kept for searches and questions (#317).
        field.keyboardType = .webSearch
        field.textContentType = .URL
        field.enablesReturnKeyAutomatically = !allowsEmptySubmit
        field.clearButtonMode = .never
        field.accessibilityIdentifier = "field.input"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.escape = { context.coordinator.parent.escape() }
        field.moveSelection = moveSelection
        // A deletion, or marked text starting, over the selected address
        // takes all of it first; keys, pastes and dictation do the same
        // through shouldChangeCharactersIn. The address is never half replaced.
        field.willEdit = { [weak coordinator = context.coordinator] field in coordinator?.replaceAddress(in: field) ?? false }
        return field
    }

    func updateUIView(_ field: YabTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.moveSelection = moveSelection
        field.enablesReturnKeyAutomatically = !allowsEmptySubmit
        field.bodyPointSize = style?.fontSize
        // UIKit can resize the font before SwiftUI's text category changes.
        // Keep that native font and let its measured size drive the pill.
        let font = field.font ?? UIFont.preferredFont(forTextStyle: .body, compatibleWith: field.traitCollection)
        let selectedFont = field.attributedText.flatMap {
            $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
        }
        let ink: UIColor = style?.ink ?? (dark ? .white : AppearanceColors.ui(0x000000, 0xF2F2F7))
        if selected {
            // The address, selected the way the prototype draws it: the
            // highlight without handles or a caret, its start in view; the
            // first edit replaces all of it (shouldChangeCharactersIn), a
            // finger inside it edits it in place (textFieldDidChangeSelection).
            if coordinator.address != text || field.text != text
                || selectedFont != font || coordinator.scheme != colorScheme {
                coordinator.address = text
                field.attributedText = NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: ink,
                    .backgroundColor: style?.selection ?? Metrics.Field.selection,
                ])
                if field.isFirstResponder {
                    coordinator.placing {
                        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.beginningOfDocument)
                    }
                }
            }
            field.tintColor = .clear
        } else {
            coordinator.address = nil
            // Words set by the app (cleared, opened with words): not typed growing.
            if coordinator.typedText != text, field.markedTextRange == nil {
                coordinator.typedText = text
                coordinator.growing = false
            }
            // The address's tail: only while the words grow at their end by
            // keys, never over marked text, after ⌫, a paste or dictation.
            let tail: String? = if let completion, !completion.isEmpty, coordinator.growing,
                                   field.isFirstResponder, field.markedTextRange == nil,
                                   coordinator.typedText == text { completion } else { nil }
            if field.markedTextRange == nil,
               field.text != text + (tail ?? "") || coordinator.tail != tail || (tail != nil && selectedFont != font) {
                coordinator.tail = tail
                if let tail {
                    let words = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
                    words.append(NSAttributedString(string: tail, attributes: [
                        .font: font, .foregroundColor: ink,
                        .backgroundColor: style?.selection ?? Metrics.Field.selection,
                    ]))
                    coordinator.placing {
                        field.attributedText = words
                        if let at = field.position(from: field.beginningOfDocument, offset: (text as NSString).length) {
                            field.selectedTextRange = field.textRange(from: at, to: at)
                        }
                    }
                    FieldInput.Coordinator.plainTyping(in: field)
                } else {
                    coordinator.placing {
                        field.attributedText = nil
                        field.text = text
                    }
                }
            }
            if field.textColor != ink, coordinator.tail == nil { field.textColor = ink }
            field.tintColor = style?.caret ?? (dark ? .white : Metrics.Field.caret)
        }
        coordinator.selected = selected
        let hint = style?.placeholder ?? (dark ? UIColor.white.withAlphaComponent(0.55) : Metrics.Field.placeholder)
        field.setHint(placeholder, compact: compactPlaceholder, color: hint,
                      purpose: accessibilityPurpose ?? placeholder)
        // Match the app's appearance, while keeping the prototype's light
        // keyboard for private browsing in the light theme.
        let keyboard: UIKeyboardAppearance = colorScheme == .dark ? .dark : .light
        let keyboardChanged = field.keyboardAppearance != keyboard
        field.keyboardAppearance = keyboard
        let wanted: UIReturnKeyType = switch key {
        case .go: .go
        case .search: .search
        case .send: .send
        }
        if field.returnKeyType != wanted || coordinator.dark != dark || keyboardChanged {
            field.returnKeyType = wanted
            if field.isFirstResponder { field.reloadInputViews() }
        }
        (accessory as? FieldMathKeys)?.field = field
        if field.inputAccessoryView !== accessory {
            field.inputAccessoryView = accessory
            if field.isFirstResponder { field.reloadInputViews() }
        }
        coordinator.dark = dark
        coordinator.scheme = colorScheme
        if coordinator.focus != focusRequest {
            coordinator.focus = focusRequest
            // Next turn: the field is in its window by then.
            DispatchQueue.main.async {
                coordinator.placing {
                    if !field.isFirstResponder { field.becomeFirstResponder() }
                    let at = coordinator.selected ? field.beginningOfDocument : field.endOfDocument
                    field.selectedTextRange = field.textRange(from: at, to: at)
                }
            }
        }
        if coordinator.blur != blurRequest {
            coordinator.blur = blurRequest
            if field.isFirstResponder { field.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: FieldInput
        var focus = 0
        var blur = 0
        var dark = false
        var scheme: ColorScheme?
        var selected = false
        /// The address drawn selected, while it is.
        var address: String?
        /// The best row's address written on after the words, while it shows.
        var tail: String?
        /// The words as last typed, and whether that edit added one
        /// character at their end: only then is an address written on.
        var typedText = ""
        var growing = false
        /// The app is putting the cursor, not a finger.
        private var placingCursor = false

        init(_ parent: FieldInput) {
            self.parent = parent
            // A field made already asked for: the request it was made with
            // counts as asked, so it takes the keyboard once, on its own.
            focus = parent.waits ? parent.focusRequest : parent.focusRequest - 1
            blur = parent.blurRequest
        }

        @objc func changed(_ field: UITextField) {
            if !selected { unhighlight(field) }
            let now = field.text ?? ""
            growing = field.markedTextRange == nil && now.count == typedText.count + 1 && now.hasPrefix(typedText)
            typedText = now
            parent.typed(now)
        }

        /// The address's tail goes, the words stay; true when there was one.
        @discardableResult
        func dropTail(in field: UITextField) -> Bool {
            guard tail != nil else { return false }
            tail = nil
            growing = false
            placing {
                field.attributedText = nil
                field.text = typedText
                field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            }
            Self.plainTyping(in: field)
            return true
        }

        /// The address's tail taken: it is words now, the caret after them.
        private func acceptTail(in field: UITextField) {
            guard let tail else { return }
            let whole = typedText + tail
            self.tail = nil
            growing = false
            typedText = whole
            placing {
                field.attributedText = nil
                field.text = whole
                field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            }
            Self.plainTyping(in: field)
            parent.typed(whole)
        }

        /// Typed words are plain: none keeps the selected address's highlight.
        private func unhighlight(_ field: UITextField) {
            guard field.markedTextRange == nil, let words = field.attributedText, words.length > 0 else { return }
            var lit = false
            words.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: words.length)) { value, _, stop in
                if value != nil { lit = true; stop.pointee = true }
            }
            guard lit else { return }
            let caret = field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.end) }
            let plain = NSMutableAttributedString(attributedString: words)
            plain.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: plain.length))
            placing {
                field.attributedText = plain
                if let caret, let at = field.position(from: field.beginningOfDocument, offset: caret) {
                    field.selectedTextRange = field.textRange(from: at, to: at)
                }
            }
            Self.plainTyping(in: field)
        }

        /// What is typed next carries no highlight, by default or at the caret.
        static func plainTyping(in field: UITextField) {
            if field.defaultTextAttributes[.backgroundColor] != nil {
                var plain = field.defaultTextAttributes
                plain[.backgroundColor] = nil
                field.defaultTextAttributes = plain
            }
            field.typingAttributes?[.backgroundColor] = nil
        }

        func placing(_ body: () -> Void) {
            placingCursor = true
            body()
            placingCursor = false
        }

        /// Over the selected address an edit takes all of it: the field is
        /// emptied, in plain words, and the edit goes on. True when it did,
        /// which a deletion takes as done.
        func replaceAddress(in field: UITextField) -> Bool {
            // ⌫ over a written-on address takes the address alone.
            if !selected { return dropTail(in: field) }
            dropSelection(in: field, keeping: "")
            return true
        }

        /// The selected look goes: plain words, the caret back.
        private func dropSelection(in field: UITextField, keeping text: String? = nil) {
            selected = false
            address = nil
            let text = text ?? field.text ?? ""
            placing {
                field.attributedText = nil
                field.text = text
            }
            // The highlight was the address's own words': UIKit keeps it as
            // what is typed next, so words typed over it came out highlighted.
            Self.plainTyping(in: field)
            field.tintColor = parent.style?.caret ?? (parent.dark ? .white : Metrics.Field.caret)
        }

        /// Over the selected address a key, a paste or dictation takes all of
        /// it: the field is emptied and the system goes on with the edit as
        /// it makes it, marked text too.
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // Over a written-on address the edit goes to the words alone:
            // the tail goes first, and comes back if the words still lead to it.
            if !selected, tail != nil {
                let words = typedText as NSString
                let start = min(range.location, words.length)
                let end = min(range.location + range.length, words.length)
                let next = words.replacingCharacters(in: NSRange(location: start, length: end - start), with: string)
                dropTail(in: field)
                placing {
                    field.text = next
                    if let at = field.position(from: field.beginningOfDocument, offset: start + (string as NSString).length) {
                        field.selectedTextRange = field.textRange(from: at, to: at)
                    }
                }
                changed(field)
                return false
            }
            guard selected else { return true }
            dropSelection(in: field, keeping: "")
            // The edit was at the caret, the address's start: it goes on in the empty field.
            if range.location == 0, range.length == 0 { return true }
            // Anywhere else in words that are gone now: the new words alone.
            placing { field.text = string }
            parent.typed(string)
            return false
        }

        /// A finger put the cursor somewhere in the selected address (a tap,
        /// an arrow key): the address is words to edit there.
        /// The system moving the caret on its own (the keyboard rising, the
        /// field taking focus) leaves the address selected.
        func textFieldDidChangeSelection(_ field: UITextField) {
            // A finger or an arrow key into the written-on address takes it.
            if !selected, tail != nil, !placingCursor, (field as? YabTextField)?.movedByPerson == true,
               let range = field.selectedTextRange,
               field.offset(from: field.beginningOfDocument, to: range.end) != (typedText as NSString).length {
                acceptTail(in: field)
                return
            }
            guard selected, !placingCursor, (field as? YabTextField)?.movedByPerson == true,
                  let range = field.selectedTextRange else { return }
            let start = field.offset(from: field.beginningOfDocument, to: range.start)
            let end = field.offset(from: field.beginningOfDocument, to: range.end)
            // Where the app keeps it while the address shows: at its start.
            guard start != 0 || end != 0 else { return }
            dropSelection(in: field)
            placing {
                if let from = field.position(from: field.beginningOfDocument, offset: start),
                   let to = field.position(from: field.beginningOfDocument, offset: end) {
                    field.selectedTextRange = field.textRange(from: from, to: to)
                }
            }
            parent.editAddress()
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.submit()
            return false
        }
    }
}

/// Escape on a hardware keyboard closes the field, as on the Mac. A
/// deletion or marked text asks first whether the selected address goes; a
/// finger or an arrow key on the field is told from the system moving the caret.
final class YabTextField: UITextField {
    var bodyPointSize: CGFloat? {
        didSet { if bodyPointSize != oldValue { refreshBodyFont() } }
    }
    var escape: (() -> Void)?
    var fontSizeChanged: ((CGFloat) -> Void)? {
        didSet { reportFontSize() }
    }
    private var reportedFontSize: CGFloat?
    private var fontReportQueued = false

    private var fullHint = ""
    private var compactHint = ""
    private var hintColor: UIColor = .placeholderText
    private var appliedHintColor: UIColor?

    /// A single-line hint should fit the person's real font. VoiceOver keeps
    /// the full purpose, including whether only private search is available.
    func setHint(_ full: String, compact: String, color: UIColor, purpose: String) {
        fullHint = full
        compactHint = compact
        hintColor = color
        accessibilityLabel = purpose
        fitHint()
    }

    private func fitHint() {
        guard let font else { return }
        let width = textRect(forBounds: bounds).width
        let hint: String
        if window == nil {
            hint = fullHint
        } else {
            hint = Self.hint(full: fullHint, compact: compactHint, font: font, width: width)
        }
        if attributedPlaceholder?.string != hint || appliedHintColor != hintColor {
            appliedHintColor = hintColor
            attributedPlaceholder = NSAttributedString(string: hint, attributes: [.foregroundColor: hintColor])
        }
    }

    static func hint(full: String, compact: String, font: UIFont, width: CGFloat) -> String {
        guard width.isFinite, width > 0 else { return "" }
        func fits(_ text: String) -> Bool {
            (text as NSString).size(withAttributes: [.font: font]).width <= width
        }
        if fits(full) { return full }
        if fits(compact) { return compact }
        // Very narrow fields can share a row with the Incognito label. Make
        // the visible abbreviation fit while its accessible purpose stays whole.
        var prefix = compact.hasSuffix("…") ? String(compact.dropLast()) : compact
        while !prefix.isEmpty {
            prefix.removeLast()
            let shorter = prefix + "…"
            if fits(shorter) { return shorter }
        }
        return fits("…") ? "…" : ""
    }

    override var font: UIFont? {
        didSet { reportFontSize() }
    }

    func useBodyFont(pointSize: CGFloat? = nil) {
        bodyPointSize = pointSize
        refreshBodyFont()
        adjustsFontForContentSizeCategory = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (field: YabTextField, _: UITraitCollection) in
            field.refreshBodyFont()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { refreshBodyFont() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Automatic UIKit scaling can change the font during layout too.
        reportFontSize()
    }

    private func refreshBodyFont() {
        let preferred = bodyPointSize.map {
            UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: $0), compatibleWith: traitCollection)
        } ?? UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        if font != preferred { font = preferred }
        else { reportFontSize() }
    }

    private func reportFontSize() {
        fitHint()
        guard fontSizeChanged != nil, let size = font?.pointSize, size.isFinite, size > 0,
              size != reportedFontSize, !fontReportQueued else { return }
        fontReportQueued = true
        // Coalesce UIKit changes and avoid mutating SwiftUI state in updateUIView.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fontReportQueued = false
            guard let size = self.font?.pointSize, size.isFinite, size > 0,
                  size != self.reportedFontSize, let report = self.fontSizeChanged else { return }
            self.reportedFontSize = size
            report(size)
        }
    }

    /// Before an edit: true when the selected address was taken away.
    var willEdit: ((UITextField) -> Bool)?
    /// When a finger last came down on the field or an arrow key moved in it.
    private var personAt: Date?

    /// The caret was moved by the person just now, not by the system.
    var movedByPerson: Bool { personAt.map { -$0.timeIntervalSinceNow < 1.5 } ?? false }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))]
        if moveSelection != nil, markedTextRange == nil {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow] {
                let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(moveResult(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands
    }

    var moveSelection: ((Int) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(moveResult(_:)) { return moveSelection != nil && markedTextRange == nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func moveResult(_ command: UIKeyCommand) {
        guard markedTextRange == nil else { return }
        moveSelection?(command.input == UIKeyCommand.inputUpArrow ? -1 : 1)
    }

    @objc private func escapePressed() { escape?() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches { personAt = Date() }
        return hit
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let moving: Set<UIKeyboardHIDUsage> = [.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow,
                                               .keyboardHome, .keyboardEnd]
        if presses.contains(where: { $0.key.map { moving.contains($0.keyCode) } ?? false }) { personAt = Date() }
        super.pressesBegan(presses, with: event)
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if markedTextRange == nil { _ = willEdit?(self) }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    override func deleteBackward() {
        // Deleting the selected address is deleting all of it.
        if willEdit?(self) == true {
            sendActions(for: .editingChanged)
            return
        }
        super.deleteBackward()
    }
}
