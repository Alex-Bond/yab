import SwiftUI

/// The same block and inline treatment used by the Mac's Cmd+J transcript.
/// Words are rendered locally. Markdown never executes HTML or remote content.
enum ChatMarkdown {
    enum Block: Equatable {
        case heading(String), words(String), item(String, mark: String), code(String), table([[String]])
    }

    static func blocks(_ source: String, streaming: Bool = false) -> [Block] {
        let text = source.replacingOccurrences(of: "<b>", with: "**")
            .replacingOccurrences(of: "</b>", with: "**")
            .replacingOccurrences(of: "<strong>", with: "**")
            .replacingOccurrences(of: "</strong>", with: "**")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
        var result: [Block] = [], words: [String] = [], table: [[String]] = []
        var code: [String]?, fence: String?, ruled = false
        var lines = text.components(separatedBy: "\n")
        if streaming, lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("|") == true { lines.removeLast() }
        func endTable() {
            if !table.isEmpty, ruled || !streaming { result.append(.table(table)) }
            table = []; ruled = false
        }
        func flush() {
            if !words.isEmpty { result.append(.words(words.joined(separator: "\n"))); words = [] }
            endTable()
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if line.hasPrefix(marker) {
                    result.append(.code((code ?? []).joined(separator: "\n")))
                    code = nil; fence = nil
                } else { code?.append(raw) }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush(); fence = String(line.prefix(3)); code = []; continue
            }
            if line.hasPrefix("|") {
                if !words.isEmpty { result.append(.words(words.joined(separator: "\n"))); words = [] }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { ruled = true; continue }
                table.append(cells); continue
            }
            endTable()
            if line.isEmpty { flush(); continue }
            if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); result.append(.heading(String(line[heading.upperBound...])))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); result.append(.item(String(line.dropFirst(2)), mark: "•"))
            } else if let number = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flush(); result.append(.item(String(line[number.upperBound...]), mark: String(line[number]).trimmingCharacters(in: .whitespaces)))
            } else { words.append(line) }
        }
        if let code { result.append(.code(code.joined(separator: "\n"))) }
        flush()
        if streaming, let last = result.popLast() {
            switch last {
            case let .heading(text): result.append(.heading(settled(text)))
            case let .words(text): result.append(.words(settled(text)))
            case let .item(text, mark): result.append(.item(settled(text), mark: mark))
            default: result.append(last)
            }
        }
        return result
    }

    /// Incomplete inline marks wait for their closing bytes while streaming.
    static func settled(_ words: String) -> String {
        var text = words
        if text.components(separatedBy: "**").count % 2 == 0, let open = text.range(of: "**", options: .backwards) {
            text = String(text[..<open.lowerBound])
        }
        if let open = text.range(of: "[", options: .backwards) {
            let rest = text[open.upperBound...]
            let closed = rest.range(of: "](").map { rest[$0.upperBound...].contains(")") } ?? false
            if !closed, !(rest.contains("]") && !rest.contains("](")) { text = String(text[..<open.lowerBound]) }
        }
        return text
    }

    static func inline(_ text: String) -> AttributedString {
        var rich = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Only ordinary website links are actionable. A reply cannot run a
        // custom URL command, open a file or cross into another application.
        for run in rich.runs {
            if let url = run.link, !["https", "http"].contains(url.scheme?.lowercased() ?? "") { rich[run.range].link = nil }
        }
        return rich
    }

    /// A native link retains the conversation that actually rendered it.
    /// A delayed callback cannot borrow the next chat's privacy context.
    @MainActor
    static func open(_ url: URL, from id: Chat.ID, app: AppModel) -> OpenURLAction.Result {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host,
              ChatNativeMenu.isCurrentConversation(id, app: app) else { return .discarded }
        _ = host
        return openInNewTab(url, from: id, app: app) ? .handled : .discarded
    }

    /// A web address said in or done by chat `id` as a new tab in front, the
    /// sheet put away: a link in an answer, a site or link in Chat Info. A
    /// private chat's opens only inside unlocked Private.
    @MainActor
    static func openInNewTab(_ url: URL, from id: Chat.ID, app: AppModel) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host,
              app.chats.chat(id) != nil, app.chats.isVisible(id), !app.privateContentBlocked else { return false }
        let privateOrigin = app.chats.isPrivate(id)
        guard !privateOrigin || (app.browser.space.isPrivate && app.privateLock.mayReveal) else { return false }
        let tab = Tab(id: UUID().uuidString, title: host, site: host, icon: host,
                      url: url.absoluteString, isPrivate: privateOrigin || app.browser.space.isPrivate)
        if app.chatSheet.info { app.closeChatInfo() }
        app.closeSheet()
        app.browser.open(tab)
        return true
    }

    /// The blocks as messages (the Mac's ChatWords.parts): a heading or a
    /// paragraph each its own, a list together with the short line that
    /// leads into it; a table or code each on its own, out of any bubble.
    static func parts(_ blocks: [Block]) -> [[Int]] {
        var out: [[Int]] = []
        for (index, block) in blocks.enumerated() {
            if case .item = block, let last = out.last?.last, said(blocks[last]) {
                switch blocks[last] {
                case .item:
                    out[out.count - 1].append(index)
                    continue
                case let .words(words) where words.count < leadIn && out[out.count - 1].count == 1:
                    out[out.count - 1].append(index)
                    continue
                default: break
                }
            }
            out.append([index])
        }
        return out
    }

    /// A line this short before a list leads into it, in its bubble.
    static let leadIn = 60

    /// A block said as a message, not one standing between them.
    static func said(_ block: Block) -> Bool {
        switch block {
        case .table, .code: false
        default: true
        }
    }

    static func plain(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case let .heading(text), let .words(text), let .item(text, _): String(inline(text).characters)
            case let .code(text): text
            case let .table(rows): rows.map { $0.map { String(inline($0).characters) }.joined(separator: " · ") }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }
}

