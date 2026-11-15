import Foundation
import SwiftUI
import UIKit

/// The named states of answers and chats (M5): the atlas group "Answer and chat"
/// (chat.1…10), the hidden answer and chat (now.11, now.12), the chapter
/// "Chats" step by step (ch-chats.N: where each step ends), and the
/// transitions frame by frame (fin-<mode>.1…6: the sheet stopped at t = 0,
/// .2, .4, .6, .8, 1). Each starts from the atlas's own start: Work,
/// Onboarding v3 in Figma, nothing running.
///
/// The prototype's tray of recent chats (its board "Chat actions",
/// entry.4, ch-chats.2…4, fin-pop, fin-push) is gone: your chats are New
/// Tab's Chats page (chats.page, chats.search in States+Field).
///
/// chat.2 shows Claude's typing dots, the sheet tall enough to hold them
/// (y 619, h 247 on the 17 Pro). The prototype's frame (y 664, h 202) is
/// snapped on the first frame of its height spring, as the dots arrive
/// (its setup asks with quick off, then turns quick on at once): settled,
/// the prototype's sheet holds the dots too.
extension StateCatalog {
    static let chats: [NamedState] = atlas + chapter + frames + chatWork + attach + macWait + long + projects

    private static let anna = "what does anna want?"
    private static let sprint = "and what did she say about the sprint?"

    private static let atlas: [NamedState] = [
        NamedState("chat.1", "Answer on iPhone", "A question about the page: the model on the iPhone answers.") { app in
            app.ask(anna, page: app.browser.tab)
        },
        NamedState("chat.2", "Claude thinking", "A question without a page: Claude answers from the Mac.") { app in
            app.chatSheet.answerers.mac.paused = true
            app.ask("plan a calm saturday", page: nil)
        },
        NamedState("chat.3", "Chat", "Kept talking: the sheet at full height.") { app in
            await annaAndSprint(app)
        },
        NamedState("chat.4", "Chat and keyboard", "The field rides on the keyboard.") { app in
            app.ask(anna, page: app.browser.tab)
            app.expand()
            app.chatSheet.draft = "and the sprint"
            await pause(200)
            app.chatSheet.focused = true
            await pause(900)
        },
        NamedState("chat.5", "Back to Chats", "‹ from the chat: the Chats page in the New Tab card, the chat in its own row.") { app in
            app.ask(anna, page: app.browser.tab)
            app.expand()
            await pause(60)
            app.openHistory()
        },
        NamedState("chat.6", "New chat", "Ideas for the open page.") { app in
            app.newChat(focus: false)
        },
        NamedState("chat.7", "⋯ menu", "Pin, Rename, Unread, Copy, Open on Mac, Archive, Delete.") { app in
            app.openChat("cafe")
            app.chatSheet.moreMenu = true
        },
        NamedState("chat.19", "Chat from the Chats page", "The card grew into the chat, like Chat Info from the face: the system zoom, the chat as a page in its own cover, the Chats page under it as it was.") { app in
            NewTabPager.shared.startAt = NewTabPager.chatsPage
            app.field.openSpaces()
            await pause(400)
            app.openChatFromSpaces("cafe")
            await pause(800)
        },
        NamedState("chat.8", "Mac asleep", "Claude's answer waits, said in words.") { app in
            app.browser.macAsleep = true
            app.ask("plan a calm saturday", page: nil)
            app.expand()
        },
        NamedState("chat.16", "Not sent", "Two questions in a row as one run, the second didn't go: a red ! and Not Sent under it, as in Messages.") { app in
            await annaAndSprint(app)
            guard let id = app.chatSheet.chatID else { return }
            app.chats.update(id) { chat in
                chat.messages.append(Message(role: .you, text: "turn this check off"))
                chat.messages.append(Message(role: .you, text: "it should run once a month"))
                chat.messages.append(Message(role: .failed, text: "This question expired before your Mac received it. Send it again."))
            }
        },
        // chat.9, the task as a chat, is the tasks' sheet (States+Tasks.swift).
        NamedState("chat.info", "Chat profile", "Grown from the face: the face at 88, the name, who answers, Pin, Open on Mac, Archive.") { app in
            await annaAndSprint(app)
            await pause(300)
            app.openChatInfo()
            await pause(600)
        },
        NamedState("chat.bubbles", "Answer in bubbles", "As on the Mac: a paragraph, a heading, a list with a line before it, code between bubbles; a tail on the last one.") { app in
            await annaAndSprint(app)
            guard let id = app.chatSheet.chatID else { return }
            app.chats.update(id) { chat in
                chat.messages.append(Message(role: .you, text: "how should we ship it?"))
                chat.messages.append(Message(role: .answer, text: bubblesAnswer, by: .claude))
            }
        },
        NamedState("chat.table", "Table as cards", "An answer with a four-column table reads as cards, as on the Mac: a title, words, a quiet line and a source with its icon.") { app in
            await annaAndSprint(app)
            guard let id = app.chatSheet.chatID else { return }
            app.chats.update(id) { chat in
                chat.messages.append(Message(role: .you, text: "which accounts on X stream live 24/7?"))
                chat.messages.append(Message(role: .answer, text: tableAnswer, by: .claude))
            }
        },
        NamedState("chat.grid", "Table as grid", "Three columns: a framed grid, the header as a band, numbers on the right.") { app in
            await annaAndSprint(app)
            guard let id = app.chatSheet.chatID else { return }
            app.chats.update(id) { chat in
                chat.messages.append(Message(role: .you, text: "compare the grinders"))
                chat.messages.append(Message(role: .answer, text: gridAnswer, by: .claude))
            }
        },
        NamedState("chat.10", "Task done", "The result, the booking number, where to find it.") { app in
            app.openChat("grinder")
        },
        NamedState("now.11", "Hidden answer", "A tap brings it back, a swipe lets it go.") { app in
            app.ask(anna, page: app.browser.tab)
            await pause(60)
            parkNow(app, mode: .answer)
        },
        NamedState("now.12", "Hidden chat", "The chat's name and its last answer.") { app in
            await annaAndSprint(app)
            parkNow(app, mode: .chat)
        },
    ]

