import SwiftUI
import UIKit
import WebKit

/// The phone uses the Mac's parser; the field decides what Return does.
enum FieldAnswerPolicy {
    static func searchesChats(mode: Surfaces.FieldMode?, activeMode: Surfaces.FieldMode?, onChats: Bool, isPrivate: Bool) -> Bool {
        mode != nil && mode == activeMode && onChats && !isPrivate
    }

    @MainActor
    static func takesKey(_ words: String, answer: Calc.Answer?, now: Date = Date()) -> Bool {
        guard let answer, !answer.copy.isEmpty, Words.address(words) == nil else { return false }
        return Calc.time(words, now: now) == nil && Calc.date(words, now: now) == nil
    }

    static func mathKeys(_ words: String) -> Bool {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = words.first, first.isNumber || "(.-−".contains(first) else { return false }
        return !words.contains(where: \.isLetter)
    }

    @MainActor
    static func keepsLocal(_ words: String, rates: Rates? = nil) -> Bool {
        guard Words.address(words) == nil else { return false }
        if Calc.answer(words, rates: rates) != nil { return true }
        let expression = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "sqrt", with: "√").replacingOccurrences(of: "pi", with: "π")
        guard let first = expression.first, first.isNumber || "(.-−√π".contains(first) else { return false }
        return expression.allSatisfy { "0123456789.,+-−*/×÷x^%()√π ".contains($0) }
    }

    @MainActor
    static func reversed(_ answer: Calc.Answer, words: String, rates: Rates = .shared) -> Calc.Answer? {
        let copy: String
        if Calc.units(words) != nil || Calc.base(words) != nil {
            copy = answer.question.replacingOccurrences(of: ",", with: "")
        } else if let (value, _) = Calc.money(amount: answer.question, rates: rates, tickers: true) {
            copy = Calc.shown(value, places: 8).replacingOccurrences(of: ",", with: "")
        } else {
            return nil
        }
        guard !answer.copy.isEmpty else { return nil }
        return Calc.Answer(question: answer.result, questionNote: answer.resultNote,
                           result: answer.question, resultNote: answer.questionNote, copy: copy)
    }
}

@MainActor @Observable
final class FieldAnswers {
    static let shared = FieldAnswers()
    private(set) var rates = 0
    private(set) var copied: (words: String, at: Date)?
    private(set) var swapped: String?
    private(set) var pasteTarget: FieldPasteTarget?

    private init() {
        Rates.shared.came = { [weak self] in self?.rates += 1 }
    }

    func toggle(_ words: String) {
        swapped = swapped == words ? nil : words
        copied = nil
    }

    func clear() { copied = nil; swapped = nil }
    func unmarkCopied() { copied = nil }

    func capturePage(in app: AppModel, mode: Surfaces.FieldMode) {
        pasteTarget = nil
        guard mode == .address, let id = app.browser.tab?.id, let view = app.pages.liveView(id) else { return }
        let target = FieldPasteTarget(tab: id, view: view)
        pasteTarget = target
        target.capture()
    }

    func markCopied(_ words: String) {
        let at = Date()
        copied = (words, at)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            if self?.copied?.at == at { self?.copied = nil }
        }
    }
}

/// A document-local reference to the original editable field. The page's
/// scripts cannot replace this isolated-world bookmark with another input.
@MainActor @Observable
final class FieldPasteTarget {
    let tab: Tab.ID
    private weak var view: WKWebView?
    private let token = UUID().uuidString
    private(set) var ready = false

    init(tab: Tab.ID, view: WKWebView) { self.tab = tab; self.view = view }

    func capture(completion: @escaping (Bool) -> Void = { _ in }) {
        view?.callAsyncJavaScript("""
            const e = document.activeElement;
            const input = e instanceof HTMLTextAreaElement || (e instanceof HTMLInputElement &&
                ['text','search','url','tel'].includes(e.type));
            const editable = e?.isContentEditable;
            globalThis.__yabAnswerTarget = null;
            if (!e || e.matches(':disabled') || e.readOnly || (!input && !editable)) return false;
            const selection = getSelection();
            globalThis.__yabAnswerTarget = {token, e, document, input,
                start: input ? e.selectionStart : null, end: input ? e.selectionEnd : null,
                range: editable && selection?.rangeCount ? selection.getRangeAt(0).cloneRange() : null};
            return true;
            """, arguments: ["token": token], in: nil, in: .defaultClient) { [weak self] result in
                let ready = (try? result.get()) as? Bool == true
                self?.ready = ready
                completion(ready)
            }
    }

