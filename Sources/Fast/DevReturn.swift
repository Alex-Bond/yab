import AppKit
import Foundation

// Developer Tools are the tab's, as Chromium's are: another tab in front puts
// the card away and back with the tab (Browser.devFollows). WebKit keeps one
// page's inspector at a time here (140 MB each), so the one left is closed
// and comes up anew on the way back. Everything the person had in it is
// kept and given back: what was typed at Console's prompt and not run, the
// filters, Console's lines and answers, Network's rows and the one picked,
// Elements' open nodes, selection and scroll, Sources' files and
// breakpoints, :hov and DOM breakpoints, Device Settings.
//
// The new inspector numbers nodes, scripts and requests anew, so what is
// kept by number is found again by place: a node by the child indexes from
// the document down, a script by its address, a request by its method and
// address. A tab whose page changed while it was away (devDocument moved)
// starts fresh, as Chromium's does on a new page.

/// What a tab's inspector held when another tab in front put it away.
struct DevReturn {
    /// The tab's document then (Tab.devDocument): the same one or nothing.
    var document: Int
    /// Device Settings, which WebKit drops with its inspector.
    var overrides: Set<DevOverride>
}

/// What Console's and Network's panels show for one tab: their words and
/// picks. The window has one of each (Browser.consolePanel, netPanel), over
/// the tab in front; each tab keeps its own here while another is in front.
struct DevPanes {
    var consoleFilter = ConsoleFilter()
    var consoleGroup: ConsoleGroup = .all
    var consoleSource: String?
    var consoleHiddenFiles: Set<String> = []
    /// Typed at the prompt and not run.
    var consoleDraft = ""
    var netFilter = NetFilter()
    var netSelected: Int?
    var netDetail: NetDetailTab = .headers
    var netSearchOpen = false
    var netQuery = ""
}

extension Browser {
    /// The panes as they are now, for the tab being left.
    func devPanesNow() -> DevPanes {
        let console = consolePanel, net = netPanel
        return DevPanes(consoleFilter: console.filter, consoleGroup: console.group, consoleSource: console.groupSource,
                        consoleHiddenFiles: console.hiddenFiles, consoleDraft: console.draft,
                        netFilter: net.filter, netSelected: net.selected, netDetail: net.detail,
                        netSearchOpen: net.searchOpen, netQuery: net.query)
    }

    /// A tab's panes in front: as it left them, or as new.
    func devPanesShow(_ panes: DevPanes) {
        let console = consolePanel, net = netPanel
        if console.filter != panes.consoleFilter { console.filter = panes.consoleFilter }
        if console.group != panes.consoleGroup { console.group = panes.consoleGroup }
        if console.groupSource != panes.consoleSource { console.groupSource = panes.consoleSource }
        if console.hiddenFiles != panes.consoleHiddenFiles { console.hiddenFiles = panes.consoleHiddenFiles }
        console.loadDraft(panes.consoleDraft)
        // The new inspector numbers its contexts anew: the page's own.
        console.context = 0
        if net.filter != panes.netFilter { net.filter = panes.netFilter }
        if net.selected != panes.netSelected { net.selected = panes.netSelected }
        if net.detail != panes.netDetail { net.detail = panes.netDetail }
        if net.searchOpen != panes.netSearchOpen { net.searchOpen = panes.netSearchOpen }
        if net.query != panes.netQuery { net.query = panes.netQuery }
    }

    /// The tab left: its panes kept on it, the window's cleared for the
    /// next tab's.
    func devPanesLeave(_ tab: Tab) {
        tab.devPanes = devPanesNow()
        devPanesShow(DevPanes())
    }

    /// The tab in front again: its panes back, if it kept any.
    func devPanesArrive(_ tab: Tab) {
        guard let panes = tab.devPanes else { return }
        tab.devPanes = nil
        devPanesShow(panes)
    }

    /// The inspector up again on the document it was put away on: what the
    /// page lost with the old one given back, and Elements found again.
    func devReturned(_ tab: Tab, _ back: DevReturn) {
        for setting in back.overrides where !tab.devOverrides.contains(setting) { toggleDevOverride(setting) }
        guard let model = workbench else { return }
        // Breakpoints went with the old inspector's debugger.
        let marks = model.breakpoints
        model.breakpoints = []
        for mark in marks {
            workCall("sources.breakpoint", ["url": mark.url, "line": mark.line, "condition": mark.condition, "logpoint": "", "target": mark.target]) { [weak model] value in
                guard let id = (value as? [String: Any])?["breakpointId"] as? String else { return }
                var again = mark
                again.id = id
                model?.breakpoints.append(again)
            }
        }
        // Elements found again now, not only once its pane is shown: the
        // Styles, :hov and DOM breakpoints are on the new numbers at once.
        if model.keptTree != nil { elementsRefresh() }
    }

    /// Elements' pane shown: the tree asked for only when the page has
    /// changed since it was fetched, and the rows at the top as they were.
    func elementsShown() {
        guard let model = workbench else { return }
        // Not up yet: asked for as it comes up (inspectorReady, devReturned).
        if wirePage != nil, model.root == nil || model.keptTree != nil || model.treeRevision != model.domRevision { elementsRefresh() }
        if model.elementsTop != nil { model.elementsTopReveal += 1 }
    }

