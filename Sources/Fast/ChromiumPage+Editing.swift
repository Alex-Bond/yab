import AppKit

extension ChromiumPage {
    /// AppKit offers menu equivalents before keyDown. WebKit consumes its
    /// text commands there; a remote page must do the same before the
    /// Developer Mode menu can claim Control-D in an editable field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self,
           navigationTab?.typing == true, Self.isForwardDeleteKey(event) {
            return takeEditingKey(event)
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isForwardDeleteKey(_ event: NSEvent) -> Bool {
        Hotkey.readings(event).contains { $0.flags == .control && $0.key == "d" }
    }

    /// The hidden CEF window does not own AppKit's Edit menu. Dispatch its
    /// command keys as trusted renderer events, including the editor command.
    func takeEditingKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // AppKit lets Control-D through while a page field has focus. The
        // concealed producer has no active Cocoa text editor to interpret it.
        // Send the same trusted key/editor pair as the native Edit actions.
        if Self.isForwardDeleteKey(event) {
            editingKeyCodes.insert(event.keyCode)
            editFromHand("Control+d")
            return true
        }
        guard let letter = KeyLayout.keyName(for: typed, at: event.keyCode, on: .current)?.lowercased(),
              ["a", "c", "v", "x", "z"].contains(letter),
              flags == .command || (letter == "z" && flags == [.command, .shift]) else { return false }
        editingKeyCodes.insert(event.keyCode)
        editFromHand(flags.contains(.shift) ? "Meta+Shift+z" : "Meta+" + letter)
        return true
    }

    /// AppKit menu actions stop at this page instead of the window's editor.
    private func editFromHand(_ keys: String) {
        guard window != nil, case .success(let strokes) = AgentPage.strokes(keys) else { return }
        lastInput = ProcessInfo.processInfo.systemUptime
        RelayGuard.felt(self)
        AgentFeed.shared.person(self)
        pageCopyTurn &+= 1
        let turn = pageCopyTurn
        sendAgentKeys(strokes)
        // The app's local key monitor runs before the remote selection.
        // Offer the selected page after Chromium acknowledges that input.
        if keys == "Meta+a", NSApp.currentEvent?.type == .keyDown {
            let trace = Store.testing && ProcessInfo.processInfo.environment["YAB_CHROMIUM_COPY_TRACE"] == "1"
            if trace { NSLog("YAB_COPY selectAll event=%ld", Int(NSApp.currentEvent?.type.rawValue ?? 0)) }
            afterAcceptedInput { [weak self] in
                if let self, trace {
                    let tab = self.navigationTab
                    let browser = tab?.delegate as? Browser
                    NSLog("YAB_COPY accepted turn=%d page=%d active=%d key=%d offering=%d typing=%d field=%d",
                          self.pageCopyTurn == turn ? 1 : 0, tab?.builtPage === self ? 1 : 0,
                          browser?.active === tab ? 1 : 0, self.window?.isKeyWindow == true ? 1 : 0,
                          browser?.pageCopy.offering == true ? 1 : 0, tab?.typing == true ? 1 : 0,
                          browser?.fieldShowing == true ? 1 : 0)
                }
                guard let self, self.pageCopyTurn == turn,
                      let tab = self.navigationTab, tab.builtPage === self,
                      let browser = tab.delegate as? Browser, browser.active === tab,
                      self.window?.isKeyWindow == true, !browser.pageCopy.offering else { return }
                browser.offerPageCopy()
            }
        }
    }

    @objc override func selectAll(_ sender: Any?) { editFromHand("Meta+a") }
    @objc func copy(_ sender: Any?) { editFromHand("Meta+c") }
    @objc func cut(_ sender: Any?) { editFromHand("Meta+x") }
    @objc func paste(_ sender: Any?) { editFromHand("Meta+v") }
    @objc func undo(_ sender: Any?) { editFromHand("Meta+z") }
    @objc func redo(_ sender: Any?) { editFromHand("Meta+Shift+z") }
}
