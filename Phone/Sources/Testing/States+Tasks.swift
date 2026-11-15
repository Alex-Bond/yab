import Foundation

/// The tasks' named states: the atlas groups "Now row" (now.2...now.10;
/// now.1 is the Mac's handoff, the sync branch's; now.11 and now.12 are the
/// chats'), "Code and yes" (yes.1...yes.5) and "Outside Yab" (out.1...out.8), the
/// task as a chat (chat.9), and the ends of the chapters "Tasks"
/// (ch-tasks.1...7) and "Mac" (ch-mac.1...5). The column's task rows
/// (column.7, column.9) are the column's states. Each starts from the atlas's
/// start (Work, Onboarding v3 in Figma, nothing running) and puts the runs
/// where the frame has them; nothing moves on its own in a named state.
extension StateCatalog {
    static let tasks: [NamedState] = now + yes + outside + chapters

    // MARK: - the Now line

    private static let now: [NamedState] = [
        NamedState("now.2", "Sent", "Until the Mac picks up the task.") { app in
            put(app, "lisbon", .sending)
        },
        NamedState("now.3", "Running", "The step in words and the site the Mac is on.") { app in
            put(app, "lisbon", .running, step: 1)
        },
        NamedState("now.4", "Running, and more", "“+1”: the rest in the column.") { app in
            put(app, "lisbon", .running, step: 1)
            put(app, "lumen", .running, step: 1)
        },
        NamedState("now.5", "Needs a code", "Orange, Enter Code.") { app in
            put(app, "lisbon", .code, step: 2)
        },
        NamedState("now.6", "Needs a yes", "Review opens the facts and Face ID.") { app in
            put(app, "lisbon", .yes, step: 3)
        },
        NamedState("now.7", "Didn't work", "What happened and Retry.") { app in
            put(app, "lisbon", .failed, step: 2)
        },
        NamedState("now.8", "Waiting for Mac", "Gray: the Mac is asleep, the task isn't lost.") { app in
            asleep(app)
            put(app, "anna", .waits)
        },
        NamedState("now.9", "Payment", "The Mac presses Pay on the site.") { app in
            put(app, "lisbon", .paying, step: 3)
        },
        NamedState("now.10", "Done", "Green until the result is opened.") { app in
            put(app, "lisbon", .done, step: 3)
        },
    ]

    // MARK: - the code and the yes

    private static let yes: [NamedState] = [
        NamedState("yes.1", "Code from Messages", "The keyboard offers the code itself.") { app in
            put(app, "lisbon", .code, step: 2)
            app.taskDesk.pictureCode = ""
            app.taskDesk.showStill(.code("lisbon"))
        },
        NamedState("yes.2", "Code entered", "Goes to the Mac, encrypted.") { app in
            put(app, "lisbon", .code, step: 2)
            app.taskDesk.pictureCode = MacScript.story["lisbon"]?.expectedCode ?? ""
            app.taskDesk.showStill(.code("lisbon"))
        },
        NamedState("yes.3", "Facts before yes", "Amount, flights, seat, card: from the page.") { app in
            put(app, "lisbon", .yes, step: 3)
            app.taskDesk.showStill(.yes("lisbon"))
        },
        NamedState("yes.4", "Face ID", "Signs this exact payment.") { app in
            put(app, "lisbon", .yes, step: 3)
            app.taskDesk.showStill(.yes("lisbon"), faceID: .looking)
        },
        NamedState("yes.5", "Signed", "The Mac checks the signature and presses Pay.") { app in
            put(app, "lisbon", .yes, step: 3)
            app.taskDesk.showStill(.yes("lisbon"), faceID: .signed)
        },
    ]

    // MARK: - outside Yab

    private static let outside: [NamedState] = [
        NamedState("out.1", "Island", "Two words and the site.") { app in
            island(app, .running, step: 1)
        },
        NamedState("out.2", "Island: waiting for you", "An orange word.") { app in
            island(app, .code, step: 2)
        },
        NamedState("out.3", "Running", "The step in words, Stop.") { app in
            lock(app, .running, step: 1, open: false)
        },
        NamedState("out.4", "Needs a code", "Enter Code sleeps until Face ID.") { app in
            lock(app, .code, step: 2, open: false)
        },
        NamedState("out.5", "Payment, locked", "“A payment needs you”, no amount.") { app in
            lock(app, .yes, step: 3, open: false)
        },
        NamedState("out.6", "Payment, recognized", "Review works now.") { app in
            lock(app, .yes, step: 3, open: true)
        },
        NamedState("out.7", "Done", "The result and where it is.") { app in
            lock(app, .done, step: 3, open: false)
        },
        NamedState("out.8", "Error", "What happened; Retry in Yab.") { app in
            lock(app, .failed, step: 2, open: false)
        },
    ]

    // MARK: - the chapters

