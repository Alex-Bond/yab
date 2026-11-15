import AppKit

// An agent's keys, read once and sent one of two ways. A web view in a
// window takes them as real key events (AgentPage.press). A tab of yours
// in the background has no window: its view is out of the window until you
// pick it, and key events handed to it went nowhere, so the page is told in
// script instead, in the agent's world, what a keyboard would have told it:
// keydown, keypress, the words in (through the editing commands, so the
// page hears beforeinput and input as it would from a hand), keyup; Tab
// moves the focus, Space and Enter on a button or link press it, and Enter
// in a form's field sends the form the way the browser's own implicit
// submission does, through its default button. Whether a Send-like key may
// go at all is decided before either way (AgentBench's `weighed`), from the
// focused element, the same for both, before each Enter or Space, once
// the keys before it have landed: Tab Tab Enter is weighed where the two
// Tabs left the focus, not where it was before them.

extension AgentPage {
    typealias Stroke = PageKey

    /// The named keys: Mac key code, characters, DOM key, code, keyCode,
    /// and what each types.
    nonisolated private static let names: [String: (UInt16, String, String, String, Int, String)] = [
        "enter": (36, "\r", "Enter", "Enter", 13, ""), "return": (36, "\r", "Enter", "Enter", 13, ""),
        "tab": (48, "\t", "Tab", "Tab", 9, ""),
        "escape": (53, "\u{1b}", "Escape", "Escape", 27, ""), "esc": (53, "\u{1b}", "Escape", "Escape", 27, ""),
        "backspace": (51, "\u{7f}", "Backspace", "Backspace", 8, ""),
        "delete": (117, fn(NSDeleteFunctionKey), "Delete", "Delete", 46, ""),
        "space": (49, " ", " ", "Space", 32, " "),
        "arrowup": (126, fn(NSUpArrowFunctionKey), "ArrowUp", "ArrowUp", 38, ""),
        "arrowdown": (125, fn(NSDownArrowFunctionKey), "ArrowDown", "ArrowDown", 40, ""),
        "arrowleft": (123, fn(NSLeftArrowFunctionKey), "ArrowLeft", "ArrowLeft", 37, ""),
        "arrowright": (124, fn(NSRightArrowFunctionKey), "ArrowRight", "ArrowRight", 39, ""),
        "pageup": (116, fn(NSPageUpFunctionKey), "PageUp", "PageUp", 33, ""),
        "pagedown": (121, fn(NSPageDownFunctionKey), "PageDown", "PageDown", 34, ""),
        "home": (115, fn(NSHomeFunctionKey), "Home", "Home", 36, ""),
        "end": (119, fn(NSEndFunctionKey), "End", "End", 35, ""),
    ]

    nonisolated private static func fn(_ key: Int) -> String { String(UnicodeScalar(key)!) }

    /// "Enter", "Meta+a", "ArrowDown ArrowDown Enter", or words to type key
    /// by key, read into strokes; or what could not be read.
    nonisolated static func strokes(_ keys: String) -> Result<[Stroke], KeyTrouble> {
        var all: [Stroke] = []
        for chord in keys.split(separator: " ", omittingEmptySubsequences: true) {
            var parts = chord.split(separator: "+").map(String.init)
            // "+" alone, or ending a chord, is the plus key.
            if chord.hasSuffix("++") || chord == "+" { parts = parts.filter { !$0.isEmpty } + ["+"] }
            guard let last = parts.popLast() else { continue }
            var command = false, shift = false, option = false, control = false
            for word in parts {
                switch word.lowercased() {
                case "meta", "cmd", "command": command = true
                case "shift": shift = true
                case "alt", "option": option = true
                case "control", "ctrl": control = true
                default: return .failure(KeyTrouble("unknown modifier \(word)"))
                }
            }
            func stroke(_ code: UInt16, _ characters: String, _ key: String, _ domCode: String, _ keyCode: Int, _ text: String) -> Stroke {
                Stroke(command: command, shift: shift, option: option, control: control, code: code, characters: characters,
                       key: key, domCode: domCode, keyCode: keyCode, text: command || control ? "" : text)
            }
            if let n = names[last.lowercased()] {
                all.append(stroke(n.0, n.1, n.2, n.3, n.4, n.5))
            } else if last.count == 1 || parts.isEmpty {
                for character in last {
                    let plain = String(character)
                    let key = shift ? plain.uppercased() : plain
                    let upper = plain.uppercased()
                    let letter = upper.count == 1 && upper.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
                    let digit = plain.count == 1 && plain.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
                    let domCode = letter ? "Key\(upper)" : digit ? "Digit\(plain)" : ""
                    let keyCode = letter || digit ? Int(upper.unicodeScalars.first!.value) : 0
                    all.append(stroke(Bench.keyCode(for: character), plain, key, domCode, keyCode, key))
                }
            } else {
                return .failure(KeyTrouble("unknown key \(last)"))
            }
        }
        return .success(all)
    }