    func insert(_ value: String, completion: @escaping (Bool) -> Void) {
        guard ready, let view else { completion(false); return }
        view.callAsyncJavaScript("""
            const t = globalThis.__yabAnswerTarget;
            globalThis.__yabAnswerTarget = null;
            if (!t || t.token !== token || t.document !== document || !t.e.isConnected ||
                t.e.matches(':disabled') || t.e.readOnly || t.e.type === 'password') return false;
            const e = t.e;
            if (t.input) {
                if (!(e instanceof HTMLTextAreaElement) &&
                    !(e instanceof HTMLInputElement && ['text','search','url','tel'].includes(e.type))) return false;
                e.focus();
                e.setRangeText(value, t.start ?? e.value.length, t.end ?? e.value.length, 'end');
                e.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertFromPaste', data:value}));
                return true;
            }
            if (!e.isContentEditable || !t.range || !e.contains(t.range.commonAncestorContainer)) return false;
            e.focus();
            const s = getSelection(); s.removeAllRanges(); s.addRange(t.range);
            return document.execCommand('insertText', false, value);
            """, arguments: ["token": token, "value": value], in: nil, in: .defaultClient) { result in
                completion((try? result.get()) as? Bool == true)
            }
    }
}

extension AppModel {
    var fieldSearchesChats: Bool {
        FieldAnswerPolicy.searchesChats(mode: field.mode, activeMode: NewTabPager.shared.activeFieldMode,
                                      onChats: NewTabPager.shared.onChats, isPrivate: field.place.isPrivate)
    }

    var fieldAnswer: Calc.Answer? {
        guard !fieldSearchesChats, Words.address(field.words) == nil else { return nil }
        _ = FieldAnswers.shared.rates
        guard let answer = Calc.answer(field.words) else { return nil }
        return FieldAnswers.shared.swapped == field.words
            ? FieldAnswerPolicy.reversed(answer, words: field.words) ?? answer : answer
    }

    var fieldAnswerTakesKey: Bool { FieldAnswerPolicy.takesKey(field.words, answer: fieldAnswer) }
    var fieldMathKeys: Bool { !fieldSearchesChats && FieldAnswerPolicy.mathKeys(field.words) }

    func copyFieldAnswer() {
        guard let answer = fieldAnswer, !answer.copy.isEmpty else { return }
        copyFieldResult(answer.copy)
    }

    func copyFieldResult(_ value: String, markAnswer: Bool = true) {
        UIPasteboard.general.string = value
        Haptics.play(.soft, reason: Haptics.Reason.copyAnswer)
        if markAnswer { FieldAnswers.shared.markCopied(field.words) }
        else { FieldAnswers.shared.unmarkCopied() }
    }

    /// The explicit menu action inserts only in the page that was in front
    /// when tapped. WebKit arguments keep the copied value out of JS source.
    func pasteFieldAnswer() {
        guard let answer = fieldAnswer, !answer.copy.isEmpty, field.mode == .address,
              let target = FieldAnswers.shared.pasteTarget, target.ready, browser.tab?.id == target.tab else { return }
        closeFieldAfterChoice()
        target.insert(answer.copy) { [weak self] inserted in
            guard let self, self.browser.tab?.id == target.tab else { return }
            if !inserted {
                self.say("Select a text field on the page first", glyph: .squareBehindSquare1)
            }
        }
    }
}

