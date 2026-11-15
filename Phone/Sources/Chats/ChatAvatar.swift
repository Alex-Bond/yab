import SwiftUI
import UIKit

/// The agent's face, drawn edge to edge in its own filled circle, as X's
/// avatars are: the face is the avatar, not a mark on a glass button. It is
/// drawn by SwiftUI (so it stands over the name's glass capsule tucked under
/// it); the native control over it takes the touch, and this whole view is
/// the source UIKit's Info zoom grows out of.
struct ChatAvatar: View {
    @Environment(\.colorScheme) private var scheme
    let chat: Chat
    var large = false

    var body: some View {
        let art = large ? Metrics.Chats.infoFaceArt : Metrics.Chats.faceArt
        ZStack {
            Circle().fill(Color(uiColor: ChatAvatarControl.fill(large: large)))
            if chat.by == .iphone {
                Glyph(.sparkle, size: art * 2 / 3, color: Ink.primary)
            } else {
                AgentFace(size: art, color: Ink.primary)
            }
            ChatAvatarButton(chat: chat, large: large)
        }
    }
}

/// The native button over the drawn face: its target and generation rules.
private struct ChatAvatarButton: UIViewRepresentable {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let large: Bool

    func makeUIView(context: Context) -> ChatAvatarControl {
        let control = ChatAvatarControl(type: .custom)
        control.drawsFace = false
        return control
    }
    func updateUIView(_ button: ChatAvatarControl, context: Context) {
        button.configure(chat: chat, app: app, large: large,
                         style: context.environment.colorScheme == .dark ? .dark : .light)
    }
    static func dismantleUIView(_ button: ChatAvatarControl, coordinator: ()) { button.retire() }
}

final class ChatAvatarControl: UIButton {
    private let artwork = UIView()
    private let face = CAShapeLayer()
    private let sparkle = UIImageView()
    private var artworkSize = Metrics.Chats.faceArt
    private var onOpen: (() -> Void)?
    private var generation: UUID?
    /// Off when SwiftUI draws the face under it (ChatAvatar): it only takes the touch.
    var drawsFace = true {
        didSet { artwork.isHidden = !drawsFace; setNeedsLayout() }
    }

    /// The circle under the drawing: #f1f1f3 in the header, white in Info.
    static func fill(large: Bool) -> UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark { return large ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.2, alpha: 1) }
            return large ? .white : UIColor(red: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF3 / 255, alpha: 1)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        artwork.isUserInteractionEnabled = false; artwork.isAccessibilityElement = false
        artwork.layer.addSublayer(face); addSubview(artwork)
        face.fillColor = nil; face.lineCap = .round; face.lineJoin = .round
        sparkle.image = UIImage(named: GlyphName.sparkle.rawValue)?.withRenderingMode(.alwaysTemplate)
        sparkle.contentMode = .scaleAspectFit; sparkle.isUserInteractionEnabled = false
        sparkle.isAccessibilityElement = false; artwork.addSubview(sparkle)
        accessibilityIdentifier = "chat.face"; accessibilityLabel = "Chat Info"
        addTarget(self, action: #selector(openInfo), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { return nil }

    override var isHighlighted: Bool {
        didSet {
            artwork.alpha = isHighlighted ? 0.55 : 1
            if !drawsFace { backgroundColor = isHighlighted ? UIColor.white.withAlphaComponent(0.3) : .clear }
        }
    }

    func configure(chat: Chat, app: AppModel, large: Bool, style: UIUserInterfaceStyle) {
        overrideUserInterfaceStyle = style
        artworkSize = large ? Metrics.Chats.infoFaceArt : Metrics.Chats.faceArt
        backgroundColor = drawsFace ? Self.fill(large: large) : .clear
        face.isHidden = chat.by == .iphone; sparkle.isHidden = chat.by != .iphone
        face.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        sparkle.tintColor = .label
        let id = chat.id
        let currentGeneration = app.chatSheet.navigationGeneration
        if generation != currentGeneration { cancelTracking(with: nil) }
        generation = currentGeneration
        let fresh = app.chatSheet.fresh.contains(id)
        isEnabled = !fresh; isUserInteractionEnabled = !large
        accessibilityTraits = large ? [.image] : [.button]
        onOpen = large ? nil : { [weak app] in
            guard let app, app.chatSheet.navigationGeneration == currentGeneration,
                  ChatNativeMenu.isCurrentConversation(id, app: app), !app.chatSheet.fresh.contains(id) else { return }
            app.openChatInfo()
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        face.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        let rect = CGRect(x: (bounds.width - artworkSize) / 2, y: (bounds.height - artworkSize) / 2,
                          width: artworkSize, height: artworkSize)
        artwork.frame = rect; bringSubviewToFront(artwork)
        // The sparkle has no circle of its own: two thirds of the drawing.
        sparkle.frame = artwork.bounds.insetBy(dx: artworkSize / 6, dy: artworkSize / 6)
        face.frame = artwork.bounds
        let k = artworkSize / 24
        let path = UIBezierPath(ovalIn: CGRect(x: 3 * k, y: 3 * k, width: 18 * k, height: 18 * k))
        path.move(to: CGPoint(x: 9.5 * k, y: 9.75 * k)); path.addLine(to: CGPoint(x: 9.5 * k, y: 12.25 * k))
        path.move(to: CGPoint(x: 14.5 * k, y: 9.75 * k)); path.addLine(to: CGPoint(x: 14.5 * k, y: 12.25 * k))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.path = path.cgPath; face.lineWidth = 2 * k
        CATransaction.commit()
    }

    @objc private func openInfo() { onOpen?() }
    func retire() { onOpen = nil; removeTarget(self, action: #selector(openInfo), for: .touchUpInside) }
}
