import Foundation

// Console's module in WebKit's inspector page (DevWire.swift): every message
// the page's console says, as WebKit's frontend hears it, posted on the
// "console" channel; and what Yab's Console asks back: an expression run, an
// object's properties, a Map's entries, a getter, the contexts there are,
// names to complete, live expressions, a node shown, a function's place.
//
// A value goes over as the protocol gives it, a RemoteObject: its type,
// subtype, description, preview, and its objectId, which Yab hands back to
// ask for more of it with the protocol's own commands.

enum DevConsoleBridge {
    static let script = PageScript.load("dev-console")
}
