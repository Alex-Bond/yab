import SwiftUI
import UIKit

/// A chat's icon in its 34 round (or, for tasks, rounded square) box: the
/// model's mark (Apple Intelligence for chats only this iPhone answered),
/// Yab's folder for tasks.
struct ChatRowIcon: View {
    let chat: Chat
    /// Its box: 34 on a card, 44 on a project's row (Messages' size).
    var box: CGFloat = Metrics.Chats.rowIconBox

    var body: some View {
        let mark = box * 20 / 34
        if chat.task != nil || chat.taskLike {
            FolderIcon(open: false, size: FolderIcon.slot(box * 18 / 34), variant: .task)
                .frame(width: box, height: box)
                .background(ChatInk.fill(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            // The model's own mark, as the Mac's chat list draws it.
            Image(brand)
                .renderingMode(.template)
                .resizable()
                .frame(width: mark, height: mark)
                .foregroundStyle(ChatInk.gray(0.62))
                .frame(width: box, height: box)
                .background(ChatInk.fill(0.08), in: Circle())
                .accessibilityHidden(true)
        }
    }

    /// Claude, ChatGPT, or Apple Intelligence on this iPhone.
    private var brand: String {
        if onlyThisIPhone || chat.by == .iphone { return "BrandAppleIntelligence" }
        return chat.macCLI == "codex" ? "BrandOpenAI" : "BrandClaude"
    }

    /// Answered only by the model on this iPhone so far.
    private var onlyThisIPhone: Bool {
        chat.messages.contains { $0.by == .iphone && $0.role == .answer }
            && !chat.messages.contains { $0.by == .claude || $0.role == .pick }
    }
}

enum Rubber {
    /// The prototype's rubber band: sign(x) × (1 - 1 / (|x| × .55 / d + 1)) × d.
    static func band(_ x: CGFloat, _ d: CGFloat) -> CGFloat {
        let s: CGFloat = x < 0 ? -1 : 1
        return s * (1 - 1 / (abs(x) * 0.55 / d + 1)) * d
    }
}

extension Motion {
    /// A swiped row's capsule growing to the whole width past the threshold
    /// (History's rows).
    static let swipeCapsule = easeOut("swipeCapsule", 0.25)
}

/// A vertical pan on the sheet: an answer pulled up follows toward the chat,
/// let go past a quarter (or flicked up) it is the chat; pulled down 90
/// (or flicked down) it folds into the Now line.
struct SheetDrag: UIGestureRecognizerRepresentable {
    let app: AppModel
    var presentationPose: SheetPose?

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let controller = context.coordinator.controller
        let moved = recognizer.translation(in: recognizer.view)
        let dy = moved.y
        switch recognizer.state {
        case .began: controller.begin(pose: presentationPose ?? app.chatSheet.pose)
        case .changed: controller.move(dy, dx: moved.x)
        case .ended: controller.end(dy, velocity: recognizer.velocity(in: recognizer.view).y, cancelled: false)
        case .cancelled, .failed: controller.end(dy, velocity: 0, cancelled: true)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(app: app) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var app: AppModel?
        let controller: ChatSheetPan
        init(app: AppModel) {
            self.app = app; controller = ChatSheetPan(app: app)
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let app, let pan = gesture as? UIPanGestureRecognizer,
                  app.chatSheet.shown, !app.chatSheet.info, !app.privateContentBlocked else { return false }
            let v = pan.velocity(in: pan.view)
            // A chat is left by ‹ or a finger from its left edge; in its
            // cover, UIKit's own pull down takes it, so its head never claims one.
            if app.chatSheet.mode == .chat { return false }
            return abs(v.y) > abs(v.x)
        }
    }
}

/// The native header pan changes the same pose and retained viewport. Navigation
/// commits only on an ended gesture owned by the route that began it.
@MainActor
final class ChatSheetPan {
    private weak var app: AppModel?
    private struct Start {
        let generation: UUID
        let chat: Chat.ID?
        let mode: ChatSheet.Mode
        let pose: SheetPose
        let targetPose: SheetPose
    }
    private var start: Start?
    init(app: AppModel) { self.app = app }

    func begin(pose: SheetPose) {
        guard let app, app.chatSheet.shown, !app.chatSheet.info,
              !app.chatSheet.moreMenu, app.chatSheet.renaming == nil, app.chatSheet.deleting == nil,
              !app.privateContentBlocked, !app.privateLock.presentsPrompt,
              // A chat takes no vertical pull; only an answer is pulled.
              app.chatSheet.mode == .answer else { start = nil; return }
        let sheet = app.chatSheet
        start = Start(generation: sheet.navigationGeneration, chat: sheet.chatID,
                      mode: sheet.mode, pose: pose, targetPose: sheet.pose)
    }

    private var current: (AppModel, Start)? {
        guard let app, let start else { return nil }
        let sheet = app.chatSheet
        guard sheet.shown, !sheet.info, !sheet.moreMenu, sheet.renaming == nil, sheet.deleting == nil,
              !app.privateContentBlocked, !app.privateLock.presentsPrompt,
              sheet.navigationGeneration == start.generation, sheet.chatID == start.chat,
              sheet.mode == start.mode, sheet.pose.e < 0.001 else { return nil }
        return (app, start)
    }

    func move(_ dy: CGFloat, dx: CGFloat = 0) {
        guard dy.isFinite, let (app, start) = current else { return }
        let sheet = app.chatSheet
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) {
            if start.mode == .answer && dy < 0 {
                let span = max(1, app.screenSize.height - Metrics.Edge.sheet - CGFloat(start.pose.h) - Metrics.Chat.standSlack)
                sheet.pose.t = SheetGeometry.clamp(start.pose.t - Double(dy / span)); sheet.pose.drag = 0
            } else {
                sheet.pose.drag = start.pose.drag + Double(max(0, dy))
            }
            app.syncBehind()
        }
    }

    func end(_ dy: CGFloat, velocity: CGFloat, cancelled: Bool) {
        defer { start = nil }
        guard dy.isFinite, velocity.isFinite, let (app, start) = current else { return }
        let sheet = app.chatSheet
        if cancelled {
            Motion.sheetDragBack.run { sheet.pose.t = start.targetPose.t; sheet.pose.drag = start.targetPose.drag; app.syncBehind() }
            return
        }
        if start.mode == .answer && dy < 0 {
            if sheet.pose.t > Metrics.Chat.standShare || velocity < -Metrics.Chat.standVelocity { app.expand(velocity: velocity) }
            else { Motion.answerBack.run { sheet.pose.t = start.targetPose.t; sheet.pose.drag = start.targetPose.drag; app.syncBehind() } }
        } else if dy > Metrics.Chat.hideDistance || velocity > Metrics.Chat.hideVelocity {
            app.park()
        } else {
            Motion.sheetDragBack.run { sheet.pose.t = start.targetPose.t; sheet.pose.drag = start.targetPose.drag; app.syncBehind() }
        }
    }
}