    private static let chapters: [NamedState] = [
        NamedState("chat.9", "Task as a chat", "Steps in words, its tabs on the Mac.") { app in
            put(app, "lisbon", .running, step: 1)
            app.taskDesk.openChat("lisbon", from: .other(nil))
        },
        NamedState("ch-tasks.1", "Words decide: a task", "The task goes to the Mac: the Now row says “Sending”, then the step in words.") { app in
            flights(app)
            put(app, "lisbon", .running, step: 2)
        },
        NamedState("ch-tasks.2", "Task in the column", "At the end of the space, the task's folder with its words.") { app in
            flights(app)
            put(app, "lisbon", .running, step: 1)
        },
        NamedState("ch-tasks.3", "In another app", "A tap on the island: the task's chat grows out of it, a swipe down folds it into the Now row.") { app in
            flights(app)
            put(app, "lisbon", .running, step: 1)
        },
        NamedState("ch-tasks.4", "Code from Messages", "The code went to the Mac, the task carries on.") { app in
            flights(app)
            put(app, "lisbon", .running, step: 3)
            app.tasks.update("lisbon") { $0.codeGiven = true }
            app.taskDesk.openChat("lisbon", from: .other(nil))
        },
        NamedState("ch-tasks.5", "Lock screen", "Face ID recognized Mira, and Review works now.") { app in
            flights(app)
            lock(app, .yes, step: 3, open: true)
        },
        NamedState("ch-tasks.6", "Face ID signs the yes", "The Mac checks the signature and presses Pay itself.") { app in
            flights(app)
            put(app, "lisbon", .done, step: 3)
        },
        NamedState("ch-tasks.7", "Done", "Once opened, the result leaves the row.") { app in
            flights(app)
            put(app, "lisbon", .done, step: 3)
            app.tasks.markSeen("lisbon")
        },
        NamedState("ch-mac.1", "From Mac to iPhone", "A tap opens the same view here, the row goes away.") { app in
            app.tasks.handoff = nil
        },
        NamedState("ch-mac.2", "Mac asleep: task waits", "“Waits for your Mac · asleep since 18:52”, in gray.") { app in
            asleep(app)
            put(app, "anna", .waits)
        },
        NamedState("ch-mac.3", "Mac woke up", "The task started by itself: “3 replies drafted · not posted”.") { app in
            put(app, "anna", .done, step: 1)
        },
        NamedState("ch-mac.4", "Didn't work", "Retry runs it again from the same step.") { app in
            put(app, "anna", .done, step: 1)
            app.tasks.markSeen("anna")
            put(app, "lisbon", .running, step: 1)
        },
        NamedState("ch-mac.5", "Claude's answer waits too", "While the Mac sleeps, the answer waits.") { app in
            put(app, "lisbon", .done, step: 3)
            app.tasks.markSeen("lisbon")
            asleep(app)
            let chat = Chat(id: "calm-saturday", title: "Plan a calm saturday", time: "18:43", by: .claude,
                            messages: [Message(role: .you, text: "plan a calm saturday?"), Message(role: .wait)])
            app.chats.add(chat)
            app.chats.parked = ChatStore.Parked(chat: chat.id, mode: .answer)
        },
    ]

    // MARK: - setting them up

    /// A task's run where the frame has it, and what the Mac asked for it.
    @MainActor
    private static func put(_ app: AppModel, _ id: TaskRun.ID, _ status: TaskStatus, step: Int = 0) {
        app.tasks.start(id)
        app.tasks.set(id, status: status, step: step)
        if status == .paying || status == .done { app.tasks.update(id) { $0.codeGiven = true; $0.yesGiven = true } }
        if status == .waits { app.tasks.update(id) { $0.asleepSince = app.taskDesk.macAsleepSince } }
        app.taskDesk.setRequests(id)
    }

    /// The Mac asleep since 18:52.
    @MainActor
    private static func asleep(_ app: AppModel) {
        app.taskDesk.apply(.presence(.asleep(since: app.taskDesk.virtualMac?.script.asleepSince ?? "18:52")))
    }

    /// The chapter "Tasks" starts on Lisbon's flights.
    @MainActor
    private static func flights(_ app: AppModel) {
        app.browser.select("lisbon-flights")
    }

    /// Another app in front, the task in the Island.
    @MainActor
    private static func island(_ app: AppModel, _ status: TaskStatus, step: Int) {
        put(app, "lisbon", status, step: step)
        if let state = TaskActivityContent.state(desk: app.taskDesk) {
            app.taskDesk.outside = .island(state)
        }
    }

    /// The Lock Screen with the task's Live Activity.
    @MainActor
    private static func lock(_ app: AppModel, _ status: TaskStatus, step: Int, open: Bool) {
        put(app, "lisbon", status, step: step)
        if let state = TaskActivityContent.state(desk: app.taskDesk) {
            app.taskDesk.outside = .lock(state, open: open)
        }
    }
}