/// A separate plate above the search rows, as in the selected C prototype.
struct AnswerPlate: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let answer: Calc.Answer
    let words: String
    let lit: Color?
    var dark = false
    let copy: () -> Void
    private typealias C = Metrics.FieldCard
    private typealias A = Metrics.FieldAnswer

    private var canSwap: Bool {
        guard let original = Calc.answer(words) else { return false }
        return FieldAnswerPolicy.reversed(original, words: words) != nil
    }

    var body: some View {
        let copied = FieldAnswers.shared.copied?.words == words
        // The key's capsule is light: the words stay their color on it.
        let white = dark
        ZStack {
            Button(action: copy) {
                HStack(spacing: 0) {
                    side(answer.question, answer.questionNote, white: white)
                    Glyph(.arrowRight, size: A.arrow, color: white ? Color.white.opacity(0.75) : Ink.rowSubtitle)
                        .opacity(canSwap ? 0 : 1).frame(width: A.control)
                    side(answer.result, copied ? "Copied" : answer.resultNote, strong: true, white: white)
                }
                .frame(height: A.height).frame(maxWidth: .infinity)
                .background {
                    if let lit { Capsule(style: .continuous).fill(lit) }
                }
                .padding(C.linesPadding).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(answer.copy.isEmpty)
            .accessibilityLabel("\(answer.question) is \(answer.result)")
            .accessibilityValue(copied ? "Copied" : answer.resultNote)
            .accessibilityHint(answer.copy.isEmpty ? "Waiting for exchange rates" : "Copies \(answer.result)")
            .accessibilityIdentifier("field.answer")
            if canSwap {
                Button { FieldAnswers.shared.toggle(words) } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: A.arrow))
                        .foregroundStyle(white ? Color.white.opacity(0.75) : Ink.rowSubtitle)
                        .frame(width: A.control, height: A.height).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Swap")
                .accessibilityIdentifier("field.answer.swap")
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: C.linesRadius, style: .continuous))
        .environment(\.colorScheme, dark ? .dark : colorScheme)
        .contextMenu {
            Button("Copy Answer", systemImage: "doc.on.doc", action: copy).disabled(answer.copy.isEmpty)
            Button("Copy Question", systemImage: "text.quote") { app.copyFieldResult(answer.question, markAnswer: false) }
            if canSwap { Button("Swap", systemImage: "arrow.left.arrow.right") { FieldAnswers.shared.toggle(words) } }
            if app.field.mode == .address {
                Button("Paste into Page", systemImage: "doc.on.clipboard", action: app.pasteFieldAnswer)
                    .disabled(answer.copy.isEmpty || FieldAnswers.shared.pasteTarget?.ready != true)
            }
            ShareLink(item: answer.copy) { Label("Share", systemImage: "square.and.arrow.up") }.disabled(answer.copy.isEmpty)
        }
    }

    private func side(_ words: String, _ note: String, strong: Bool = false, white: Bool) -> some View {
        VStack(spacing: A.noteGap) {
            Text(words).font(.title2.weight(strong ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(white ? Color.white : Ink.primary).lineLimit(1).minimumScaleFactor(A.minimumScale)
            Text(note.isEmpty ? " " : note).font(.caption)
                .foregroundStyle(white ? Color.white.opacity(0.72) : Ink.rowSubtitle)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, A.sidePadding).frame(maxWidth: .infinity)
    }
}

/// Native accessory keys insert at the actual caret, including a selected
/// range, through the same editing event as an ordinary key.
final class FieldMathKeys: UIInputView {
    weak var field: UITextField?
    static let keys = ["+", "−", "×", "÷", "(", ")", "%"]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Metrics.screen.width, height: Metrics.FieldAnswer.keysHeight), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Metrics.FieldAnswer.keysGap
        row.translatesAutoresizingMaskIntoConstraints = false
        for symbol in Self.keys {
            let button = UIButton(type: .system)
            button.setTitle(symbol, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .title3)
            button.backgroundColor = .tertiarySystemBackground
            button.layer.cornerRadius = Metrics.FieldAnswer.keyRadius
            button.accessibilityIdentifier = "field.math.\(symbol)"
            button.addAction(UIAction { [weak self] _ in self?.insert(symbol) }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.FieldAnswer.keysInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.FieldAnswer.keysInset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.FieldAnswer.keysVertical),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.FieldAnswer.keysVertical),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Metrics.FieldAnswer.keysHeight) }

    func insert(_ symbol: String) {
        guard Self.keys.contains(symbol), let field else { return }
        field.insertText(symbol == "−" ? "-" : symbol)
        field.sendActions(for: .editingChanged)
    }
}
