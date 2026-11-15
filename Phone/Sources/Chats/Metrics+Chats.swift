import CoreGraphics

/// The chats' sizes and thresholds the skeleton's Metrics doesn't name, with
/// the prototype's numbers. Kept here, beside the views that use them, so
/// every number still has one name.
extension Metrics.Chat {
    /// What an answer or a chat grows out of (the field, the
    /// Now line, a button) keeps at most these round corners.
    static let originRadius: CGFloat = 26
    /// The words in a field as they leave it: 14 in from the field's edge
    /// (2 before a chat's own field), one 38 high line, at most 300 wide,
    /// clear of the field's buttons (60).
    static let flightInset: CGFloat = 14
    static let flightLead: CGFloat = 2
    static let flightHeight: CGFloat = 38
    static let flightMaxWidth: CGFloat = 300
    static let flightClear: CGFloat = 60
    /// The field's words start 16 in from its edge; a new chat's ideas put
    /// their site marks on that same line, as ⌘J's do on the Mac.
    static let fieldTextInset: CGFloat = 16
    /// Copy and Open in Chat under an answer: 15 high, 2 over, 10 under.
    static let actionsHeight: CGFloat = 27
    /// The turns inside the body: 4 under its top, 10 over its foot.
    static let turnsTop: CGFloat = 4
    static let turnsBottom: CGFloat = 10
    /// The question's line height: 22 for Messages' 17.
    static let bubbleLineHeight: CGFloat = 1.3
    /// The ⋯ menu: seven conversation actions and their padding, for its anchor.
    static let menuHeight: CGFloat = 320
    /// It grows out of ⋯: 22 in from its right edge, 10 over its top.
    static let menuAnchorRight: CGFloat = 22
    static let menuAnchorAbove: CGFloat = 10
    /// Under the status bar, the ⋯ menu's top (the head's buttons, 52 under it).
    static let menuTop: CGFloat = 52
    /// A finger on the sheet: pulled down 90 or flicked at 600 it hides; an
    /// answer pulled up a quarter of the way, or flicked at 500, stands up.
    static let hideDistance: CGFloat = 90
    static let hideVelocity: CGFloat = 600
    static let standShare: Double = 0.25
    static let standVelocity: CGFloat = 500
    /// An answer pulled up stands as a chat 54 short of where it rests.
    static let standSlack: CGFloat = 54
    /// A message's tail, as Messages (iOS 26) draws it (MessageBubble): it
    /// hangs under the bubble's foot corner, inside its width, so it takes
    /// no room beside the bubble; 5 under its foot.
    static let tailRoom: CGFloat = 0
    static let tailDrop: CGFloat = 5
    /// Between messages, as Messages: 2 in a run from one side, 10 when the
    /// other side speaks; a status line ("Waits for your Mac", "Not Sent")
    /// 4 under the tail of the bubble it is about.
    static let runGap: CGFloat = 2
    static let turnGap: CGFloat = 10
    static let statusGap: CGFloat = 4 + tailDrop
    static let statusFont: CGFloat = 11.5
    /// A question that wasn't sent: its red ! beside the bubble, 22, 8 off.
    static let failedMark: CGFloat = 22
    static let failedGap: CGFloat = 8
    /// An answer's paragraphs are its bubbles, 2 apart (a run, as in
    /// Messages), the blocks of one 8
    /// apart, at least 40 left beside them; a table or code stands between
    /// them on their body, 4 from them (the Mac's ChatWords, the bubbles'
    /// padding a size up with the words).
    static let answerBubbleGap: CGFloat = 2
    static let answerBlockGap: CGFloat = 8
    static let answerRoom: CGFloat = 40
    static let answerAsideGap: CGFloat = 4
    /// Code in an answer: monospaced on a faint ground, 8 round, 12 in.
    static let codeRadius: CGFloat = 8
    static let codePadding: CGFloat = 12
    /// The first words of an answer grow out of the typing bubble's corner:
    /// from 8 lower, at .96.
    static let arrivalRise: CGFloat = 8
    static let arrivalScale: CGFloat = 0.96
    /// The typing bubble: a 64 x 36 capsule, its tail two drops at its foot
    /// (10 at 2, 2 and 4 at -2, 6) with 6 under it for them; three dots of
    /// 8, 12 apart, swelling to 1.06 and a point up on their beat. It comes
    /// from its corner at .92.
    static let typingSize = CGSize(width: 64, height: 36)
    static let typingDrop: CGFloat = 10
    static let typingDropAt = CGSize(width: 2, height: 2)
    static let typingDrip: CGFloat = 4
    static let typingDripAt = CGSize(width: -2, height: 6)
    static let typingFoot: CGFloat = 6
    static let typingDot: CGFloat = 8
    static let typingPitch: CGFloat = 12
    static let typingSwell: CGFloat = 1.06
    static let typingRise: CGFloat = 1
    static let typingScale: CGFloat = 0.92
}

