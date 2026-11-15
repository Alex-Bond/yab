import ActivityKit
import AppIntents
import Foundation

/// Stop and Not Now on the Lock Screen act where they are: the system runs
/// them in Yab's own process (a LiveActivityIntent), without opening it.
/// Enter Code, Review, Retry and Open are links into Yab instead.
///
/// They ask for the person first: on a locked iPhone nothing happens until
/// Face ID knows the face (or the passcode is typed), so someone holding the
/// phone can't stop Mira's task.
struct TaskActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Task on your Mac"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Task") var task: String
    @Parameter(title: "Action") var action: String

    init() {}

    init(task: String, action: String) {
        self.task = task
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        await TaskIntentRouter.handle(task: task, action: action)
        return .result()
    }
}

/// Where the intent lands in the app; nothing in the widget's own process.
enum TaskIntentRouter {
    /// The running app's desk (TaskDesk sets it as it starts).
    @MainActor static var handler: ((String, String) -> Void)?

    struct Pending: Codable, Equatable {
        var task: String
        var action: String
    }

    private static let key = "yab.tasks.pendingActivityActions"

    /// With Yab running, the desk acts at once. Launched in the background
    /// for the tap alone (no scene, no desk yet), the tap is kept for the
    /// desk to act on when it starts, and the activity says at once what the
    /// tap did: Stop ends it, Not Now takes the question off the Lock Screen.
    @MainActor
    static func handle(task: String, action: String) async {
        guard action == "stop" || action == "notNow" else { return }
        if let handler {
            handler(task, action)
            return
        }
        var pending = load()
        pending.append(Pending(task: task, action: action))
        save(pending)
        await settle(task: task, action: action)
    }

    /// Taps kept while Yab wasn't running, oldest first; read once.
    @MainActor
    static func takePending() -> [Pending] {
        let pending = load()
        if !pending.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        return pending
    }

    private static func load() -> [Pending] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    private static func save(_ pending: [Pending]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: key)
    }

    /// The activity of `task`, told what the tap did, before the Mac hears it.
    @MainActor
    private static func settle(task: String, action: String) async {
        for activity in Activity<TaskActivityAttributes>.activities where activity.content.state.task == task {
            switch action {
            case "stop":
                await activity.end(nil, dismissalPolicy: .immediate)
            case "notNow":
                var state = activity.content.state
                state.line = "Not now. It waits for you in Yab."
                state.buttons = state.buttons.filter { $0.action != "notNow" }
                await activity.update(ActivityContent(state: state, staleDate: nil))
            default:
                break
            }
        }
    }
}
