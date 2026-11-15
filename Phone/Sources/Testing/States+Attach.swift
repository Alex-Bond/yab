import SwiftUI
import UIKit

/// Photos and files with your words, and the model for them (Chats/AttachTray,
/// Chats/ChatAttachments), in the cafe chat on a stand-in Mac:
/// attach.1–8 the Add to Chat tray (the camera not asked yet, live, off in
/// Settings, missing; the system's Photos picker over the chat; Model,
/// Reasoning, a Mac with no models);
/// attach.9–14 the field (a Mac that takes no files, empty, words, two photos
/// and a file, a file alone, long words and photos); attach.15 sent.
extension StateCatalog {
    static let attach: [NamedState] = [
        tray("attach.1", "Tray: camera not asked", "Add to Chat: Camera, Photos, Files, three cards of one size; a Model and Reasoning card.",
             camera: .notDetermined),
        tray("attach.2", "Tray: live camera", "The camera's card shows what it sees; Photos and Files beside it.", camera: .authorized),
        tray("attach.3", "Tray: camera off", "Camera off in Settings: the same three cards, no alarms.", camera: .denied),
        tray("attach.4", "Tray: no camera", "No camera, as in a simulator: the same three cards.", camera: .unavailable),
        NamedState("attach.5", "Photos: the system's picker", "Photos tapped: the tray goes and the system's picker stands over the chat.") { app in
            reset()
            await openCafe(app)
            app.openAttachTray()
            await pause(500)
            app.attachTrayHandOver { $0.attachLibrary = true }
            await pause(1500)
        },
        tray("attach.6", "Tray: model", "Default, Claude and ChatGPT in groups, a checkmark on the picked one; ‹ instead of ×.", page: .model,
             pick: ModelChoice(cli: "claude", model: "opus", effort: "high")),
        tray("attach.7", "Tray: reasoning", "Auto and Claude Opus efforts: Low … Max, a checkmark on High.", page: .reasoning,
             pick: ModelChoice(cli: "claude", model: "opus", effort: "high")),
        tray("attach.8", "Tray: Mac without models", "No Model card: the Mac doesn't name any.", models: false),
        field("attach.9", "Mac without files", "No +: the field as it was.", attachments: false, words: ""),
        field("attach.10", "Empty field", "+ inside the field, one line, 44 tall.", words: ""),
        field("attach.11", "Field with words", "+ · words · Send on one line.", words: "which of these fits the menu?"),
        field("attach.12", "Two photos and a file", "Two lines: the words, under them + · chips · Send.", words: "which of these fits the menu?", files: [1, 4, -1]),
        field("attach.13", "Only a file", "Two lines, no words, Send lit.", words: "", files: [-1]),
        field("attach.14", "Long words and photos", "Words over several lines above + · chips · Send; the turns moved up.",
              words: "compare the light in these two photos with the autumn menu and tell me which one fits the window display better, and why",
              files: [1, 4]),
        NamedState("attach.15", "Sent with files", "Photos and a PDF over my bubble, then the answer.") { app in
            reset()
            await openCafe(app)
            guard let id = app.chatSheet.chatID else { return }
            let files = waiting([1, 4, -1])
            for file in files { if let picture = file.thumbnail { ChatThumbs.keep(picture, digest: file.digest) } }
            app.chats.update(id) { chat in
                chat.messages.append(Message(role: .you, text: "which of these fits the menu?", files: files.map(\.file)))
                chat.messages.append(Message(role: .answer, text: "The second one: the warm light suits the autumn menu, and the PDF's prices fit it.", by: .claude))
            }
            await pause(300)
        },
    ]

    private static func tray(_ name: String, _ title: String, _ note: String, camera: AttachCamera.Status = .authorized,
                             page: AttachPage = .main, pick: ModelChoice? = nil, models: Bool = true) -> NamedState {
        NamedState(name, title, note) { app in
            reset()
            AttachStandIns.camera = camera
            AttachStandIns.models = models
            await openCafe(app)
            guard let id = app.chatSheet.chatID else { return }
            if let pick { app.chatSheet.picks[id] = pick }
            app.openAttachTray()
            await pause(300)
            if page != .main { app.attachTrayPage(page) }
            await pause(700)
        }
    }

    private static func field(_ name: String, _ title: String, _ note: String, attachments: Bool = true,
                              words: String, files: [Int] = []) -> NamedState {
        NamedState(name, title, note) { app in
            reset()
            AttachStandIns.attachments = attachments
            await openCafe(app)
            guard let id = app.chatSheet.chatID else { return }
            app.chatSheet.attached[id] = waiting(files)
            app.chatSheet.draft = words
            await pause(400)
        }
    }

    @MainActor private static func reset() {
        AttachStandIns.attachments = true
        AttachStandIns.models = true
        AttachStandIns.photos = (0..<10).map(photo)
        AttachStandIns.camera = .notDetermined
    }

    @MainActor private static func openCafe(_ app: AppModel) async {
        app.openChat("cafe")
        await pause(400)
    }

    private static func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// Photos by their stand-in number, -1 a PDF, made as a person's would be.
    @MainActor private static func waiting(_ which: [Int]) -> [ChatAttachment] {
        which.compactMap { n in
            if n < 0 {
                return ChatAttachment(upload: SendUpload(name: "Autumn menu, final prices.pdf", type: "application/pdf",
                                                         data: Data(repeating: 0x25, count: 182_400)), thumbnail: nil)
            }
            return photo(n).jpegData(compressionQuality: 0.9).flatMap { AttachmentPrep.photo($0, name: "IMG_\(4210 + n).HEIC") }
        }
    }

    /// A stand-in photo: a sky, a sun and hills, each in its own light.
    private static func photo(_ n: Int) -> UIImage {
        let skies: [(UIColor, UIColor)] = [
            (.systemOrange, .systemPink), (.systemTeal, .systemBlue), (.systemYellow, .systemOrange), (.systemIndigo, .systemPurple),
            (.systemMint, .systemTeal), (.systemPink, .systemPurple), (.systemCyan, .systemIndigo), (.systemRed, .systemOrange),
        ]
        let (top, bottom) = skies[n % skies.count]
        let size = CGSize(width: 600, height: n % 3 == 1 ? 800 : 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.85).setFill()
            let sun = CGFloat(70 + 15 * (n % 3))
            cg.fillEllipse(in: CGRect(x: size.width * (0.25 + 0.1 * CGFloat(n % 4)), y: size.height * 0.22, width: sun, height: sun))
            for (i, shade) in [0.35, 0.55].enumerated() {
                UIColor.black.withAlphaComponent(shade).setFill()
                let path = UIBezierPath()
                let base = size.height * (0.62 + 0.12 * CGFloat(i))
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: base))
                path.addQuadCurve(to: CGPoint(x: size.width, y: base + 30), controlPoint: CGPoint(x: size.width * (0.3 + 0.2 * CGFloat(i + n % 2)), y: base - 140))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.close()
                path.fill()
            }
        }
    }
}
