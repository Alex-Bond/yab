import Foundation

/// Application commands run in the selected frame's normal execution context.
/// Origin selection must never fall back to executing in the top frame.
enum DevApplicationBridge {
    static let script = PageScript.load("dev-application")
}
