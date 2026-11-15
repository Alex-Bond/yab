import Foundation
import UserNotifications
#if canImport(SyncKit)
import SyncKit
#endif

/// A question from an agent on a Mac, as the person sees it on the Lock
/// Screen: who asks and what ("Claude: Pay $12.00?"), and the site and
/// amount under it. The sync server's alert carries only generic words and
/// the question's sealed record; the notification extension (Notify/) opens
/// that record with this iPhone's Sync key, the app does the same for what
/// its line brings, and both file the notification under the question's
/// id, so one question is one notification.
enum ApprovalNotice {
    static let thread = "approval"
    /// The question's own two notes, the Mac's (AskSound), in the app's
    /// bundle (Resources/Sounds, scripts/ask-sound). The server's alert
    /// names it too, so a question that can't be opened sounds the same.
    static let sound = "ask.caf"

    struct Shown: Equatable {
        let id: String
        let title: String
        let body: String
    }

    static func shown(_ request: AssistantApprovalRecords.Request) -> Shown {
        Shown(id: request.id, title: request.title, body: request.summary)
    }

    /// The question in an alert's payload, opened, or nil: no record (it
    /// was too big for APNs), no key, or one that doesn't open or has run
    /// out. Only a device with the account's key can open it at all.
    static func open(_ info: [AnyHashable: Any], seal: Seal?, now: Date = Date()) -> Shown? {
        guard let seal, let yab = info["yab"] as? [String: Any], let name = yab["n"] as? String,
              let text = yab["b"] as? String, let data = Data(base64Encoded: text),
              let record = try? seal.open(data, name: name),
              record.collection == AssistantApprovalRecords.requestCollection,
              let writer = record.stamps["body"]?.device,
              let request = try? AssistantApprovalRecords.Request.read(record, account: seal.account, mac: writer),
              (try? request.validate(at: now)) != nil else { return nil }
        return shown(request)
    }

    static func content(_ shown: Shown, into content: UNMutableNotificationContent = UNMutableNotificationContent()) -> UNMutableNotificationContent {
        content.title = shown.title
        content.body = shown.body
        content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
        // Through Focus and Scheduled Summary, as on the Mac: someone waits.
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = thread
        content.userInfo["approval"] = shown.id
        return content
    }

    /// Compare the system's entire inbox, including alerts delivered before
    /// this process started. Seen questions stay answerable inside Yab.
    static func stale(_ delivered: [(identifier: String, approval: String?, thread: String)],
                      requests: [AssistantApprovalRecords.Request]) -> [String] {
        let ringing = Set(requests.filter { $0.seen == nil }.map { $0.id.lowercased() })
        return delivered.filter { $0.thread == thread && !ringing.contains(($0.approval ?? $0.identifier).lowercased()) }.map(\.identifier)
    }

    // Accessed on the main queue. A later journal snapshot supersedes an
    // outstanding notification read, so it cannot ring a closed question.
    private static var generation = 0
    private static var completions: [() -> Void] = []

    static func fresh(_ questions: [Shown], present: Set<String>, announced: Set<String>) -> [Shown] {
        let known = Set(present.union(announced).map { $0.lowercased() })
        return questions.filter { !known.contains($0.id.lowercased()) }
    }

    static func reconcile(_ requests: [AssistantApprovalRecords.Request], center: UNUserNotificationCenter = .current(),
                          done: @escaping () -> Void = {}) {
        DispatchQueue.main.async {
            completions.append(done)
            generation += 1
            let current = generation
            center.getNotificationSettings { settings in
                center.getDeliveredNotifications { delivered in
                    center.getPendingNotificationRequests { pending in
                        DispatchQueue.main.async {
                            guard current == generation else { return }
                            let deliveredRows = delivered.map { ($0.request.identifier, $0.request.content.userInfo["approval"] as? String,
                                                                  $0.request.content.threadIdentifier) }
                            let pendingRows = pending.map { ($0.identifier, $0.content.userInfo["approval"] as? String,
                                                            $0.content.threadIdentifier) }
                            center.removeDeliveredNotifications(withIdentifiers: stale(deliveredRows, requests: requests))
                            center.removePendingNotificationRequests(withIdentifiers: stale(pendingRows, requests: requests))
                            let there = Set((deliveredRows + pendingRows).filter { $0.2 == thread }.flatMap {
                                [$0.0.lowercased(), ($0.1 ?? "").lowercased()]
                            })
                            let defaults = UserDefaults.standard
                            let now = Date().timeIntervalSince1970
                            var announced = (defaults.dictionary(forKey: "approval.notices") as? [String: Double] ?? [:])
                                .filter { now - $0.value < 172_800 }
                            for id in there where !id.isEmpty { announced[id] = now }
                            let questions = requests.filter { $0.seen == nil }.map(shown)
                            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                            let group = DispatchGroup()
                            if allowed {
                                for question in fresh(questions, present: there, announced: Set(announced.keys)) {
                                    announced[question.id.lowercased()] = now
                                    group.enter()
                                    center.add(UNNotificationRequest(identifier: question.id, content: content(question), trigger: nil)) { _ in group.leave() }
                                }
                            }
                            defaults.set(announced, forKey: "approval.notices")
                            group.notify(queue: .main) {
                                guard current == generation else { return }
                                let finished = completions
                                completions = []
                                for complete in finished { complete() }
                            }
                        }
                    }
                }
            }
        }
    }
}
