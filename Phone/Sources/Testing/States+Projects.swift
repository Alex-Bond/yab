import Foundation

/// Projects of chats (PLAN-chat-projects.md, iPhone): the Chats page with
/// pinned projects over the cards and one among them, a project open, its
/// card, a chat in it, a new chat begun there. Mira's world with four
/// projects of its chats, as a Mac would sync them.
extension StateCatalog {
    static let projects: [NamedState] = [
        NamedState("projects.list", "Projects in Chats",
                   "Pinned projects as circles over the cards, a bubble with the news on one, the dots on another; a project not pinned is a card among the chats.") { app in
            seedProjects(app)
            NewTabPager.shared.startAt = NewTabPager.chatsPage
            app.field.openSpaces()
        },
        NamedState("projects.page", "Project", "A project as a group chat: its circle and name, its chats as rows, the field at the foot.") { app in
            await openLisbon(app)
        },
        NamedState("projects.info", "Project card", "The project's card: its circle, New Chat, its instructions and memory, read only.") { app in
            await openLisbon(app)
            app.projects.info = true
            await pause(900)
        },
        NamedState("projects.chat", "Chat in a project", "A chat opened from its project: the project's circle on the agent's face.") { app in
            await openLisbon(app)
            app.openChatPage("lisbon", inProject: lisbonProject)
            await pause(900)
        },
        NamedState("projects.new", "New chat in a project", "✎ in a project: a new chat wearing the project's pill over its field.") { app in
            await openLisbon(app)
            app.newChat(inProject: lisbonProject, saying: "", from: ChatPagePresentation.newChat)
            await pause(900)
        },
        NamedState("projects.typed", "Words in a project's field", "Words in “New chat in Lisbon Trip”, the send button out.") { app in
            await openLisbon(app)
            app.projects.draft = "Is the 7:05 return worth it?"
            await pause(300)
        },
        NamedState("projects.none", "Chats, no projects", "A Mac without projects: the Chats page as before, nothing offered.") { app in
            NewTabPager.shared.startAt = NewTabPager.chatsPage
            app.field.openSpaces()
        },
    ]

    static let lisbonProject = "prj-1a2b3c4d"

    /// Four projects of Mira's chats: three pinned, one not.
    @MainActor static func seedProjects(_ app: AppModel) {
        app.projects.adopt([
            ChatProject(id: lisbonProject, name: "Lisbon Trip", emoji: "\u{1F9F3}", tint: "orange",
                        instructions: "Trip Nov 14 to 19, two people, budget \u{20AC}2,000 all in. Walkable areas, Alfama or Chiado. Short lists with prices in euros.",
                        pinned: true),
            ChatProject(id: "prj-5e6f7a8b", name: "Tern Launch", emoji: "\u{1F680}", tint: "blue", pinned: true),
            ChatProject(id: "prj-9c0d1e2f", name: "Home", emoji: "\u{1F3E0}", tint: "green", memoryOn: false, pinned: true),
            ChatProject(id: "prj-3a4b5c6d", name: "Stockholm", emoji: "\u{2615}\u{FE0F}", tint: "teal"),
        ])
        let into: [String: String] = ["lisbon": lisbonProject, "plan": "prj-5e6f7a8b", "crdt": "prj-5e6f7a8b",
                                      "arch-kitchen": "prj-9c0d1e2f", "cafe": "prj-3a4b5c6d", "weekend": "prj-3a4b5c6d"]
        for (chat, project) in into { app.chats.update(chat) { $0.project = project } }
        // News on Lisbon Trip's circle, Tern Launch answering.
        app.chats.update("lisbon") { chat in
            chat.unread = true
            if chat.lastAnswer == nil {
                chat.messages = [Message(role: .you, text: "Watch flights to Lisbon for Nov 14"),
                                 Message(role: .answer, text: "TAP is \u{20AC}212 now, was \u{20AC}264. easyJet added a 7:05 AM return.", by: .claude)]
            }
        }
        app.chats.update("crdt") { chat in
            if !chat.working { chat.messages.append(Message(role: .typing, by: .claude)) }
        }
    }

    @MainActor private static func openLisbon(_ app: AppModel) async {
        seedProjects(app)
        NewTabPager.shared.startAt = NewTabPager.chatsPage
        app.field.openSpaces()
        await pause(400)
        app.openProject(lisbonProject)
        await pause(800)
    }

    private static func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
}
