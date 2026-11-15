import AppKit

/// The default engine. Choosing one writes it at once and gives it to every
/// tab with no page; a tab with a page keeps its engine and its document, with
/// no reload, and takes the default when it next wakes. Sites decide on top.
@MainActor
enum EngineSwitchGlobal {
    private static var observation: NSObjectProtocol?
    private static var lastRequested: PageEngineKind?

    static func install() {
        guard observation == nil else { return }
        lastRequested = PageEngineFactory.requestedEngine ?? .webKit
        observation = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                             object: nil, queue: nil) { _ in
            // queue: .main would hold whichever thread wrote the default until
            // the main thread ran this, and the launch hung on a lock between them.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let selected = PageEngineFactory.requestedEngine ?? .webKit
                    guard selected != lastRequested else { return }
                    settle(selected)
                }
            }
        }
    }

    static func choose(_ kind: PageEngineKind) throws {
        guard kind != .chromium || PageEngineFactory.chromiumAvailable else { throw SiteEngineError.unavailable }
        // An explicit selection supersedes the launch argument.
        var arguments = Store.settings.volatileDomain(forName: "NSArgumentDomain")
        if arguments[PageEngineSelection.key] != nil {
            arguments[PageEngineSelection.key] = kind.rawValue
            Store.settings.setVolatileDomain(arguments, forName: "NSArgumentDomain")
        }
        Store.settings.set(kind.rawValue, forKey: PageEngineSelection.key)
        settle(kind)
    }

    private static func settle(_ kind: PageEngineKind) {
        lastRequested = kind
        for tab in BrowserWindows.shared.browsers.flatMap(\.pagesHeld) where tab.engineFactory.followsGlobalSelection {
            tab.followDefaultEngine(kind)
        }
    }
}