    /// The tree found again in the new inspector (DevWorkbench.restore):
    /// the selected node's sidebar asked for anew, and what the page lost
    /// with the old inspector (:hov, DOM breakpoints, grid and flex
    /// overlays) given back on the new numbers.
    func elementsReturned() {
        guard let model = workbench else { return }
        let id = model.selectedNode
        if id != 0 {
            if !model.forced.isEmpty {
                workCall("CSS.forcePseudoState", ["nodeId": id, "forcedPseudoClasses": Array(model.forced)]) { [weak self] _ in self?.elementsSelect(id) }
            } else {
                elementsSelect(id)
            }
        } else {
            elementsStart()
        }
        for mark in model.domBreaks where mark.enabled { workCall("DOMDebugger.setDOMBreakpoint", ["nodeId": mark.node, "type": mark.type]) }
        elementsOverlaysRedraw()
        if model.elementsFind, !model.elementsQuery.isEmpty { elementsSearch(model.elementsQuery, keep: true) }
        model.elementsTopReveal += 1
    }
}

// MARK: - Elements by place

extension DevDOMNode {
    /// The child indexes from this node down to each of `ids` found.
    func paths(to ids: Set<Int>) -> [Int: [Int]] {
        var out: [Int: [Int]] = [:]
        var trail: [Int] = []
        func walk(_ node: DevDOMNode) {
            if ids.contains(node.id) { out[node.id] = trail }
            guard out.count < ids.count else { return }
            for (index, child) in node.children.enumerated() {
                trail.append(index)
                walk(child)
                trail.removeLast()
            }
        }
        walk(self)
        return out
    }

    /// WebKit's own path to the node at these child indexes, "1,HTML,1,BODY"
    /// (DOM.pushNodeByPathToFrontend, as its inspector finds the selected
    /// node again after a reload): a child's place among the element's own
    /// children and its node name. Nil through a shadow root, a pseudo
    /// element or a template's content, which it has no words for.
    func webKitPath(_ path: [Int]) -> String? {
        var node = self
        var out: [String] = []
        for index in path {
            guard index < node.children.count else { return nil }
            let child = node.children[index]
            switch child.type {
            // A frame's document, the frame element's only child for WebKit.
            case 9: out.append("0,#document")
            case 1:
                guard !(child.name ?? "").hasPrefix("::"), let name = child.name else { return nil }
                // HTML's elements are named in capitals, SVG's as written.
                out.append("\(index)," + (name == name.lowercased() ? name.uppercased() : name))
            case 3: out.append("\(index),#text")
            case 8: out.append("\(index),#comment")
            case 10: out.append("\(index)," + (child.name ?? "html"))
            default: return nil
            }
            node = child
        }
        return out.joined(separator: ",")
    }

    /// Old node ids to new for the nodes of an old tree found in a new one:
    /// walked side by side, a child matched by its place when it is the
    /// same kind of node, else by the next one of its kind (the page may
    /// have added or taken some while it was away).
    static func matched(_ old: DevDOMNode, _ new: DevDOMNode) -> [Int: Int] {
        var map: [Int: Int] = [:]
        func same(_ a: DevDOMNode, _ b: DevDOMNode) -> Bool { a.type == b.type && a.tag == b.tag }
        func walk(_ a: DevDOMNode, _ b: DevDOMNode) {
            map[a.id] = b.id
            guard !a.children.isEmpty, !b.children.isEmpty else { return }
            var from = 0
            for (index, child) in a.children.enumerated() {
                if index < b.children.count, index >= from, same(child, b.children[index]) {
                    walk(child, b.children[index]); from = index + 1
                } else if let at = b.children[min(from, b.children.count)...].firstIndex(where: { same(child, $0) }) {
                    walk(child, b.children[at]); from = at + 1
                }
            }
        }
        if same(old, new) { walk(old, new) }
        return map
    }
}

extension DevWorkbench {
    /// The paths in the kept tree that the new inspector must have loaded
    /// for the open nodes, the selection and the top row to be found again.
    /// Each as the child indexes ("i"), WebKit's own path to it where there
    /// is one ("p"), and whether its children are wanted too, open ("k").
    func keptPaths(_ kept: DevDOMNode) -> [[String: Any]] {
        var ids = expanded
        if selectedNode != 0 { ids.insert(selectedNode) }
        if let top = elementsTop.flatMap(Self.rowNode) { ids.insert(top) }
        return kept.paths(to: ids).sorted { $0.value.count < $1.value.count }.map { id, path in
            ["i": path, "p": kept.webKitPath(path) ?? NSNull(), "k": expanded.contains(id)]
        }
    }

    /// The node of a tree row's id ("o12", "c12").
    static func rowNode(_ row: String) -> Int? { Int(row.dropFirst()) }

    /// The kept tree's open nodes, selection and top row put on the new
    /// tree's numbers; what is no longer there is let go.
    func restore(from old: DevDOMNode, into new: DevDOMNode) {
        let map = DevDOMNode.matched(old, new)
        expanded = Set(expanded.compactMap { map[$0] })
        selectedNode = map[selectedNode] ?? 0
        if let top = elementsTop, let id = Self.rowNode(top) {
            elementsTop = map[id].map { String(top.prefix(1)) + String($0) }
        }
        domBreaks = domBreaks.compactMap { mark in map[mark.node].map { var m = mark; m.node = $0; return m } }
        overlays = Set(overlays.compactMap { map[$0] })
        layoutBoxes = layoutBoxes.compactMap { box in map[box.id].map { var b = box; b.id = $0; return b } }
        // The find's marks were the old inspector's search.
        elementsSearched = ""; elementsCount = 0; elementsMatch = 0; elementsMatchNode = 0; elementsWaiting = false
        root = new
        if expanded.isEmpty { expanded.insert(new.id); expanded.formUnion(new.children.filter { $0.type == 1 }.map(\.id)) }
    }
}
