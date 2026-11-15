import SwiftUI

/// The approval tray's movements (docs/approvals.md, "On the iPhone"), each a
/// named spring stepped frame by frame (SpringValue), so a tap or a finger
/// in the middle of one carries on from where it is, at the speed it has.
/// The numbers are Yab's trays' (AttachTray) and Amber's window and picture
/// (meta-agent DeckMotion.window, PictureViewer.open), which the user picked.
extension Motion {
    /// Up from the bottom edge, no origin to grow from (it came from the Mac).
    static let approvalIn = spring("approvalIn", response: 0.34, damping: 0.88)
    /// Down and away: quicker than it came, as exits are.
    static let approvalOut = spring("approvalOut", response: 0.22)
    /// Let go short of closing: back where it was.
    static let approvalBack = spring("approvalBack", response: 0.3, damping: 0.82)
    /// One body for another, and the height that comes with it.
    static let approvalStep = spring("approvalStep", response: 0.32, damping: 0.88)
    static let approvalHeight = spring("approvalHeight", response: 0.3, damping: 0.88)
    /// A row into its window and back (Amber's card into its window).
    static let approvalWindow = spring("approvalWindow", response: 0.5, damping: 0.86)
    /// The next or previous item in the window.
    static let approvalPage = spring("approvalPage", response: 0.5, damping: 0.86)
    /// The window's words coasting after a flick, and back inside their ends.
    static let approvalScroll = spring("approvalScroll", response: 0.45)
    /// A file's page out of its thumbnail and back (Amber's picture viewer).
    static let approvalPicture = spring("approvalPicture", response: 0.42, damping: 0.88)
    static let approvalPictureBack = spring("approvalPictureBack", response: 0.4, damping: 0.9)
    /// The tray into its head once it is done, with no bounce.
    static let approvalFold = spring("approvalFold", response: 0.46)
    /// The ring drawing round the button as the answer goes.
    static let approvalRing = curve("approvalRing", 0.4, 0, 0.2, 1, 0.6)
    /// A row just picked, lit and fading.
    static let approvalGlow = easeOut("approvalGlow", 0.8)
    /// Riding on the keyboard.
    static let approvalKeyboard = spring("approvalKeyboard", response: 0.34)
}

/// The tray's sizes. The surface is Yab's tray (8 from the screen, r38, 16
/// inside, AttachTray); the rest is the approved prototype's
/// (claude.ai/artifact/MZjAeESmzDF1vxDr36b3cx).
enum ApprovalMetrics {
    static let inset: CGFloat = 8
    static let radius: CGFloat = 38
    static let pad: CGFloat = 16
    static let maxWidth: CGFloat = 500
    static let header: CGFloat = 60
    /// The tray shrunk into its head: the head and the tray's inset under it.
    static let receipt: CGFloat = 76
    static let mark: CGFloat = 32
    static let face: CGFloat = 17
    static let close: CGFloat = 36
    static let group: CGFloat = 22
    static let row: CGFloat = 64
    static let payRow: CGFloat = 60
    static let avatar: CGFloat = 36
    static let button: CGFloat = 50
    static let question: CGFloat = 22
    static let total: CGFloat = 34
    /// The window's top, under the status bar.
    static let windowTop: CGFloat = 8
    /// The dim behind, and how much deeper it gets behind the window.
    static let dim: Double = 0.28
    static let dimWindow: Double = 0.18
    /// The tray behind a window steps back and darkens.
    static let behindScale: CGFloat = 0.07
    /// The window under the finger: Amber's band, 0.8 of the way and heavier.
    static func band(_ d: CGFloat) -> CGFloat { d <= 0 ? 0 : 0.8 * d / (1 + d / 1400) }
    static let pullClose: CGFloat = 130
    static let pullFlick: CGFloat = 650
    static let pageCommit: CGFloat = 0.25
    static let pageFlick: CGFloat = 500
    /// A new body rises this much as it comes in.
    static let rise: CGFloat = 8
    /// At most this share of a body's lines show before Show All.
    static let paperLines = 6
}
