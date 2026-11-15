import SwiftUI
import UIKit

// MARK: - opening a project

extension AppModel {
    /// A project out of its circle or its card on the Chats page: its chats
    /// and its field, in a cover of its own (UIKit's zoom, as a chat's).
    func openProject(_ id: ChatProject.ID) {
        guard projects.project(id) != nil else { return }
        Haptics.play(.soft, reason: Haptics.Reason.rowAction)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        field.blur()
        field.rest()
        projects.info = false
        projects.draft = ""
        projects.page = ProjectPresentation(id: UUID(), project: id)
    }

    /// Words from the project's field: a new chat in the project, the
    /// words its first, in its own cover over the project.
    func newChat(inProject id: ChatProject.ID, saying words: String, from source: String = ProjectPage.fieldSource) {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projects.project(id) != nil, canStartInProject else { return }
        projects.draft = ""
        newChat(focus: text.isEmpty, asPage: source, project: id)
        if !text.isEmpty { send(text) }
    }
}

// MARK: - the circle

/// A project's circle: its emoji on its color, as a contact's photo.
struct ProjectCircle: View {
    @Environment(\.colorScheme) private var scheme
    let project: ChatProject
    let size: CGFloat

    var body: some View {
        let (top, bottom) = ProjectCircle.colors(project.tint, dark: scheme == .dark)
        Text(project.emoji.isEmpty ? String(project.name.prefix(1)).uppercased() : project.emoji)
            .font(.system(size: size * 0.5, weight: project.emoji.isEmpty ? .semibold : .regular))
            .foregroundStyle(Ink.primary)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .accessibilityHidden(true)
    }

    /// Each tint's two ends, light and dark (the concept's circles).
    static func colors(_ tint: String, dark: Bool) -> (Color, Color) {
        let light: (UInt32, UInt32), night: (UInt32, UInt32)
        switch tint {
        case "green": light = (0xCDEED6, 0x9FDCB1); night = (0x2E5A3B, 0x1F4A2C)
        case "orange": light = (0xFFD9A8, 0xFFB877); night = (0x6A4320, 0x55331A)
        case "purple": light = (0xE4DCFF, 0xC3B4FF); night = (0x463A70, 0x362B5C)
        case "pink": light = (0xFFD6E5, 0xFFB0CB); night = (0x6A2F45, 0x562437)
        case "yellow": light = (0xFFF0B3, 0xFFE07A); night = (0x5E5220, 0x4A4018)
        case "teal": light = (0xC9F0EE, 0x94DDD9); night = (0x1F5553, 0x174341)
        case "gray": light = (0xE8E8ED, 0xD1D1D6); night = (0x3A3A3C, 0x2C2C2E)
        default: light = (0xC9D8FF, 0x9DB6FF); night = (0x2D3E6E, 0x22305A)
        }
        let pick = dark ? night : light
        return (Color(projectRGB: pick.0), Color(projectRGB: pick.1))
    }
}

private extension Color {
    init(projectRGB rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: - Move to Project

/// Move to Project ›, a submenu in a held chat's menu: the projects with
/// their circles, the chat's own ticked, and out of its project.
struct MoveToProjectMenu: View {
    @Environment(AppModel.self) private var app
    let chat: Chat

    var body: some View {
        if app.canMoveToProject(chat.id) {
            Menu {
                ForEach(app.projects.listed) { project in
                    Button {
                        app.moveChat(chat.id, to: project.id)
                    } label: {
                        Label {
                            Text(project.name)
                        } icon: {
                            Image(uiImage: ProjectMenuIcon.picture(project))
                        }
                    }
                    .disabled(chat.project == project.id)
                }
                if app.project(of: chat) != nil {
                    Divider()
                    Button { app.moveChat(chat.id, to: nil) } label: { Text("Remove from Project") }
                }
            } label: {
                Label {
                    Text("Move to Project")
                } icon: {
                    if let image = UIImage.menuGlyph(GlyphName.folder1.rawValue) { Image(uiImage: image) }
                }
            }
            .accessibilityIdentifier("chat.menu.moveToProject")
        }
    }
}

/// A project's circle for a native menu row: the emoji on its color.
enum ProjectMenuIcon {
    @MainActor
    static func picture(_ project: ChatProject) -> UIImage {
        let side: CGFloat = 24
        let (top, _) = ProjectCircle.colors(project.tint, dark: UITraitCollection.current.userInterfaceStyle == .dark)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor(top).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let words = (project.emoji.isEmpty ? String(project.name.prefix(1)) : project.emoji) as NSString
            let font = UIFont.systemFont(ofSize: 13)
            let size = words.size(withAttributes: [.font: font])
            words.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: [.font: font])
        }.withRenderingMode(.alwaysOriginal)
    }
}