extension Metrics.Chats {
    /// A conversation and a compact new chat share the same bottom field.
    static let newTrayHeight: CGFloat = 388
    static let conversationHeader: CGFloat = 104
    static let infoHeader: CGFloat = 150
    static let face: CGFloat = 44
    static let faceInk: CGFloat = 28
    /// The avatar's drawing, edge to edge: 40 in the header's 44, 96 in Info's 104.
    static let faceArt: CGFloat = 40
    static let infoFaceArt: CGFloat = 96
    static let infoFace: CGFloat = 104
    static let nameHeight: CGFloat = 44
    static let nameFont: CGFloat = 15
    static let nameLineFont: CGFloat = 12
    static let headerButton: CGFloat = 44
    static let headerSymbol: CGFloat = 20
    static let infoFaceDrop: CGFloat = 50
    static let headerGap: CGFloat = 8
    static let headerNameRoom: CGFloat = 188
    /// Where a finger takes a chat in the sheet back to its card: its left 24 points.
    static let edgePanWidth: CGFloat = 24
    /// The chat's back button: ‹ and the unread count on glass, 44 tall.
    static let backCount: CGFloat = 13
    /// The header's face is the avatar: a 44 circle, the drawing 40 in it,
    /// over a one-line name capsule 29 tall that tucks 8 under it.
    static let nameCapsule: CGFloat = 29
    static let nameTuck: CGFloat = 8
    static let nameCapsuleMax: CGFloat = 200
    static let faceTop: CGFloat = 6
    /// Chat Info as X's profile: the face 104 at 115, a 36 chip, round white
    /// actions 72 in columns 95 wide, one card 24 round of rows 60, 16 in.
    static let infoFaceTop: CGFloat = 115
    static let infoChip: CGFloat = 36
    static let infoAction: CGFloat = 72
    static let infoActionColumn: CGFloat = 95
    static let infoCardInset: CGFloat = 16
    static let infoCardRadius: CGFloat = 24
    static let infoRow: CGFloat = 60
    static let infoRowIcon: CGFloat = 24
    static let infoRowInset: CGFloat = 16
    static let infoPencil: CGFloat = 20
    /// Chat Info's × on the left, 12 in.
    static let trayCloseLead: CGFloat = 12
    /// A conversation, as Messages (iOS 26, measured): its head's buttons
    /// and its bubbles' outer edge 16 from the screen.
    static let trayEdge: CGFloat = 16

    static let trayHeaderInset: CGFloat = 20
    static let trayTitleFont: CGFloat = 18
    static let trayFullHeaderTop: CGFloat = 48
    /// Full chat pages have no sheet corners.
    static let trayFullRadius: CGFloat = 0
    static let scrollFootFade: CGFloat = 24
    /// Under a conversation's head the veil is opaque for its first 72 %
    /// (the status bar, the buttons and the name), fading out under it.
    static let headSolid: CGFloat = 0.72
    /// The field, as Messages' (iOS 26, measured): 40 tall, its words 17.
    static let trayComposeHeight: CGFloat = 40
    static let trayComposeFont: CGFloat = 17
    /// It stands in from the bubbles, 29 a side; with the keyboard up it
    /// takes the width, 16 a side, 16 over the keyboard.
    static let trayComposeInset: CGFloat = 29
    static let trayComposeTypingInset: CGFloat = 16
    static let trayComposeOverKeyboard: CGFloat = 16
    static func composeInset(keyboard: Bool) -> CGFloat { keyboard ? trayComposeTypingInset : trayComposeInset }
    static let trayComposeBottom: CGFloat = 16
    /// Messages' (iOS 26, measured from a screenshot): 27 from the bottom.
    static let trayFullComposeBottom: CGFloat = 27
    static let trayButtonInset: CGFloat = 10
    /// Send: the system's accent in a 30 circle inside the field, shown
    /// once there are words (there is no dictation to offer).
    static let traySendButton: CGFloat = 30
    /// The field with + in it, as the Mac's: one line 44 tall (radius 22),
    /// + and send round 32 in it; with photos or files, or words that need
    /// the room, two rows, the words over + · chips · send. Chips 30 tall.
    static let fieldMin: CGFloat = 44
    static let fieldButton: CGFloat = 32
    static let fieldChip: CGFloat = 30
    /// Add to Chat, a tray floating 8 in from the screen's edges, its corners
    /// concentric with the iPhone's.
    static let trayInset: CGFloat = 8
    static let trayCorner: CGFloat = Metrics.FirstTray.radius
    /// What stands 16 in from the tray's edge is concentric with it.
    static let trayPad: CGFloat = 16
    static let trayCard: CGFloat = trayCorner - trayPad
    /// Camera, Photos, Files: three cards of one size in a row.
    static let attachMediaHeight: CGFloat = 100
    static let attachTileGap: CGFloat = 10
    static let attachMediaGap: CGFloat = 8
    static let attachCameraSymbol: CGFloat = 22

    /// A new chat grows out of + (25) or ✎ (20).
    static let plusRadius: CGFloat = 25
    static let composeRadius: CGFloat = 20
    /// The Now line under a finger: flicked past 110 or at 650 a second it
    /// goes, 420 off to its side; it fades over 320 as it is pulled.
    static let letGoDistance: CGFloat = 110
    static let letGoVelocity: CGFloat = 650
    static let letGoFlight: CGFloat = 420
    static let letGoFade: CGFloat = 320
    /// A swiped row (History's) let go: open past 60 or flicked at 500; a
    /// long swipe sends it 400 off to its side before it acts.
    static let swipeOpenDistance: CGFloat = 60
    static let swipeOpenVelocity: CGFloat = 500
    static let swipeAway: CGFloat = 400
}