    struct KeyTrouble: Error, Equatable {
        let said: String
        init(_ said: String) { self.said = said }
    }

    /// Where a press of keys stopped for the person's yes, by tab: the
    /// same keys asked again go on from there, the keys before it not sent
    /// twice (Tab Tab Enter would move on past the button asked about).
    static var keysLeft: [ObjectIdentifier: (session: String, keys: String, at: Int)] = [:]

    /// How many keys have come up in the page so far, counted in the
    /// agent's world, for a web view in a window, whose real key events
    /// reach the page one after another, behind any script sent between.
    static func keysSeen(_ web: any PageHandle, _ done: @escaping @MainActor (Int) -> Void) {
        guard web.engine == .chromium || web.window != nil else { done(0); return }
        let count = "(() => { const all = globalThis; if (!all.__yabKeyups) { all.__yabKeyups = { n: 0 }; addEventListener('keyup', () => all.__yabKeyups.n++, true); } return all.__yabKeyups.n; })()"
        web.run(count, in: .agent) { result in
            MainActor.assumeIsolated { done((try? result.get()) as? Int ?? 0) }
        }
    }

    /// Once the page has had `count` keys come up, or 0.6 s has gone (a key
    /// into a frame isn't counted): then what has the focus is where the
    /// keys before left it. At once with no window, where keys are script
    /// and run in order.
    static func keysLanded(_ web: any PageHandle, count: Int, _ done: @escaping @MainActor () -> Void) {
        guard (web.engine == .chromium || web.window != nil), count > 0 else { done(); return }
        let limit = Date().addingTimeInterval(0.6)
        func check() {
            web.run("globalThis.__yabKeyups ? globalThis.__yabKeyups.n : 0", in: .agent) { result in
                MainActor.assumeIsolated {
                    if ((try? result.get()) as? Int ?? 0) >= count || Date() > limit { done() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check() } }
                }
            }
        }
        check()
    }

    /// The strokes told to the page in script, for a web view with no
    /// window. In order, all in one run, so nothing between two keys.
    static func pressInScript(_ web: any PageHandle, _ strokes: [Stroke]) {
        web.call(keysScript, arguments: ["strokes": strokes.map(\.json)], in: .agent) { _ in }
    }

    /// What finds the focused element, tells it a key, and edits it, for
    /// both scripts.
    static let keysHelpers = focusedScript + """
    function fire(el, type, s) {
      const view = el.ownerDocument.defaultView || window;
      const e = new view.KeyboardEvent(type, {
        key: s.key, code: s.code, keyCode: s.keyCode, which: s.keyCode, charCode: type === 'keypress' ? (s.text || s.key).charCodeAt(0) : 0,
        metaKey: s.meta, shiftKey: s.shift, altKey: s.alt, ctrlKey: s.ctrl,
        bubbles: true, cancelable: true, composed: true, view
      });
      return el.dispatchEvent(e);
    }
    function field(el) {
      if (el.tagName === 'TEXTAREA') return 'area';
      if (el.tagName === 'INPUT') return /^(button|submit|reset|checkbox|radio|file|image|range|color|hidden)$/i.test(el.type) ? null : 'line';
      if (el.isContentEditable) return 'rich';
      return null;
    }
    function edit(el, command, value) {
      const doc = el.ownerDocument;
      if (command === 'insertText' && el.isContentEditable) {
        // The keyboard's own textInput first: Draft inserts from it and
        // would otherwise add its copy to execCommand's (AgentPage.act).
        // WebKit inserts from an untaken textInput itself.
        const was = el.textContent;
        const said = doc.createEvent('TextEvent');
        said.initTextEvent('textInput', true, true, doc.defaultView, value);
        el.dispatchEvent(said);
        if (said.defaultPrevented || el.textContent !== was) return;
      }
      let done = false;
      try { done = doc.execCommand(command, false, value); } catch (e) {}
      if (done) return;
      // execCommand refused (an input some pages handle themselves): the
      // value set by hand, and the page told as an input would tell it.
      if (el.value === undefined) return;
      const start = el.selectionStart ?? el.value.length, end = el.selectionEnd ?? start;
      if (command === 'insertText') el.setRangeText(value, start, end, 'end');
      else if (command === 'delete') el.setRangeText('', start === end ? Math.max(0, start - 1) : start, end, 'end');
      else if (command === 'forwardDelete') el.setRangeText('', start, start === end ? end + 1 : end, 'end');
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: command, data: command === 'insertText' ? value : null }));
    }
    function focusables(doc) {
      const q = 'a[href],button,input,select,textarea,[tabindex],[contenteditable=true],[contenteditable=""],summary';
      return [...doc.querySelectorAll(q)].filter(el => !el.disabled && el.tabIndex >= 0 && el.type !== 'hidden'
        && (el.offsetParent !== null || el.getClientRects().length))
        .sort((a, b) => (a.tabIndex || 1e6) - (b.tabIndex || 1e6));
    }
    function pressable(el) {
      return el.closest && el.closest('button,a[href],[role=button],[role=link],[role=menuitem],[role=tab],[role=checkbox],[role=switch],summary,input[type=button],input[type=submit],input[type=reset],input[type=checkbox],input[type=radio]');
    }
    function submit(el) {
      const form = el.form || el.closest('form');
      if (!form) return;
      // The browser's own implicit submission: its default button's click,
      // or the form sent as it stands when it has none.
      const button = [...form.elements].find(b => (b.tagName === 'BUTTON' && (b.type || 'submit') === 'submit') || (b.tagName === 'INPUT' && /^(submit|image)$/i.test(b.type)));
      if (button) { if (!button.disabled) button.click(); return; }
      if (form.requestSubmit) form.requestSubmit(); else form.submit();
    }

    """

    /// Words into what has focus in one insertion, as an input method puts
    /// them, for a web view with no window.
    static func insertInScript(_ web: any PageHandle, _ text: String) {
        web.call(insertScript, arguments: ["text": text], in: .agent) { _ in }
    }

    static let insertScript = keysHelpers + """
    const el = focused();
    if (field(el)) edit(el, 'insertText', text);
    return true;
    """

    /// What a keyboard would do on the page, for each stroke, on whatever
    /// has focus, into open shadow roots and frames of the same site.
    static let keysScript = keysHelpers + """
    for (const s of strokes) {
      const el = focused();
      const go = fire(el, 'keydown', s);
      let typed = false;
      if (go && s.text && !s.meta && !s.ctrl) {
        if (fire(el, 'keypress', s) && field(el)) { edit(el, 'insertText', s.text); typed = true; }
      }
      if (go && !typed) {
        const kind = field(el);
        const plain = !s.meta && !s.ctrl && !s.alt;
        if (s.key === 'Enter') {
          if (kind === 'line') { if (plain || s.meta) submit(el); }
          else if (kind === 'area') { if (plain || s.shift) edit(el, 'insertText', '\\n'); else if (s.meta || s.ctrl) submit(el); }
          else if (kind === 'rich') { if (plain) edit(el, s.shift ? 'insertLineBreak' : 'insertParagraph'); }
          else if (plain) { const p = pressable(el); if (p) p.click(); }
        } else if (s.key === 'Backspace' && kind) {
          edit(el, s.alt ? 'deleteWordBackward' : 'delete');
        } else if (s.key === 'Delete' && kind) {
          edit(el, 'forwardDelete');
        } else if (s.key === 'Tab' && plain) {
          const all = focusables(el.ownerDocument);
          if (all.length) {
            const at = all.indexOf(el);
            const next = all[(at < 0 ? (s.shift ? all.length - 1 : 0) : at + (s.shift ? -1 : 1) + all.length) % all.length];
            next.focus();
          }
        } else if (s.meta && s.key.toLowerCase() === 'a' && kind) {
          el.ownerDocument.execCommand('selectAll');
        }
      }
      const up = fire(focused(), 'keyup', s);
      // Space lets a button go on its way up, as a keyboard's does.
      if (go && up && s.key === ' ' && !typed) { const p = pressable(el); if (p) p.click(); }
    }
    return true;
    """
}