// Projects of chats on the iPhone (PLAN-chat-projects.md, the "iMessage way"
// concept): pinned projects as big circles over the Chats page's cards, the
// others a card among them, a project opened as a group chat (its chats as
// Messages' rows, its field at the foot), its card as a contact's.

private typealias R = Metrics.Chats

// MARK: - pinned, over the cards

/// The pinned projects, three to a row, as Messages' pinned conversations:
/// a circle 72 with the name under it and a dot for something new; over
/// the circle a bubble with its newest answer not read yet, or the typing
/// dots while one of its chats is answering.
struct ProjectPins: View {
    @Environment(AppModel.self) private var app
    let projects: [ChatProject]
    let within: [ChatProject.ID: [Chat]]
    let cards: Namespace.ID

    var body: some View {
        let bubbles = projects.contains { ProjectPins.peek(within[$0.id] ?? [], app: app) != nil }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: 3), spacing: 14) {
            ForEach(projects) { project in
                ProjectPin(project: project, chats: within[project.id] ?? [], cards: cards)
            }
        }
        // Room for the bubbles over the first row's circles.
        .padding(.top, bubbles ? 44 : 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newtab.projects")
    }

    enum Peek: Equatable {
        case typing
        case words(title: String, text: String)
    }

    /// What the bubble over a project's circle says: the dots while one of
    /// its chats answers, else its newest unread answer; nothing otherwise.
    @MainActor
    static func peek(_ chats: [Chat], app: AppModel) -> Peek? {
        if chats.contains(where: \.working) { return .typing }
        guard let chat = chats.first(where: \.unread) else { return nil }
        return .words(title: chat.title, text: ChatWords.preview(chat, app: app))
    }
}

private struct ProjectPin: View {
    @Environment(AppModel.self) private var app
    let project: ChatProject
    let chats: [Chat]
    let cards: Namespace.ID

    var body: some View {
        let unread = chats.contains(where: \.unread)
        Button {
            app.openProject(project.id)
        } label: {
            VStack(spacing: 7) {
                ProjectCircle(project: project, size: 72)
                    .matchedTransitionSource(id: ProjectPage.source(project.id), in: cards) { $0.clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous)) }
                HStack(spacing: 5) {
                    if unread { Circle().fill(Color.accentColor).frame(width: 9, height: 9) }
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if let peek = ProjectPins.peek(chats, app: app) {
                // Standing on the circle's top: its foot 10 into it, a little right of center.
                Color.clear.frame(height: 10)
                    .overlay(alignment: .bottom) {
                        ProjectPeek(peek: peek).fixedSize(horizontal: false, vertical: true)
                    }
                    .offset(x: 12)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button { app.openProject(project.id) } label: { Text("Open Project") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("newtab.project.\(project.id)")
        .accessibilityLabel(project.name)
        .accessibilityValue(unread ? "unread" : "")
    }
}

/// The bubble over a pinned circle: two lines at most, a tail toward it.
private struct ProjectPeek: View {
    let peek: ProjectPins.Peek

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            switch peek {
            case .typing:
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Ink.faint).frame(width: 6, height: 6) }
                }
                .padding(.vertical, 4)
                .fixedSize()
                .accessibilityLabel("Answering")
            case let .words(title, text):
                Text("\(Text(title).fontWeight(.semibold)) \(text)")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 112, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ChatDetails.tile, in: shape)
        .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .background(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(ChatDetails.tile)
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(45))
                .offset(x: 16, y: 4)
        }
        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
        .accessibilityIdentifier("newtab.project.peek")
    }
}