    /// A long chat from a Mac, as a week of research leaves one: 150 turns
    /// (300 messages), each answer's work on a few of 30 sites, links in the
    /// answers, photos and PDFs with some questions. chat.long is the chat
    /// open (the film chatInfoLong taps its face), chat.info.long its Chat
    /// Info (Sites), chat.info.long.3 and .4 on Links and Media.
    private static let long: [NamedState] = [
        NamedState("chat.long", "Long chat", "300 messages, work on 30 sites, links, photos and files.") { app in
            await openLong(app)
        },
        NamedState("chat.info.long", "Long chat profile", "Chat Info of a long chat: the head, actions, the Sites, Links, Media, Files tabs.") { app in
            await openLong(app)
            app.openChatInfo()
            await pause(900)
        },
        NamedState("chat.info.long.3", "Long chat profile, links", "The Links tab: links from the answers, newest first.") { app in
            await openLong(app)
            ChatInfoScroll.tab = .links
            app.openChatInfo()
            await pause(1200)
        },
        NamedState("chat.info.long.4", "Long chat profile, photos", "The Media tab: photos in a grid of three.") { app in
            await openLong(app)
            ChatInfoScroll.tab = .media
            app.openChatInfo()
            await pause(1200)
        },
    ]

    @MainActor
    private static func openLong(_ app: AppModel) async {
        app.chats.add(longChat())
        app.openChat("long")
        await pause(700)
    }

    static let longSites = [
        "booking.com", "airbnb.com", "tripadvisor.com", "timeout.com", "lonelyplanet.com", "google.com", "maps.apple.com",
        "skyscanner.net", "kayak.com", "tap.pt", "visitlisboa.com", "theguardian.com", "nytimes.com", "reddit.com",
        "youtube.com", "wikipedia.org", "x.com", "instagram.com", "eater.com", "michelin.com", "cp.pt", "uber.com",
        "bolt.eu", "weather.com", "accuweather.com", "rome2rio.com", "github.com", "notion.so", "medium.com", "yelp.com",
    ]

    /// 150 turns: a question, an answer with its work (4 to 6 steps on the
    /// sites), every seventh answer with a link, every eleventh question
    /// with a photo, every nineteenth with a PDF.
    @MainActor
    static func longChat() -> Chat {
        let now = Date()
        var messages: [Message] = []
        for turn in 0..<150 {
            var files: [Message.File] = []
            if turn % 11 == 3 {
                let digest = "long-photo-\(turn)"
                if ChatThumbs.image(digest) == nil { ChatThumbs.keep(longPhoto(turn), digest: digest) }
                files.append(Message.File(name: "IMG_\(5100 + turn).HEIC", type: "image/jpeg", size: 1_200_000 + turn * 911, digest: digest))
            }
            if turn % 19 == 5 {
                files.append(Message.File(name: "Itinerary draft \(turn / 19 + 1).pdf", type: "application/pdf", size: 182_400 + turn * 37, digest: "long-pdf-\(turn)"))
            }
            messages.append(Message(role: .you, text: "Question \(turn + 1): what about the \(longSites[turn % 30]) options for day \(turn % 5 + 1)?", files: files))
            let began = now.addingTimeInterval(-Double(150 - turn) * 600)
            let steps: [TurnWork.Step] = (0..<(4 + turn % 3)).map { k in
                let site = longSites[(turn * 3 + k * 7) % 30]
                let name = ["open", "snapshot", "navigate", "click", "fetch", "scroll"][k % 6]
                let detail = name == "open" || name == "navigate" || name == "fetch" ? site : "tab:\(turn)-\(k)"
                return TurnWork.Step(id: "long/\(turn)/\(k)", kind: "tool", name: name, detail: detail, state: "done",
                                     began: began.addingTimeInterval(Double(k) * 9), ended: began.addingTimeInterval(Double(k) * 9 + 7))
            }
            var answer = "For day \(turn % 5 + 1), **\(longSites[(turn * 3) % 30])** had the better picks; I compared prices and reviews across \(steps.count) pages."
            if turn % 7 == 2 {
                let host = longSites[(turn * 5) % 30]
                answer += " See [\(longLinkTitles[turn % longLinkTitles.count])](https://www.\(host)/lisbon/guide-\(turn))."
            }
            let work = TurnWork(kind: .actions, id: "long/\(turn)", words: "Worked for \(40 + turn % 50)s", steps: steps, text: answer,
                                question: nil, at: began.addingTimeInterval(60))
            messages.append(Message(role: .answer, text: answer, by: .claude, work: work))
        }
        return Chat(id: "long", title: "Lisbon trip research", day: .today, time: "20:36", by: .claude, macCLI: "claude", messages: messages)
    }

