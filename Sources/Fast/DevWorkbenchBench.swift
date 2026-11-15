import AppKit
import Foundation
import WebKit

extension Browser {
    func workbenchProbe() -> [String: Any] {
        guard let model = workbench else { return [:] }
        let tree = model.root.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        let window = BrowserWindows.shared.window(for: self)
        let editor = (window?.attachedSheet ?? window)?.firstResponder as? NSTextView
        return ["root": tree, "selectedNode": model.selectedNode, "styles": model.styles.map { ["selector": $0.selector, "text": $0.text, "styleId": $0.styleID, "key": $0.id, "origin": $0.origin, "source": $0.source, "line": $0.line,
                                                                                              "inheritedFrom": $0.inheritedFrom, "kind": $0.kind, "editable": $0.editable,
                                                                                              "properties": $0.properties.map { ["name": $0.name, "value": $0.value, "index": $0.index, "disabled": $0.disabled, "overridden": $0.overridden, "dim": $0.dim, "longhands": $0.longhands.map(\.name)] as [String: Any] }] as [String: Any] },
                "computedFrom": model.computedFrom.mapValues { ["value": $0.value, "selector": $0.selector, "origin": $0.origin] }, "listenerRows": model.listenerRows.map { ["id": $0.id, "type": $0.type, "owner": $0.owner, "handler": $0.handler, "url": $0.url] as [String: Any] },
                "ax": model.ax.mapValues { DevWorkbench.string($0) }, "domBreaks": model.domBreaks.map { ["node": $0.node, "type": $0.type, "enabled": $0.enabled] as [String: Any] },
                "layoutBoxes": model.layoutBoxes.map { ["id": $0.id, "kind": $0.kind, "label": $0.label] as [String: Any] }, "overlays": Array(model.overlays),
                "nodeProperties": model.nodeProperties.map { ["name": $0.name, "preview": $0.preview, "type": $0.type] }, "elementsTab": model.elementsTab, "styleCompletions": model.styleCompletions, "colorPanel": NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible, "styleEditing": model.styleEditing, "elementsFind": model.elementsFind, "elementsQuery": model.elementsQuery, "elementsSearched": model.elementsSearched, "elementsCount": model.elementsCount, "elementsMatch": model.elementsMatch,
                "axTree": model.axRoot.map { root in DevAXLine.lines(root).map { ["id": $0.node.id, "role": $0.node.role, "name": $0.node.name, "depth": $0.depth] as [String: Any] } } ?? [], "forced": Array(model.forced), "styleEdits": Array(model.styleEdits.keys),
                "computed": model.computed.map { ["name": $0.name, "value": $0.value] }, "accessibility": model.accessibility.map { ["name": $0.name, "value": $0.value] },
                "sources": model.sources.map { ["id": $0.script, "url": $0.url, "target": $0.target, "kind": $0.kind] },
                "source": model.source?.url ?? "", "sourcesFind": model.sourcesFind, "sourcesQuery": model.sourcesQuery, "sourcesFound": model.sourcesFound, "sourcesSearched": model.sourcesSearched, "sourcesNote": model.sourcesNote, "sourcesLines": model.sourcesResults.reduce(0) { $0 + $1.lines.count }, "elementsMatchNode": model.elementsMatchNode, "elementsWaiting": model.elementsWaiting, "sourceText": model.sourceText, "sourceLine": model.sourceLine, "sourceColumn": model.sourceColumn,
                "prettyText": model.source.flatMap { model.pretty[$0.url]?.text } ?? "",
                "shownLine": model.source.flatMap { model.pretty[$0.url]?.shown(model.sourceLine, column: model.sourceColumn) } ?? model.sourceLine,
                "frames": model.frames.map { ["id": $0.id, "name": $0.name, "line": $0.line, "target": $0.target, "mappedURL": $0.mappedURL, "mappedLine": $0.mappedLine, "scopes": $0.scopes.map { ["name": $0.name, "objectId": $0.objectID] }] as [String: Any] },
                "breakpoints": model.breakpoints.map { ["id": $0.id, "url": $0.url, "line": $0.line, "column": $0.column] as [String: Any] },
                "recording": model.recording, "trace": model.trace.map { ["id": $0.id, "name": $0.name, "duration": $0.duration, "depth": $0.depth] as [String: Any] },
                "memorySamples": model.memorySamples.count, "storage": model.storage.map { ["name": $0.name, "value": $0.value] }, "application": model.applicationInfo,
                "applicationPanel": ["section": model.application.selection.section.rawValue, "category": model.application.selection.category, "database": model.application.selection.database, "expanded": Array(model.application.expanded), "origin": model.application.selection.origin, "frames": model.application.frames, "origins": model.application.origins, "rows": model.application.rows.map { ["id": $0.id, "cells": $0.cells] }, "document": model.application.document, "error": model.application.error, "busy": model.application.busy, "backForward": model.application.backForwardStatus, "events": model.application.events, "recording": model.application.recordingEvents] as [String: Any],
                "applicationEditor": editor.map { ["editable": $0.isEditable, "controlEditable": ($0.delegate as? NSTextField)?.isEditable ?? false, "selection": [$0.selectedRange().location, $0.selectedRange().length], "field": $0.isFieldEditor, "text": $0.string, "delegate": String(describing: Swift.type(of: $0.delegate as AnyObject))] as [String: Any] } ?? [:],
                "applicationGrid": DevApplicationGrid.probe(window),
                "applicationTree": DevApplicationTree.probe(window),
                "heap": model.heap.map { ["name": $0.name, "count": $0.count, "size": $0.size] as [String: Any] },
                "heapSnapshots": model.heapSnapshots.count, "audit": model.audit.map { ["name": $0.name, "value": $0.value] }, "auditReport": model.auditReport, "error": model.error, "busy": model.busy,
                "expanded": Array(model.expanded), "elementsTop": model.elementsTop ?? "", "treeFetches": model.treeFetches, "treeMs": model.treeMs, "restoreMs": model.restoreMs, "connectMs": model.connectMs, "kept": model.keptTree != nil,
                "selectedClose": model.selectedClose, "loadMs": model.loadMs, "linesMs": model.linesMs, "selectMs": model.selectMs,
                "lineCount": model.treeLines.lines.count, "maxDepth": model.treeLines.maxDepth, "treeInWindow": elementsTreeInWindow(),
                "lineAround": elementsLinesAround(), "hoveredNode": model.hoverSent, "pickSerial": model.pickSerial,
                "devPicking": devPicking, "webPicking": active?.webPicking ?? false, "nativePicker": DevPicker.on, "modelPicking": model.picking]
    }
    /// Elements' state without its tree: cheap to ask for in a loop, where
    /// the whole probe's encoding of a 20,000-node tree is itself a second
    /// of main thread.
    func workbenchBrief() -> [String: Any] {
        guard let model = workbench else { return [:] }
        return ["selectedNode": model.selectedNode, "selectedClose": model.selectedClose, "expandedCount": model.expanded.count,
                "expanded": model.expanded.count < 400 ? Array(model.expanded) : [], "rootID": model.root?.id ?? 0,
                "treeFetches": model.treeFetches, "treeMs": model.treeMs, "loadMs": model.loadMs, "linesMs": model.linesMs, "selectMs": model.selectMs,
                "lineCount": model.treeLines.lines.count, "maxDepth": model.treeLines.maxDepth, "lineAround": elementsLinesAround(),
                "treeInWindow": elementsTreeInWindow(), "rowShown": elementsTable?.shown(model.selectedNode, close: model.selectedClose) ?? false,
                "tableRows": elementsTable?.table?.numberOfRows ?? -1, "rows": elementsTable?.rowsOnScreen() ?? [],
                "treeScroll": elementsTable?.scrollOffset ?? [], "attributesEditor": elementsTable?.editorShown ?? false, "elementsTop": model.elementsTop ?? "", "hoveredNode": model.hoverSent, "pickSerial": model.pickSerial,
                "devPicking": devPicking, "webPicking": active?.webPicking ?? false, "nativePicker": DevPicker.on, "modelPicking": model.picking,
                "pickStart": DevPicker.lastStart, "pickerSeen": DevPicker.seen, "pickerMissed": DevPicker.missed, "error": model.error, "kept": model.keptTree != nil]
    }