// MARK: - a project's card among the chats

/// A project not pinned, a card among the chats at its newest chat's place,
/// as Messages has a group among the people: its circle, its name, what its
/// newest chat said, when.
struct ProjectPageCard: View {
    @Environment(AppModel.self) private var app
    let project: ChatProject
    let chats: [Chat]
    let cards: Namespace.ID

    var body: some View {
        let card = RoundedRectangle(cornerRadius: Metrics.NewTab.chatCardRadius, style: .continuous)
        let newest = chats.first
        let unread = chats.contains(where: \.unread)
        let working = chats.contains(where: \.working)
        Button {
            app.openProject(project.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ProjectCircle(project: project, size: Metrics.Chats.rowIconBox)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if unread { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                }
                Group {
                    if let newest {
                        Text("\(Text(newest.title).fontWeight(.medium)): \(ChatWords.preview(newest, app: app))")
                    } else {
                        Text("No chats yet")
                    }
                }
                .font(.footnote)
                .foregroundStyle(Ink.rowSubtitle)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(working ? "working" : chats.count == 1 ? "1 chat" : "\(chats.count) chats")
                    .font(.caption)
                    .foregroundStyle(working ? Ink.done : Ink.faint)
            }
            .padding(Metrics.NewTab.chatCardPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.NewTab.chatCardHeight, alignment: .topLeading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: card)
            .matchedTransitionSource(id: ProjectPage.source(project.id), in: cards) { source in
                source.background(Color(uiColor: .secondarySystemGroupedBackground)).clipShape(card)
            }
            .contentShape(card)
        }
        .buttonStyle(.plain)
        .contentShape(.contextMenuPreview, card)
        .contextMenu {
            Button { app.openProject(project.id) } label: { Text("Open Project") }
        }
        .accessibilityIdentifier("newtab.project.\(project.id)")
    }
}

// MARK: - the project

/// A project open, as a group chat in Messages: ‹ and ✎ on glass, its
/// circle and "Name ›" (its card) in the middle, its chats as Messages'
/// rows (swiped: Project, Pin, Archive; held: the chat's menu with Move to
/// Project), and at the foot the field "New chat in ‹Name›": words sent
/// there are a new chat in the project. A chat opens out of its row in its
/// own cover, and goes back into it.
struct ProjectPage: View {
    @Environment(AppModel.self) private var app
    let presentation: ProjectPresentation
    @Namespace private var rows
    @State private var moving: Chat.ID?
    @FocusState private var typing: Bool

    static func source(_ id: ChatProject.ID) -> String { "project." + id }
    /// The field's own source: a chat begun there zooms out of it.
    static let fieldSource = "project.field"
    static let headSource = "project.head"