    private static let longLinkTitles = [
        "Where to stay in Alfama", "Best pastel de nata, ranked", "Tram 28 without the queue", "A day in Sintra",
        "Rooftop bars with a view", "Fado houses worth it", "LX Factory on a Sunday",
    ]

    /// A stand-in photo: a gradient sky and a sun, each its own light.
    private static func longPhoto(_ n: Int) -> UIImage {
        let skies: [(UIColor, UIColor)] = [(.systemOrange, .systemPink), (.systemTeal, .systemBlue), (.systemYellow, .systemOrange),
                                           (.systemIndigo, .systemPurple), (.systemMint, .systemTeal), (.systemCyan, .systemIndigo)]
        let (top, bottom) = skies[n % skies.count]
        let size = CGSize(width: 480, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.85).setFill()
            cg.fillEllipse(in: CGRect(x: 120 + CGFloat(n % 4) * 50, y: 110, width: 90, height: 90))
            UIColor.black.withAlphaComponent(0.4).setFill()
            cg.fill(CGRect(x: 0, y: 360, width: size.width, height: 120))
        }
    }

    /// The chapter "Chats": where each of its steps ends (2 to 4 were the
    /// old tray's search, swipes and archive).
    private static let chapter: [NamedState] = [
        NamedState("ch-chats.1", "All chats", "The Chats page in the New Tab card.") { app in
            app.openChats()
        },
        NamedState("ch-chats.5", "Asked about the page", "The model on the iPhone answers.") { app in
            app.ask(anna, page: app.browser.tab)
        },
        NamedState("ch-chats.6", "Hid the answer", "The answer waits in the Now row.") { app in
            app.ask(anna, page: app.browser.tab)
            await pause(60)
            parkNow(app, mode: .answer)
        },
        NamedState("ch-chats.7", "Came back and asked more", "The chat at full height, Claude answers.") { app in
            await annaAndSprint(app)
        },
        NamedState("ch-chats.8", "History", "‹ brought back the Chats page: the chat went to its own row.") { app in
            await annaAndSprint(app)
            app.openHistory()
        },
        NamedState("ch-chats.9", "Old chat", "Yesterday's task about coffee grinders.") { app in
            await annaAndSprint(app)
            app.openHistory()
            await pause(200)
            app.openChat("grinder")
        },
        NamedState("ch-chats.10", "A task is a chat too", "Lisbon flights: steps, tabs, the result.") { app in
            await annaAndSprint(app)
            app.openHistory()
            await pause(200)
            app.openChat("lisbon")
        },
        NamedState("ch-chats.11", "New chat", "“plan a calm saturday in stockholm”, Claude answers.") { app in
            await saturday(app)
        },
        NamedState("ch-chats.12", "Back to the page", "The chat in the Now row.") { app in
            await saturday(app)
            parkNow(app, mode: .chat)
        },
        NamedState("ch-chats.13", "Let go", "The Now row swiped away: the chat stays on the Chats page.") { app in
            await saturday(app)
            parkNow(app, mode: .chat)
            app.letGoParked(direction: 1)
        },
    ]

    /// A new chat from ✎, Claude asked about a Saturday, the answer in.
    @MainActor
    private static func saturday(_ app: AppModel) async {
        app.chatSheet.answerers.mac.thinking = .milliseconds(10)
        app.newChat(focus: false)
        app.send("plan a calm saturday in stockholm")
        await pause(80)
        app.landNow()
        await pause(80)
    }

    /// The section "Frame by frame": each transition stopped at six points.
    private static let frames: [NamedState] = ["open", "grow", "park"].flatMap { mode in
        (1...6).map { n in
            let t = Double(n - 1) / 5
            return NamedState("fin-\(mode).\(n)", "\(mode), t = \(t)", "") { app in await frame(mode, t: t, in: app) }
        }
    }

    // MARK: - setting them up

    private static func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// An answer of every kind of block, for chat.bubbles.
    private static let bubblesAnswer = """
        Ship it behind a flag first, so the beta keeps its invite flow.

        ## Before Monday
        Three things:
        - the **same as last week** button on frame 2
        - copy for the empty week
        - a check that the hours carry over

        ```
        flags.sameAsLastWeek = true
        ```

        Anna pairs with you on it then.
        """

    /// Asked about Anna on the Figma page, then about the sprint: Claude
    /// carries on and answers.
    private static let tableAnswer = """
I opened the profiles of about 30 news accounts on X. Only TRT World and Al Jazeera English carry a nonstop TV channel stream.

| Account | What's live | 24/7? | Source |
|---|---|---|---|
| @trtworld | TRT World "Live Now", started 3 weeks ago | Yes | x.com |
| @AJEnglish | "LIVE: AL JAZEERA ENGLISH", started 21 hours ago, the stream restarts now and then | Looks like it | [x.com](https://x.com/AJEnglish) |
| @Reuters | Only single events: press conferences and launches | No | x.com |
"""

    private static let gridAnswer = """
Three are worth it.

| Grinder | Price | Steps |
|---|---|---|
| Baratza Encore ESP | $199 | 40 |
| Fellow Opus | $195 | 41 |
| DF54 | $239 | stepless |
"""

    @MainActor
    private static func annaAndSprint(_ app: AppModel) async {
        app.chatSheet.answerers.mac.thinking = .milliseconds(10)
        app.ask(anna, page: app.browser.tab)
        app.send(sprint)
        await pause(80)
        app.landNow()
        await pause(80)
    }

    /// Hidden into the Now line, at once.
    @MainActor
    private static func parkNow(_ app: AppModel, mode: ChatStore.Parked.Mode) {
        guard let id = app.chatSheet.chatID else { return }
        app.chats.update(id) { $0.ephemeral = mode == .answer }
        app.chats.parked = .init(chat: id, mode: mode)
        app.hideSheet()
    }

    /// The prototype's scripted progress: cubic in and out.
    static func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    /// The page's finPrep(p, mode) and its at(t), on this app.
    @MainActor
    private static func frame(_ mode: String, t: Double, in app: AppModel) async {
        await setUp(mode, t: t, in: app)
        // Once more after the views have laid out: nothing late may move it.
        await pause(300)
        await setUp(mode, t: t, in: app, again: true)
    }

    @MainActor
    private static func setUp(_ mode: String, t: Double, in app: AppModel, again: Bool = false) async {
        let sheet = app.chatSheet
        let k = ease(t)
        let screen = app.screenSize
        switch mode {
        case "open":
            if !again {
                app.ask(anna, page: app.browser.tab)
                await pause(120)
            }
            // FIELD_RECT: the New Tab field, 20 from the sides, 10 over the keyboard.
            let field = CGRect(x: 20, y: screen.height - 316 - 46, width: screen.width - 40, height: 46)
            sheet.origin = SheetShape(rect: field, top: 23, bottom: 23)
            sheet.pose.o = 1 - k
            sheet.flight = .init(text: anna, from: CGRect(x: 34, y: field.minY + 4, width: 220, height: 38), fontSize: 17, padding: 2, bubble: 0)
            sheet.flown = min(1, t * 1.1)
            if t >= 1 { sheet.flight = nil }
            sheet.arrival = Arrival(from: 1, shown: min(1, max(0, (t - 0.35) / 0.65)))
        case "grow":
            // The sheet stands up and its foot rises with the keyboard
            // (finPrep moves aiT and aiK together). The system's keyboard
            // can't be stopped mid-rise (it is drawn outside the app), so
            // the frames between hold the foot where the prototype's
            // keyboard top is, and the last one raises the real keyboard:
            // chat.4's pose.
            if !again {
                app.ask(anna, page: app.browser.tab)
                await pause(120)
            }
            if let id = sheet.chatID { app.chats.update(id) { $0.ephemeral = false } }
            sheet.mode = .chat
            sheet.pose.t = k
            if t >= 1, !again {
                sheet.focused = true
                await pause(900)
            }
            let keyboard = t >= 1 ? sheet.keyboard : Metrics.Field.keyboard
            sheet.pose.k = Double(keyboard) * k
            app.syncBehind()
        case "park":
            if !again { await annaAndSprint(app) }
            if let id = sheet.chatID { app.chats.parked = .init(chat: id, mode: .chat) }
            sheet.pose.p = k
            app.syncBehind()
            if t >= 1 { app.hideSheet() }
        default:
            break
        }
    }
}