struct ChatMarkdownView: View {
    @Environment(AppModel.self) private var app
    let text: String
    let chat: Chat.ID
    var streaming = false
    var bubbles = false
    var fresh = false
    /// Its last bubble has the tail: not when its next message is the agent's too.
    var tail = true
    var body: some View {
        // Held, a chat's answer lifts with its menu (MessageHold), whose
        // Select Text picks a part; the system's whole-text selection would
        // take the same hold.
        ChatMarkdownContent(text: text, streaming: streaming, selectable: false, bubbles: bubbles, tail: tail, fresh: fresh)
            .environment(\.openURL, OpenURLAction { url in
                ChatMarkdown.open(url, from: chat, app: app)
            })
    }
}

/// Intrinsic transcript rendering shared by real chats and checked task results.
/// The caller supplies its own captured link authority, never a fabricated Chat.
struct ChatMarkdownContent: View {
    let text: String
    var streaming = false
    var selectable = true
    /// Said in a chat: each paragraph a message of its own, as Messages
    /// shows them, its last with the tail.
    var bubbles = false
    var tail = true
    /// Still being written: the last block's newest words soak in (FreshWords).
    var fresh = false
    /// Messages' 17 at every system text size, as the question bubbles.
    private let size = Metrics.Chat.text

    private typealias C = Metrics.Chat

