import AppKit
import SwiftUI

// Elements' tree in hand, kept so a redraw costs nothing: the lines shown
// (made once a change of the tree or of what is open, not on every hover
// or every answer of the sidebar), each node by its number with its parent,
// and the keys of Chrome's tree (Treeoutline.ts treeKeyDown, DOMTreeWidget
// onKeyDown) worked out on those lines.

extension DevDOMNode {
    /// Straight from what JSONSerialization made of the inspector's answer:
    /// no second pass through JSONEncoder and JSONDecoder, which on X's
    /// 20,000 nodes cost more than the answer itself.
    init?(json: Any?) {
        guard let d = json as? [String: Any], let id = (d["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        type = (d["type"] as? NSNumber)?.intValue ?? 0
        label = d["label"] as? String ?? ""
        count = (d["count"] as? NSNumber)?.intValue ?? 0
        children = (d["children"] as? [Any] ?? []).compactMap { DevDOMNode(json: $0) }
        name = d["name"] as? String
        attrs = (d["attrs"] as? [[Any]])?.map { $0.map { $0 as? String ?? "" } }
        value = d["value"] as? String
        layout = d["layout"] as? String
    }

    /// A text of nothing but white space, which no line shows: HTML's own
    /// white space only, as Blink's ContainsOnlyWhitespaceOrEmpty; a text of
    /// no-break spaces is shown, as `&nbsp;`.
    var blank: Bool { type == 3 && (value ?? "").unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" } }
}

/// The lines shown and where each one is.
struct DevTreeLines {
    let lines: [DevTreeLine]
    let maxDepth: Int
    /// A line's place by its id ("o12", "c12").
    let place: [String: Int]

    init(_ lines: [DevTreeLine]) {
        self.lines = lines
        var place: [String: Int] = [:]
        place.reserveCapacity(lines.count)
        var deepest = 0
        for (i, line) in lines.enumerated() { place[line.id] = i; deepest = max(deepest, line.depth) }
        self.place = place
        maxDepth = deepest
    }

    func at(_ id: Int, close: Bool) -> Int? { place[(close ? "c" : "o") + String(id)] }
}

/// Every node of the tree in hand by its number, with its parent's.
struct DevTreeIndex {
    private(set) var nodes: [Int: DevDOMNode] = [:]
    private(set) var parent: [Int: Int] = [:]

    init(_ root: DevDOMNode?) {
        guard let root else { return }
        var stack = [root]
        while let node = stack.popLast() {
            nodes[node.id] = node
            for child in node.children { parent[child.id] = node.id; stack.append(child) }
        }
    }

    /// From the document down to the node, both ends in.
    func path(to id: Int) -> [Int] {
        guard nodes[id] != nil else { return [] }
        var out = [id], at = id
        while let up = parent[at] { out.append(up); at = up }
        return out.reversed()
    }
}

/// Chrome's keys on the tree, as moves on the lines shown.
enum DevTreeKeys {
    enum Move: Equatable {
        /// Select the line at this place.
        case select(Int)
        case expand(Int, deep: Bool)
        case collapse(Int, deep: Bool)
        case none
    }

    static func up(_ lines: [DevTreeLine], from: Int?) -> Move {
        guard !lines.isEmpty else { return .none }
        guard let from else { return .select(lines.count - 1) }
        return from > 0 ? .select(from - 1) : .none
    }

    static func down(_ lines: [DevTreeLine], from: Int?) -> Move {
        guard !lines.isEmpty else { return .none }
        guard let from else { return .select(0) }
        return from + 1 < lines.count ? .select(from + 1) : .none
    }

    /// ←: an open node closes (⌥: with everything under it); a closing tag
    /// goes to its opening one; anything else to its parent's line.
    static func left(_ lines: [DevTreeLine], from: Int, open: Set<Int>, option: Bool) -> Move {
        let line = lines[from]
        if line.kind == .open, open.contains(line.node.id) { return .collapse(line.node.id, deep: option) }
        if line.kind == .close {
            if let opening = (0..<from).last(where: { lines[$0].node.id == line.node.id && lines[$0].kind == .open }) { return .select(opening) }
            return .none
        }
        return parentLine(lines, of: from).map { .select($0) } ?? .none
    }

    /// →: a closed node opens (⌥: everything under it); an open one goes to
    /// its first child.
    static func right(_ lines: [DevTreeLine], from: Int, open: Set<Int>, option: Bool) -> Move {
        let line = lines[from]
        guard line.kind != .close, line.arrow else { return .none }
        if line.kind == .whole || !open.contains(line.node.id) { return .expand(line.node.id, deep: option) }
        if option { return .expand(line.node.id, deep: true) }
        let next = from + 1
        return next < lines.count && lines[next].depth == line.depth + 1 ? .select(next) : .none
    }

    /// The line of the node a line is under: the nearest open line above
    /// it one level up.
    static func parentLine(_ lines: [DevTreeLine], of at: Int) -> Int? {
        let depth = lines[at].depth
        guard depth > 0 else { return nil }
        return (0..<at).last { lines[$0].depth == depth - 1 && lines[$0].kind == .open }
    }

    /// The node to select once one is deleted, as Chromium finds it
    /// (findVisibleSibling): the next shown sibling, else the one before,
    /// else the parent.
    static func afterRemoval(_ id: Int, in index: DevTreeIndex) -> Int? {
        guard let up = index.parent[id], let parent = index.nodes[up] else { return nil }
        let shown = parent.children.filter { !$0.blank }
        guard let at = shown.firstIndex(where: { $0.id == id }) else { return parent.type == 9 ? nil : up }
        if at + 1 < shown.count { return shown[at + 1].id }
        if at > 0 { return shown[at - 1].id }
        return parent.type == 9 ? nil : up
    }

    /// Every node under one that has children, itself in: for ⌥← and ⌥→.
    static func subtree(_ id: Int, in index: DevTreeIndex) -> [Int] {
        guard let node = index.nodes[id] else { return [] }
        var out: [Int] = [], stack = [node]
        while let n = stack.popLast() {
            if !n.children.isEmpty || n.count > 0 { out.append(n.id) }
            stack.append(contentsOf: n.children)
        }
        return out
    }
}

extension Browser {
    /// The node drawn on the page (0: none), as Chromium's highlightInOverlay;
    /// kept, so a row pointed at again draws it once (DevElementsPane.hover).
    func elementsHighlight(_ id: Int) {
        workbench?.hoverSent = id
        workCall("elements.highlight", ["id": id])
    }

    /// For the bench: the tree in the window, top-left points.
    func elementsTreeInWindow() -> [Double] {
        guard let model = workbench, let rect = model.treeRect, let content = model.treeView?.window?.contentView else { return [] }
        return [rect.minX, content.bounds.height - rect.maxY, rect.width, rect.height].map { Double($0) }
    }

    /// For the bench: the table drawing the tree (DevTreeTable).
    var elementsTable: DevTreeTableController? {
        ((workbench?.treeView as? NSScrollView)?.documentView as? DevTreeTableView)?.controller
    }

    /// For the bench: the lines either side of the one selected.
    func elementsLinesAround() -> [String] {
        guard let model = workbench else { return [] }
        let tree = model.treeLines
        guard let at = tree.at(model.selectedNode, close: model.selectedClose) else { return [] }
        return tree.lines[max(0, at - 4)..<min(tree.lines.count, at + 5)].map(\.id)
    }

    /// A node opened; `deep`, everything under it loaded and opened too
    /// (⌥ on the triangle or →, Expand Recursively), as Chromium's.
    func elementsExpand(_ id: Int, deep: Bool = false) {
        guard let model = workbench else { return }
        model.expanded.insert(id)
        guard deep else { elementsRefresh(expand: id); return }
        workCall("elements.tree", ["expand": id, "deep": true]) { [weak model] value in
            guard let model else { return }
            model.loadTree(value)
            // In one change, not one a node: each was a redraw of the pane.
            model.expanded.formUnion(DevTreeKeys.subtree(id, in: model.treeIndex))
        }
    }

    /// A node closed; `deep`, everything under it closed too (⌥). Chrome's
    /// Collapse Children leaves the node itself open (`keep`).
    func elementsCollapse(_ id: Int, deep: Bool = false, keep: Bool = false) {
        guard let model = workbench else { return }
        var ids: Set<Int> = deep ? Set(DevTreeKeys.subtree(id, in: model.treeIndex)) : []
        if keep { ids.remove(id) } else { ids.insert(id) }
        guard !model.expanded.isDisjoint(with: ids) else { return }
        model.expanded.subtract(ids)
        // Its closing tag is gone with it: the node's own line selected.
        if model.selectedClose, ids.contains(model.selectedNode) { model.selectedClose = false }
    }

    /// Chrome's keys on the tree, while it has the keyboard: ↑ ↓ through
    /// the lines shown (closing tags too), ← closes or goes up, → opens or
    /// goes in (⌥: everything under it), Home and End, Return edits the
    /// attributes, F2 edits as HTML, Delete removes the node, H hides it,
    /// ⌘↑ ⌘↓ move it among its siblings, ⌘Z and ⇧⌘Z undo and redo.
    func elementsKey(_ event: NSEvent) -> Bool {
        guard let model = workbench, !model.axTreeShown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let tree = model.treeLines
        let at = model.selectedNode == 0 ? nil : tree.at(model.selectedNode, close: model.selectedClose)
        func go(_ move: DevTreeKeys.Move) -> Bool {
            switch move {
            case .select(let place):
                let line = tree.lines[place]
                model.keySelected = true
                elementsSelect(line.node.id, close: line.kind == .close)
                model.elementsKeyReveal += 1
                // Chrome's onSelect: a node selected by hand is shown on the page.
                elementsHighlight(line.node.id)
            case .expand(let id, let deep): elementsExpand(id, deep: deep)
            case .collapse(let id, let deep): elementsCollapse(id, deep: deep)
            case .none: break
            }
            return true
        }
        if flags == [.command] || flags == [.command, .shift] {
            if key == "z" { workCall(flags.contains(.shift) ? "DOM.redo" : "DOM.undo") { [weak self] _ in self?.elementsRefresh(reload: true) }; return true }
            guard flags == [.command], let at, event.keyCode == 126 || event.keyCode == 125 else { return false }
            elementsMove(tree.lines[at].node.id, up: event.keyCode == 126)
            return true
        }
        guard flags.isEmpty || flags == [.option] else { return false }
        let option = flags == [.option]
        switch event.keyCode {
        case 126: return option ? false : go(DevTreeKeys.up(tree.lines, from: at))
        case 125: return option ? false : go(DevTreeKeys.down(tree.lines, from: at))
        case 123: return at.map { go(DevTreeKeys.left(tree.lines, from: $0, open: model.expanded, option: option)) } ?? false
        case 124: return at.map { go(DevTreeKeys.right(tree.lines, from: $0, open: model.expanded, option: option)) } ?? false
        case 115: return go(tree.lines.isEmpty ? .none : .select(0))
        case 119: return go(tree.lines.isEmpty ? .none : .select(tree.lines.count - 1))
        default: break
        }
        guard !option, let at else { return false }
        let node = tree.lines[at].node
        switch event.keyCode {
        case 36, 76:
            if node.type == 1 { model.editNode = node.id; model.editRequest += 1 }
            return true
        case 120:
            model.editNode = node.id; model.htmlRequest += 1
            return true
        case 51, 117:
            elementsRemove(node.id)
            return true
        default:
            guard key == "h", node.type == 1 else { return false }
            workCall("elements.action", ["id": node.id, "action": "hide"]) { [weak self] _ in self?.elementsRefresh() }
            return true
        }
    }

    /// Delete on a node: gone from the page (undoable), the next sibling
    /// selected, else the one before, else the parent, as Chromium's. The
    /// document's own element stays, as Chromium won't remove it.
    func elementsRemove(_ id: Int) {
        guard let model = workbench, let parent = model.treeIndex.parent[id], model.node(parent)?.type != 9 else { return }
        let next = DevTreeKeys.afterRemoval(id, in: model.treeIndex)
        workCall("DOM.markUndoableState")
        workCall("DOM.removeNode", ["nodeId": id]) { [weak self, weak model] _ in
            guard let self, let model else { return }
            self.elementsRefresh(reload: true)
            if let next { model.keySelected = true; self.elementsSelect(next); model.elementsKeyReveal += 1 }
        }
    }

    /// ⌘↑ ⌘↓: the node put before its previous sibling, or after its next.
    func elementsMove(_ id: Int, up: Bool) {
        guard let model = workbench, let parentID = model.treeIndex.parent[id], let parent = model.node(parentID), parent.type != 9 else { return }
        let shown = parent.children.filter { !$0.blank }
        guard let at = shown.firstIndex(where: { $0.id == id }) else { return }
        var params: [String: Any] = ["nodeId": id, "targetNodeId": parentID]
        if up {
            guard at > 0 else { return }
            params["insertBeforeNodeId"] = shown[at - 1].id
        } else {
            guard at + 1 < shown.count else { return }
            if at + 2 < shown.count { params["insertBeforeNodeId"] = shown[at + 2].id }
        }
        workCall("DOM.markUndoableState")
        workCall("DOM.moveTo", params) { [weak self, weak model] value in
            guard let self, let model else { return }
            let moved = (value as? [String: Any])?["nodeId"] as? Int ?? id
            self.elementsRefresh(reload: true)
            model.keySelected = true
            self.elementsSelect(moved)
            model.elementsKeyReveal += 1
        }
    }

    /// The node the picker picked: selected, and the tree takes the keyboard,
    /// as Chromium brings DevTools to the front with the tree focused.
    func elementsPicked(_ id: Int) {
        guard let model = workbench else { return }
        elementsSelect(id)
        guard let rect = model.treeRect, let tree = model.treeView, let window = tree.window else { return }
        DevKeyClaim.pressAt = CGPoint(x: rect.midX, y: rect.midY)
        var host: NSView? = tree
        while let view = host, !(view is DevKeyTarget) { host = view.superview }
        guard let target = host else { return }
        window.makeFirstResponder(target)
    }
}
