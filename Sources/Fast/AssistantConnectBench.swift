import AppKit

// Test-only controls for the native D2 flow. Previews don't start agents;
// edits and button presses go through the actual field and AppKit responder.
extension Bench {
    func assistantConnectBench(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "isolated test only"]); return }
        let request = c.request
        let connect = AssistantConnect.shared
        if let reduced = request["reduceMotion"] as? Bool { Store.settings.set(reduced, forKey: "assistants.probe.reduceMotion") }
        if let installed = request["agent"] as? Bool { Store.settings.set(installed, forKey: "assistants.probe.agent") }
        if let state = request["state"] as? String {
            let bot = AssistantBot.allCases.first { $0.client == request["client"] as? String } ?? .dots
            connect.preview(state, bot: bot)
            c.browser.openSettings(.assistants)
            if state == "another" || state == "adding" {
                AssistantConnectIntent.bot = nil
                AssistantConnectIntent.selection = state == "another" ? nil : bot
                SettingsWindow.shared.model?.open(.assistants, item: AssistantPlace.add)
            } else { SettingsWindow.shared.model?.leave(AssistantPlace.add, to: .assistants) }
        }
        guard let window = SettingsWindow.shared.window, let root = window.contentView else { c.answer(["error": "no Settings window"]); return }
        if let size = request["size"] as? [Double], size.count == 2 {
            var frame = window.frame
            frame.origin.y += frame.height - size[1]
            frame.size = NSSize(width: size[0], height: size[1])
            window.setFrame(frame, display: true)
        }
        if let folder = request["film"] as? String {
            let path = URL(fileURLWithPath: folder)
            do { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
            catch { c.answer(["error": error.localizedDescription]); return }
            let start = ProcessInfo.processInfo.systemUptime
            var frames: [[String: Any]] = []
            var began = false
            var returned = false
            let byTyping = request["typing"] as? Bool ?? false
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    if !began && elapsed >= 0.1 { began = true; connect.preview("connecting", bot: .dots) }
                    if !returned && elapsed >= 1.0 {
                        returned = true
                        if byTyping { connect.editCode("K") } else { connect.clear() }
                    }
                    if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                        root.cacheDisplay(in: root.bounds, to: rep)
                        let file = path.appendingPathComponent(String(format: "%03d.png", frames.count))
                        if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: file)) != nil {
                            frames.append(["file": file.lastPathComponent, "ms": Int(elapsed * 1000)])
                        }
                    }
                    if elapsed >= 1.9 {
                        timer.invalidate()
                        if let data = try? JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted]) { try? data.write(to: path.appendingPathComponent("frames.json")) }
                        c.answer(["frames": frames, "typing": byTyping])
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        var rows: [[String: Any]] = []
        var nodes: [any NSAccessibilityProtocol] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: Any) {
            guard let node = object as? any NSAccessibilityProtocol else { return }
            let key = ObjectIdentifier(node as AnyObject)
            guard seen.insert(key).inserted else { return }
            nodes.append(node)
            let frame = node.accessibilityFrame()
            let words = node.accessibilityLabel() ?? node.accessibilityTitle() ?? ""
            if !words.isEmpty || node.accessibilityRole() == .textField {
                rows.append(["label": words, "value": node.accessibilityValue().map { String(describing: $0) } ?? "", "role": node.accessibilityRole()?.rawValue ?? "", "frame": [frame.minX - window.frame.minX, window.frame.maxY - frame.maxY, frame.width, frame.height]])
            }
            for child in node.accessibilityChildren() ?? [] { walk(child) }
        }
        walk(root)
        if let title = request["press"] as? String {
            guard let button = nodes.first(where: { $0.accessibilityRole() == .button && ($0.accessibilityLabel() == title || $0.accessibilityTitle() == title) }) else { c.answer(["error": "no button " + title, "nodes": rows]); return }
            c.answer(["pressed": button.accessibilityPerformPress()])
            return
        }
        if request["return"] as? Bool == true {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                window.sendEvent(event)
            }
        }
        if let text = request["type"] as? String {
            var fields: [NSTextField] = []
            func visit(_ view: NSView) { if let field = view as? NSTextField, field.isEditable { fields.append(field) }; view.subviews.forEach(visit) }
            visit(root)
            guard let field = fields.last else { c.answer(["error": "no input", "nodes": rows]); return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView { editor.insertText(text, replacementRange: editor.selectedRange()) }
            else { c.answer(["error": "no editor"]); return }
        }
        c.answer(["code": connect.code, "running": connect.bot?.client ?? "", "stopped": connect.stopped?.client ?? "", "nodes": rows, "window": window.windowNumber, "size": [window.frame.width, window.frame.height]])
    }
}
