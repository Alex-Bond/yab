import SwiftUI

/// The chats' movements the skeleton's Motion doesn't name, with the
/// prototype's numbers. Named here so each still runs inside its signpost.
extension Motion {
    /// The agent's face opens its own screen without replacing the tray.
    static let chatInfo = spring("chatInfo", response: 0.34)
    /// The sheet goes down (the prototype's done(), .26 / 1).
    static let chatGone = spring("chatGone", response: 0.26)
    /// Let go of an answer pulled up short of the chat: back to its height.
    static let answerBack = spring("answerBack", response: 0.32)
    /// A finger let go of the sheet short of hiding it: back in place.
    static let sheetDragBack = spring("sheetDragBack", response: 0.3)
    /// A new chat's ideas rise in one after another: each its own 260 ms,
    /// 40 ms after the one before, the first 120 ms after the chat came.
    static let ideaRise = easeOut("ideaRise", 0.26, delay: 0.12)
    static let ideaStagger: TimeInterval = 0.04
    static func ideaRise(at index: Int) -> Motion {
        easeOut("ideaRise", 0.26, delay: 0.12 + Double(index) * ideaStagger)
    }
    /// An answer's first words, in place of the typing bubble (the Mac's
    /// ChatArrival.message): a spring with a touch of give.
    static let chatMessageIn = spring("chatMessageIn", response: 0.3, damping: 0.86)
    /// The typing bubble out of its corner, and back into it, quicker (the
    /// Mac's chatIn and chatQuick).
    static let typingIn = curve("typingIn", 0.19, 1, 0.22, 1, 0.3)
    static let typingOut = curve("typingOut", 0.23, 1, 0.32, 1, 0.15)
    /// The typing dots' beat: brighter, a little bigger and a point up at
    /// 30 % of 1.2 s, each dot 0.2 s after the one before.
    static let typingBeat: TimeInterval = 1.2
    static let typingStagger: TimeInterval = 0.2
    /// Words still coming stand in full this long after the last came (FreshWords).
    static let freshSettle: TimeInterval = 0.15
}
