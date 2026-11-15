import UIKit

/// Whether Yab is the default browser. iOS answers only four times a year and
/// then refuses until a date it names, so the answer is kept and asked for
/// rarely. A link from another app answers too: http and https reach only the
/// default browser.
@MainActor
enum DefaultBrowser {
    private static let answerKey = "defaultBrowser.answer"
    private static let askedKey = "defaultBrowser.asked"
    private static let retryKey = "defaultBrowser.retry"
    /// Four answers a year, one kept back for a return from iOS Settings.
    private static let askEvery: TimeInterval = 120 * 24 * 60 * 60

    /// "Open iOS Settings" was pressed here: the person may be changing it.
    static var asksOnReturn = false

    /// What is known; nil until iOS or a link has said.
    static func answer(in defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: answerKey) as? Bool
    }

    /// A link came from another app, so Yab is the default.
    static func linkArrived(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: answerKey)
    }

    /// The answer, asking iOS when it is time. `force` is for the person
    /// coming back from iOS Settings; a refusal's date still holds.
    @discardableResult
    static func refresh(force: Bool = false, now: Date = Date(), in defaults: UserDefaults = .standard,
                        ask: () throws -> Bool = { try UIApplication.shared.isDefault(.webBrowser) }) -> Bool? {
        if let retry = defaults.object(forKey: retryKey) as? Date, now < retry { return answer(in: defaults) }
        if !force, let asked = defaults.object(forKey: askedKey) as? Date, now.timeIntervalSince(asked) < askEvery {
            return answer(in: defaults)
        }
        do {
            defaults.set(try ask(), forKey: answerKey)
            defaults.set(now, forKey: askedKey)
            defaults.removeObject(forKey: retryKey)
        } catch {
            let retry = (error as NSError).userInfo[UIApplication.CategoryDefaultError.retryAvailableDateErrorKey] as? Date
            defaults.set(retry ?? now.addingTimeInterval(askEvery), forKey: retryKey)
        }
        return answer(in: defaults)
    }
}