    var body: some View {
        Group {
            if let project = app.projects.project(presentation.project) {
                content(project)
            } else {
                Color.clear
            }
        }
        .background(ChatInk.list.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.page")
        // Its chats in their covers, out of their rows.
        .fullScreenCover(item: ChatPagePresentation.binding(app: app, project: presentation.project)) { page in
            ChatPageCover(presentation: page)
                .environment(app)
                .navigationTransition(.zoom(sourceID: page.source, in: rows))
        }
        .fullScreenCover(isPresented: Binding(get: { app.projects.info && app.projects.page == presentation },
                                              set: { if !$0 { app.projects.info = false } })) {
            ProjectCard(project: presentation.project) {
                // New Chat on the card: back to the project, its field ready.
                app.projects.info = false
                DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.disabled ? 0 : 0.5)) { typing = true }
            }
            .environment(app)
            .navigationTransition(.zoom(sourceID: Self.headSource, in: rows))
        }
        .accessibilityAction(.escape) { app.closeProject() }
    }

    private func content(_ project: ChatProject) -> some View {
        let list = app.chats(in: project.id)
        return List {
            ForEach(list) { chat in
                ProjectChatRow(chat: chat, rows: rows) { app.openChatPage(chat.id, inProject: project.id) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 16))
                    .listRowBackground(ChatInk.list)
                    .background(SpaceSwipeRowRegion())
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipes(chat) }
                    .contextMenu { menu(chat, in: project) }
            }
            if list.isEmpty {
                Text(app.canStartInProject ? "No chats yet. Ask something below." : "No chats yet.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.rowSubtitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .animation(Motion.columnRows.current, value: list.map(\.id))
        .safeAreaInset(edge: .top, spacing: 0) { head(project) }
        .safeAreaInset(edge: .bottom, spacing: 0) { field(project) }
        .confirmationDialog("Move to Project", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
                            titleVisibility: .visible) {
            if let id = moving {
                ForEach(app.projects.listed.filter { $0.id != project.id }) { other in
                    Button("\(other.emoji) \(other.name)".trimmingCharacters(in: .whitespaces)) { app.moveChat(id, to: other.id) }
                }
                Button("Remove from Project") { app.moveChat(id, to: nil) }
            }
            Button("Cancel", role: .cancel) { moving = nil }
        }
    }

    /// Swiped to the left: Archive (all the way), Pin, Project, as the concept.
    @ViewBuilder private func swipes(_ chat: Chat) -> some View {
        Button {
            app.archive(chat.id)
        } label: { swipeLabel("Archive", .yabArchive) }
        .tint(ChatInk.archive)
        Button {
            app.setPinned(chat.id, !chat.pinned)
        } label: { swipeLabel(chat.pinned ? "Unpin" : "Pin", chat.pinned ? .pinSlash : .pin) }
        .tint(ChatInk.pin)
        if app.canMoveToProject(chat.id) {
            Button {
                moving = chat.id
            } label: {
                Label {
                    Text("Project")
                } icon: {
                    if let image = UIImage.menuGlyph(GlyphName.folder1.rawValue) { Image(uiImage: image) }
                }
            }
            .tint(Color(uiColor: .systemIndigo))
            .accessibilityIdentifier("project.swipe.move")
        }
    }

    private func swipeLabel(_ title: String, _ glyph: MacGlyph) -> some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage.menuGlyph(glyph) { Image(uiImage: image) }
        }
    }

    /// A held row: the chat's menu, as on the Chats page.
    @ViewBuilder private func menu(_ chat: Chat, in project: ChatProject) -> some View {
        Button { app.openChatPage(chat.id, inProject: project.id) } label: { item("Open Chat", .yabChatRight) }
        if chat.lastAnswer != nil {
            Button { app.copyAnswer(of: chat.id) } label: { item("Copy Answer", .yabCopyframeText) }
        }
        Divider()
        Button { app.setPinned(chat.id, !chat.pinned) } label: {
            item(chat.pinned ? "Unpin Chat" : "Pin Chat", chat.pinned ? .pinSlash : .pin)
        }
        Button { app.setUnread(chat.id, !chat.unread) } label: {
            item(chat.unread ? "Mark as Read" : "Mark as Unread", chat.unread ? .yabChat : .yabChatDot)
        }
        MoveToProjectMenu(chat: chat)
        Button { app.archive(chat.id) } label: { item("Archive Chat", .yabArchive) }
    }

    private func item(_ title: String, _ glyph: MacGlyph) -> some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage.menuGlyph(glyph) { Image(uiImage: image) }
        }
    }

    /// ‹ back to the Chats page, ✎ a new chat in the project, and in the
    /// middle its circle and its name, which opens its card.
    private func head(_ project: ChatProject) -> some View {
        ZStack(alignment: .top) {
            HStack {
                RoundSheetButton(glyph: .chevronLeft, size: R.headerSymbol, id: "project.back", label: "Back to Chats", tray: true) {
                    app.closeProject()
                }
                Spacer()
                if app.canStartInProject {
                    Button {
                        app.newChat(inProject: project.id, saying: "", from: ChatPagePresentation.newChat)
                    } label: {
                        Image("MacSquareAndPencil")
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 22, height: 22)
                            .foregroundStyle(Ink.primary)
                            .frame(width: R.headerButton, height: R.headerButton)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: ChatPagePresentation.newChat, in: rows)
                    .accessibilityIdentifier("project.new")
                    .accessibilityLabel("New Chat in \(project.name)")
                }
            }
            .padding(.horizontal, R.trayCloseLead)
            Button {
                app.projects.info = true
            } label: {
                VStack(spacing: 6) {
                    ProjectCircle(project: project, size: 56)
                        .matchedTransitionSource(id: Self.headSource, in: rows) { $0.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)) }
                    HStack(spacing: 3) {
                        Text(project.name)
                            .font(.system(size: R.nameFont, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Glyph(.chevronRight, size: 11, color: Ink.faint)
                    }
                    .frame(maxWidth: 220)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("project.title")
            .accessibilityLabel(project.name)
            .accessibilityHint("Shows the project's instructions and memory")
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { ChatScrollVeil(solid: 0.72).padding(.bottom, -16).ignoresSafeArea(edges: .top) }
    }

    /// "New chat in ‹Name›": the words sent are the first of a new chat in
    /// the project. Not there when the Mac can't start one.
    @ViewBuilder private func field(_ project: ChatProject) -> some View {
        @Bindable var store = app.projects
        if app.canStartInProject {
            let words = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let shape = RoundedRectangle(cornerRadius: R.fieldMin / 2, style: .continuous)
            HStack(spacing: 6) {
                TextField("", text: $store.draft, prompt: Text("New chat in \(project.name)").foregroundStyle(ChatInk.gray(0.5)), axis: .vertical)
                    .font(.system(size: R.trayComposeFont))
                    .foregroundStyle(Ink.black)
                    .lineLimit(1...5)
                    .focused($typing)
                    .submitLabel(.return)
                    .padding(.leading, Metrics.Chat.fieldTextInset - 6)
                    .frame(minHeight: R.fieldButton)
                    .accessibilityIdentifier("project.field")
                if words {
                    Button { send(project) } label: {
                        ZStack {
                            Circle().fill(Color.accentColor)
                            Glyph(.arrowUp, size: 16, color: .white)
                        }
                        .frame(width: R.fieldButton, height: R.fieldButton)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityIdentifier("project.send")
                    .accessibilityLabel("Send")
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: R.fieldMin)
            .chatGlass(in: shape)
            .contentShape(Rectangle())
            .onTapGesture { typing = true }
            .matchedTransitionSource(id: Self.fieldSource, in: rows) { $0.clipShape(shape) }
            .animation(Motion.disabled ? nil : .snappy(duration: 0.2), value: words)
            .padding(.horizontal, R.trayEdge)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private func send(_ project: ChatProject) {
        let words = app.projects.draft
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        typing = false
        app.newChat(inProject: project.id, saying: words)
    }
}

/// One of a project's chats, as a row in Messages: the dot for something
/// new, the agent's mark, the name and when, two lines of what it said.
private struct ProjectChatRow: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let rows: Namespace.ID
    let open: () -> Void

    var body: some View {
        let waits = chat.messages.last { $0.role == .wait }.map { MacWords.waitsFor($0.mac?.name ?? "your Mac") }
        Button(action: open) {
            HStack(spacing: 10) {
                Circle()
                    .fill(chat.unread ? Color.accentColor : .clear)
                    .frame(width: 9, height: 9)
                    .frame(width: 10)
                ChatRowIcon(chat: chat, box: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(chat.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(chat.working ? "working" : waits ?? chat.time)
                            .font(.subheadline)
                            .foregroundStyle(chat.working ? Ink.done : Ink.faint)
                            .lineLimit(1)
                        Glyph(.chevronRight, size: 11, color: Ink.faint)
                    }
                    Text(ChatWords.preview(chat, app: app))
                        .font(.subheadline)
                        .foregroundStyle(Ink.rowSubtitle)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            .padding(.vertical, 10)
            .frame(minHeight: 74)
            .contentShape(Rectangle())
            .matchedTransitionSource(id: chat.id, in: rows) { $0.background(ChatInk.list) }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.chat.\(chat.id)")
        .accessibilityLabel(chat.title)
        .accessibilityValue(chat.unread ? "unread" : "")
    }
}

// MARK: - the project's card

/// A project's card, as a contact's: its circle and name, how many chats,
/// New Chat, then its instructions and its memory switch as the Mac has
/// them. Read only on the iPhone in v1: both are edited on the Mac.
struct ProjectCard: View {
    @Environment(AppModel.self) private var app
    let project: ChatProject.ID
    let newChat: () -> Void

    var body: some View {
        Group {
            if let project = app.projects.project(project) {
                ScrollView {
                    VStack(spacing: 0) {
                        top(project)
                        caption("Instructions")
                        Group {
                            Text(project.instructions.isEmpty ? "None" : project.instructions)
                                .font(.system(size: 17))
                                .foregroundStyle(project.instructions.isEmpty ? Ink.tertiary : Ink.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, R.infoRowInset)
                                .padding(.vertical, 16)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("project.info.instructions")
                        }
                        .modifier(InfoCard())
                        caption("Memory")
                        Group {
                            InfoRow(title: "Remember from These Chats", value: project.memoryOn ? "On" : "Off", id: "project.info.memory") {
                                Glyph(mac: .yabBookopen, size: R.infoRowIcon, color: Ink.primary)
                            }
                        }
                        .modifier(InfoCard())
                        Text("Instructions and memory are edited on your Mac.")
                            .font(.footnote)
                            .foregroundStyle(Ink.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, R.infoRowInset)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, R.infoCardInset)
                    .padding(.bottom, R.trayFullComposeBottom)
                }
                .scrollIndicators(.hidden)
                .overlay(alignment: .top) { head }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatDetails.page.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.info")
        .accessibilityAction(.escape) { app.projects.info = false }
    }

    private func top(_ project: ChatProject) -> some View {
        let count = app.chats(in: project.id).count
        return VStack(spacing: 0) {
            ProjectCircle(project: project, size: R.infoFace)
                .padding(.top, R.infoFaceTop - R.trayFullHeaderTop)
            Text(project.name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 14)
                .accessibilityIdentifier("project.info.title")
            Text(count == 1 ? "1 chat" : "\(count) chats")
                .font(.system(size: 15))
                .foregroundStyle(Ink.tertiary)
                .padding(.top, 3)
            if app.canStartInProject {
                Button(action: newChat) {
                    VStack(spacing: 10) {
                        Glyph(mac: .squareAndPencil, size: R.infoRowIcon, color: Ink.primary)
                            .frame(width: R.infoAction, height: R.infoAction)
                            .background(ChatDetails.tile, in: Circle())
                        Text("New Chat")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("project.info.new")
                .padding(.top, 28)
            }
        }
    }

    private func caption(_ words: String) -> some View {
        Text(words.uppercased())
            .font(.footnote)
            .foregroundStyle(Ink.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, R.infoRowInset)
            .padding(.top, 28)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private var head: some View {
        HStack {
            RoundSheetButton(glyph: .chevronLeft, size: R.headerSymbol, id: "project.info.back", label: "Back to Project", tray: true) {
                app.projects.info = false
            }
            Spacer()
        }
        .padding(.horizontal, R.trayCloseLead)
        .padding(.top, R.trayButtonInset)
        .padding(.bottom, 8)
    }
}

// MARK: - a new chat's project

/// Over a new chat's field begun in a project: the project's circle and
/// name, a menu to start it in another project or on its own.
struct ProjectPill: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let project: ChatProject

    var body: some View {
        Menu {
            ForEach(app.projects.listed) { other in
                Button {
                    app.chats.update(chat.id) { $0.project = other.id }
                } label: {
                    Label { Text(other.name) } icon: { Image(uiImage: ProjectMenuIcon.picture(other)) }
                }
                .disabled(other.id == project.id)
            }
            Divider()
            Button { app.chats.update(chat.id) { $0.project = nil } } label: { Text("No Project") }
        } label: {
            HStack(spacing: 5) {
                ProjectCircle(project: project, size: 20)
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Glyph(.chevronDownSmall, size: 12, color: Ink.faint)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(height: Metrics.Chat.pagePill)
            .background(ChatInk.fill(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("chat.projectPill")
        .accessibilityLabel("Project: \(project.name)")
    }
}