    func workbenchBench(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard let model = workbench else { answer(["error": "No inspected tab"]); return }
        if request["action"] as? String == "brief" { answer(workbenchBrief()); return }
        if let method = request["method"] as? String {
            var failed = false
            wire(method, request["params"] as? [String: Any] ?? [:], failed: { error in failed = true; answer(["error": error]) }) { value in
                guard !failed else { return }
                guard let value else { answer(["value": NSNull()]); return }
                let decoded = (value as? String).flatMap(DevWorkbench.parse) ?? value
                answer(["value": decoded])
            }
            return
        }
        // What a press at a point of the window reaches, and whether the
        // window could take it: for a probe whose press went nowhere.
        if request["action"] as? String == "hit" {
            guard Store.testing, let window = BrowserWindows.shared.window(for: self), let content = window.contentView,
                  let point = request["point"] as? [Double], point.count == 2 else { answer(["error": "Owned probe and point required"]); return }
            let at = NSPoint(x: point[0], y: content.bounds.height - point[1])
            var chain: [String] = []
            var view = (content.superview ?? content).hitTest(at)
            while let v = view, chain.count < 40 { chain.append(String(describing: Swift.type(of: v))); view = v.superview }
            answer(["chain": chain, "key": window.isKeyWindow, "active": NSApp.isActive,
                    "keyWindow": NSApp.keyWindow.map { "\(Swift.type(of: $0)) \($0.windowNumber)" } ?? "none", "window": window.windowNumber,
                    "sheet": window.attachedSheet.map { "\(Swift.type(of: $0))" } ?? "none", "modal": NSApp.modalWindow.map { "\(Swift.type(of: $0))" } ?? "none"])
            return
        }
        // Exercise the panel's real codecs in owned probes without a modal
        // file picker. Production export/import still uses the native sheets.
        if let transfer = request["transfer"] as? String {
            guard Store.testing else { answer(["error": "Owned probe required"]); return }
            let path = (request["path"] as? String).map { URL(fileURLWithPath: $0) }
            func exported(_ text: String) {
                guard let path else { answer(["text": text]); return }
                do { try text.write(to: path, atomically: true, encoding: .utf8); answer(["bytes": text.utf8.count]) }
                catch { answer(["error": error.localizedDescription]) }
            }
            let imported = transfer.hasSuffix("Import") ? ((request["text"] as? String) ?? path.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) : nil
            switch transfer {
            case "traceExport": exported(DevTraceCodec.export(model))
            case "heapExport": exported(model.heapRaw)
            case "traceImport":
                guard let text = imported,
                      let data = DevWorkbench.parse(text) as? [String: Any],
                      let records = DevTraceCodec.records(data) else {
                    answer(["error": "Invalid trace"]); return
                }
                model.trace = []; model.traceRaw = []; model.appendTrace(records)
                answer(["events": model.trace.count])
            case "heapImport":
                guard let text = imported else { answer(["error": "Missing snapshot"]); return }
                model.loadHeap(text)
                answer(["started": true])
            default: answer(["error": "Unknown transfer"])
            }
            return
        }
        switch request["action"] as? String {
        case "applicationClick":
            guard Store.testing, devPane == .application,
                  let window = BrowserWindows.shared.window(for: self), let content = window.contentView,
                  let point = request["point"] as? [Double], point.count == 2 else { answer(["error": "Owned Application probe and point required"]); return }
            NSApp.activate(ignoringOtherApps: true); window.makeKey()
            let at = NSPoint(x: point[0], y: content.bounds.height - point[1])
            let clicks = request["clicks"] as? Int ?? 1
            // Post the release before AppKit enters a table's mouse tracking loop.
            // Sending mouseDown synchronously would prevent its release being scheduled.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) { NSApp.postEvent(event, atStart: false) }
            }
        case "applicationKey":
            guard Store.testing, devPane == .application,
                  let window = BrowserWindows.shared.window(for: self),
                  let (flags, name, typed) = Bench.chord(request["keys"] as? String ?? ""),
                  name.count <= 1 || KeyLayout.names.contains(name) else { answer(["error": "Owned Application probe and key required"]); return }
            let target = window.attachedSheet ?? window
            if flags.isEmpty, let editor = target.firstResponder as? NSTextView {
                let chars = typed ?? ["⇥": "\t", "↩": "\r", "⌫": "\u{7f}", "space": " "][name] ?? name
                let code = KeyLayout.code(for: name) ?? Bench.keyCode(for: Character(String(name.prefix(1))))
                if !KeyLayout.names.contains(name) {
                    // NSTextInputClient is the native text insertion path, including IME input.
                    editor.insertText(chars, replacementRange: editor.selectedRange())
                } else if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { editor.keyDown(with: event) }
            } else { Bench.send(flags, name, typed, to: target, straight: true) }
        case "applicationSelect":
            guard Store.testing, let title = request["section"] as? String, let section = ApplicationSection(rawValue: title) else { answer(["error": "Owned probe and Application section required"]); return }
            let category = request["category"] as? Bool ?? false
            model.application.select(ApplicationSelection(section: section, category: category, origin: category ? "" : request["origin"] as? String ?? model.application.origins.first?["origin"] as? String ?? "", frame: request["frame"] as? String ?? "", database: request["database"] as? String ?? "", store: request["store"] as? String ?? "", index: request["index"] as? String ?? "", cache: request["cache"] as? String ?? "", resource: request["resource"] as? String ?? ""))
        case "applicationRecording":
            guard Store.testing else { answer(["error": "Owned probe required"]); return }; model.application.recordingEvents = request["on"] as? Bool ?? true
        case "applicationBackForward":
            guard Store.testing else { answer(["error": "Owned probe required"]); return }; model.application.testBackForward()
        case "picker": inspectElement()
        // The pointer on the page in front, as a hand's, at CSS pixels:
        // "hover", "click", "wheel" (dx, dy in points). Owned probes only.
        case "page":
            guard Store.testing, let web = active?.webKitOnly("WebKit inspector picker"), let at = request["at"] as? [Double], at.count == 2 else { answer(["error": "Owned probe and point required"]); return }
            let act = request["act"] as? String ?? "hover"
            // While picking natively the page takes no mouse: the events go
            // through the app, where inspect mode's hands see them (DevPicker).
            if DevPicker.on, act != "wheel", let window = web.window {
                let zoom = web.pageZoom * web.magnification
                let local = NSPoint(x: at[0] * zoom, y: web.isFlipped ? at[1] * zoom : web.bounds.height - at[1] * zoom)
                let point = web.convert(local, to: nil)
                let types: [NSEvent.EventType] = act == "click" ? [.mouseMoved, .leftMouseDown, .leftMouseUp] : [.mouseMoved]
                let flags: NSEvent.ModifierFlags = request["shift"] as? Bool == true ? [.shift] : []
                for type in types {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.sendEvent(event) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(["native": true]) }
                return
            }
            switch act {
            case "click": _ = AgentPage.hover(web, x: at[0], y: at[1]); _ = AgentPage.click(web, x: at[0], y: at[1])
            case "wheel":
                _ = AgentPage.hover(web, x: at[0], y: at[1])
                let zoom = web.pageZoom * web.magnification
                let local = NSPoint(x: at[0] * zoom, y: web.isFlipped ? at[1] * zoom : web.bounds.height - at[1] * zoom)
                let point = web.convert(local, to: nil)
                let dy = Int32(request["dy"] as? Double ?? 0), dx = Int32(request["dx"] as? Double ?? 0)
                if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) {
                    // Without a window an event's point is the screen's, from
                    // the bottom: put where the window's point reads the same.
                    let height = NSScreen.screens.first?.frame.height ?? 0
                    wheel.location = CGPoint(x: point.x, y: height - point.y)
                    if let event = NSEvent(cgEvent: wheel) { web.scrollWheel(with: event) }
                }
            default: _ = AgentPage.hover(web, x: at[0], y: at[1])
            }
        case "elements": elementsRefresh(reload: request["reload"] as? Bool ?? true)
        case "select": elementsSelect(request["id"] as? Int ?? 0)
        case "elementsTab": model.elementsTab = request["tab"] as? String ?? "Styles"
        // Elements as a hand would use it, for owned probes.
        case "elementsFind": model.elementsFind = request["on"] as? Bool ?? true; if let query = request["query"] as? String { model.elementsQuery = query }
        case "elementsStep": elementsStep(request["by"] as? Int ?? 1)
        // The tree scrolled to have a row ("o12") at its top, as a hand's scroll would.
        case "elementsTop": model.elementsTop = request["row"] as? String; model.elementsTopReveal += 1
        case "expand": if let id = request["id"] as? Int { model.expanded.insert(id) }
        // Expand Recursively, as the row's menu does it.
        case "expandAll": if let id = request["id"] as? Int { elementsExpand(id, deep: true) }
        // A hand's press and keys through the app, its monitors seeing them
        // first: a press at window points from the top left
        // ("at"), then "keys" as a chord ("cmd+f") or "text" typed into the
        // field that has the keyboard, "↩" ending it. Owned probes only.
        case "hand":
            guard Store.testing, let window = BrowserWindows.shared.window(for: self), let content = window.contentView else { answer(["error": "Owned probe required"]); return }
            if !window.isKeyWindow { window.makeKey() }
            if request["closeFind"] as? Bool == true { closeFind() }
            if let at = request["at"] as? [Double], at.count == 2 {
                let point = NSPoint(x: at[0], y: content.bounds.height - at[1])
                // "clicks": 2, a double click: the first press and the second.
                let clicks = max(1, request["clicks"] as? Int ?? 1)
                let flags: NSEvent.ModifierFlags = request["option"] as? Bool == true ? [.option] : []
                for (type, count) in (1...clicks).flatMap({ n in [(NSEvent.EventType.leftMouseDown, n), (.leftMouseUp, n)] }) {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1) {
                        // Through the app, its monitors first, straight
                        // away: a press queued in an app that isn't in front
                        // only brings it forward.
                        NSApp.sendEvent(event)
                    }
                }
            }
            if let keys = request["keys"] as? String, let (flags, name, typed) = Bench.chord(keys) {
                Bench.send(flags, name, typed, to: window, queued: true)
            }
            if let text = request["text"] as? String, let editor = window.firstResponder as? NSTextView {
                editor.insertText(text, replacementRange: editor.selectedRange())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let responder = window.firstResponder
                answer(["ok": true, "claim": DevKeyClaim.last, "key": window.isKeyWindow, "active": NSApp.isActive, "responder": responder.map { String(describing: Swift.type(of: $0)) } ?? "", "inCard": DevKeys.contains(responder),
                        "finding": self.finding, "elementsFind": model.elementsFind, "netSearch": self.netPanel.searchOpen, "sourcesFind": model.sourcesFind])
            }
            return
        case "sourcesSearch":
            model.sourcesFind = true; model.sourcesQuery = request["query"] as? String ?? ""; sourcesSearch(model.sourcesQuery)
        case "sourceOpenFound":
            if let file = model.sources.first(where: { $0.url.hasSuffix(request["url"] as? String ?? "\u{0}") }) { sourceOpenFound(file) }
        case "axTree": model.axTreeShown = request["on"] as? Bool ?? true; if model.axTreeShown { elementsAXTree() }
        case "prop":
            guard let style = model.styles.first(where: { $0.id == request["key"] as? String }) else { answer(["error": "No rule"]); return }
            if request["add"] as? Bool == true { elementsAddProperty(style, name: request["name"] as? String ?? "", value: request["value"] as? String ?? "") }
            else if let property = style.properties.first(where: { $0.index == request["index"] as? Int }) {
                if let on = request["enabled"] as? Bool { elementsProperty(style, property, enabled: on) }
                else { elementsProperty(style, property, name: request["name"] as? String, value: request["value"] as? String) }
            }
        case "force": elementsForce(request["state"] as? String ?? "hover")
        case "cls": elementsClass(request["name"] as? String ?? "", on: request["on"] as? Bool ?? true)
        case "addRule": elementsAddRule()
        case "break": elementsBreak(request["id"] as? Int ?? model.selectedNode, request["type"] as? String ?? "subtree-modified", on: request["on"] as? Bool ?? true)
        case "overlay":
            if let box = model.layoutBoxes.first(where: { $0.id == request["id"] as? Int }) { elementsOverlay(box, on: request["on"] as? Bool ?? true) }
        case "listener":
            if let row = model.listenerRows.first(where: { $0.id == request["id"] as? Int }) { elementsListener(row, enabled: request["on"] as? Bool ?? true) }
        case "attributes": workCall("elements.attributes", ["id": request["id"] as? Int ?? model.selectedNode, "text": request["text"] as? String ?? ""]) { [weak self] _ in self?.elementsRefresh() }
        case "sources": sourcesRefresh()
        case "openSource":
            if let url = request["url"] as? String, let file = model.sources.first(where: { $0.url == url }) { sourceOpen(file, line: request["line"] as? Int ?? 0) }
        case "breakpoint":
            // "shown": a line as the editor shows it, pretty printed or not, as the gutter's press.
            if request["shown"] as? Bool == true { sourcesBreakpoint(shown: request["line"] as? Int ?? 0) }
            else { sourcesBreakpoint(request["line"] as? Int ?? 0, condition: request["condition"] as? String ?? "", logpoint: request["logpoint"] as? String ?? "") }
        case "pretty": sourcesPretty()
        case "pickColor":
            // A color chosen in the panel a swatch opened, as a hand's drag
            // over it ends: the panel's action, with the panel as sender.
            guard Store.testing, NSColorPanel.sharedColorPanelExists, let hex = request["hex"] as? String, let color = NSColor(hex: hex) else { answer(["error": "No color panel"]); return }
            let panel = NSColorPanel.shared
            panel.color = color
            DevColorPick.shared.changed(panel)
        case "record": performanceRecord(request["on"] as? Bool ?? true, reload: request["reload"] as? Bool ?? false)
        case "snapshot": memorySnapshot()
        case "audit": auditRun(mode: request["mode"] as? String ?? "Snapshot", mobile: request["mobile"] as? Bool ?? false)
        case "comment": addDevComment(request["text"] as? String ?? "")
        case "recorderImport":
            guard Store.testing, let json = request["json"] as? String else { answer(["error": "Owned probe required"]); return }
            do { try toolsFront?.recorder.importJSON(json) } catch { answer(["error": error.localizedDescription]); return }
        case "storage": applicationStorage(local: request["local"] as? Bool ?? true)
        case "application": applicationInfo()
        case "save":
            // Only an owned probe may inject a workspace; production uses the folder picker.
            if Store.testing, let path = request["workspace"] as? String { model.workspace = URL(fileURLWithPath: path).resolvingSymlinksInPath() }
            if let text = request["text"] as? String { model.sourceText = text }; sourcesSave()
        default: break
        }
        // "quiet": no probe back, whose encoding of a big tree would be in the
        // main thread's passes being timed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(request["quiet"] as? Bool == true ? ["ok": true] : self.workbenchProbe()) }
    }
}
