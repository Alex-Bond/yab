import Foundation

/// The native panels share a connection, never a simulated document or debugger.
enum DevWorkbenchBridge {
    static let script = PageScript.load("dev-workbench")
}