    var body: some View {
        let blocks = ChatMarkdown.blocks(text, streaming: streaming)
        Group {
            if bubbles {
                bubbled(blocks)
            } else {
                VStack(alignment: .leading, spacing: C.answerBlockGap) {
                    ForEach(blocks.indices, id: \.self) { index in
                        block(blocks[index], fresh: fresh && index == blocks.count - 1)
                    }
                }
            }
        }
        .font(.system(size: size))
        .foregroundStyle(Ink.primary)
        .modifier(Selectable(on: selectable))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct Selectable: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.textSelection(.enabled) } else { content }
        }
    }

    /// Each part a gray bubble of its own, 2 apart, hugging its words with
    /// 40 left beside it; only the last of a run has the tail, the others
    /// keep its room. A table or code stands between them on the bubbles'
    /// body (the Mac's ChatWords in the column).
    private func bubbled(_ blocks: [ChatMarkdown.Block]) -> some View {
        let parts = ChatMarkdown.parts(blocks)
        return VStack(alignment: .leading, spacing: C.answerBubbleGap) {
            ForEach(parts.indices, id: \.self) { part in
                let indices = parts[part]
                let content = VStack(alignment: .leading, spacing: C.answerBlockGap) {
                    ForEach(indices, id: \.self) { index in
                        block(blocks[index], fresh: fresh && index == blocks.count - 1)
                    }
                }
                if ChatMarkdown.said(blocks[indices[0]]) {
                    let tail = part == parts.count - 1 ? self.tail : !ChatMarkdown.said(blocks[parts[part + 1][0]])
                    HStack(spacing: 0) {
                        content
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(C.bubblePadding)
                            .padding(.leading, C.tailRoom)
                            .background(MessageBubble(mine: false, tail: tail).fill(ChatInk.agentBubble))
                        Spacer(minLength: C.answerRoom)
                    }
                } else {
                    content
                        .padding(.top, C.answerAsideGap)
                        .padding(.bottom, part == parts.count - 1 ? 0 : C.answerAsideGap)
                        .padding(.horizontal, C.tailRoom)
                }
            }
        }
    }

    /// Inline words; the ones still being written soak in as they come.
    @ViewBuilder
    private func words(_ text: String, fresh: Bool) -> some View {
        if fresh { FreshWords(rich: ChatMarkdown.inline(text)) } else { Text(ChatMarkdown.inline(text)) }
    }

    @ViewBuilder
    private func block(_ block: ChatMarkdown.Block, fresh: Bool = false) -> some View {
        switch block {
        case let .heading(text):
            words(text, fresh: fresh).font(.system(size: size, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        case let .words(text):
            words(text, fresh: fresh).lineSpacing(1.5)
        case let .item(text, mark):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mark).foregroundStyle(Ink.secondary).accessibilityHidden(true)
                words(text, fresh: fresh).lineSpacing(1.5)
            }
        case let .code(text):
            ScrollView(.horizontal) {
                Text(text).font(.system(size: size - 1.5, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false).padding(C.codePadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatInk.agentCode, in: RoundedRectangle(cornerRadius: C.codeRadius, style: .continuous))
            .accessibilityIdentifier("chat.code")
        case let .table(rows):
            table(rows)
        }
    }

    @ViewBuilder
    private func table(_ rows: [[String]]) -> some View {
        let head = rows.first ?? []
        if head.count <= 3 { grid(rows) } else { cards(rows) }
    }

    /// Up to three columns: a grid, its head one tinted band, rows ruled,
    /// numbers to the right, in one rounded frame (the Mac's ChatTable).
    private func grid(_ rows: [[String]]) -> some View {
        let head = rows.first ?? []
        let body = Array(rows.dropFirst())
        let numbers = head.indices.map { column in
            !body.isEmpty && body.allSatisfy { column < $0.count && TableCards.numeric($0[column]) }
        }
        let shape = RoundedRectangle(cornerRadius: C.codeRadius, style: .continuous)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(head.indices, id: \.self) { column in
                    Text(ChatMarkdown.inline(head[column]))
                        .font(.system(size: size - 4, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: numbers[column] ? .trailing : .leading)
                        .background(ChatInk.fill(0.05))
                        .gridColumnAlignment(numbers[column] ? .trailing : .leading)
                }
            }
            ForEach(body.indices, id: \.self) { row in
                Rectangle().fill(ChatInk.fill(0.1)).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .firstTextBaseline) {
                    ForEach(head.indices, id: \.self) { column in
                        Text(ChatMarkdown.inline(column < body[row].count ? TableCards.bare(body[row][column]) : ""))
                            .font(.system(size: size - 2, weight: column == 0 ? .medium : .regular))
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: numbers[column] ? .trailing : .leading)
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(ChatInk.fill(0.12), lineWidth: 0.5))
        // The table is one element holding its cells, not a name on each cell.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.table")
    }

    /// Four columns and more: each row a card with no labels, as the Mac
    /// reads it (TableCards): a date small over the title, the long cells as
    /// words under it, the short ones in a quiet foot, the source at the
    /// foot's end by its site's mark and name.
    private func cards(_ rows: [[String]]) -> some View {
        let head = rows.first ?? []
        let body = Array(rows.dropFirst())
        let card = TableCards(rows)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(body.indices, id: \.self) { index in
                let row = body[index]
                let kicker = card.cell(row, card.kicker)
                let foot = card.footLine(row, head: head)
                let source = card.cell(row, card.source)
                VStack(alignment: .leading, spacing: 0) {
                    if !kicker.isEmpty {
                        Text(ChatMarkdown.inline(kicker))
                            .font(.system(size: size - 4)).monospacedDigit()
                            .foregroundStyle(Ink.secondary)
                            .padding(.bottom, 3)
                    }
                    Text(ChatMarkdown.inline(card.cell(row, card.title)))
                        .font(.system(size: size - 1, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(card.words.filter { !card.cell(row, $0).isEmpty }, id: \.self) { column in
                        Text(ChatMarkdown.inline(card.cell(row, column)))
                            .font(.system(size: size - 2))
                            .foregroundStyle(Ink.primary.opacity(0.82))
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 5)
                    }
                    if !foot.isEmpty || !source.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ChatMarkdown.inline(foot))
                                .font(.system(size: size - 4))
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if !source.isEmpty {
                                HStack(spacing: 5) {
                                    if let host = TableCards.host(source) {
                                        Favicon(icon: host, host: host, size: 14)
                                    }
                                    Text(ChatMarkdown.inline(TableCards.named(source)))
                                        .font(.system(size: size - 3))
                                        .lineLimit(1)
                                }
                                .fixedSize()
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChatInk.agentBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        // The table is one element holding its cards, not a name on each cell.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.table")
    }
}
