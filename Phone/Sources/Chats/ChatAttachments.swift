import ImageIO
import PhotosUI
import SwiftUI
import SyncKit
import UIKit
import UniformTypeIdentifiers

// Photos and files with your words, for a chat whose Mac takes them
// (SyncSendFile.capability): + left of the field opens "Add to Chat" (as
// Sophon's composer sheet: the camera, Photos (the system's picker), Attach
// file), what is picked waits over the words in the field, and
// it goes as `sendpart` records before the send (PhoneSync.send).

/// A photo or file waiting in the field, its bytes ready to go.
struct ChatAttachment: Identifiable, Equatable, @unchecked Sendable {
    let id = UUID()
    var upload: SendUpload
    /// A photo's picture, for the field and its bubble.
    var thumbnail: UIImage?
    let digest: String

    init(upload: SendUpload, thumbnail: UIImage?) {
        self.upload = upload
        self.thumbnail = thumbnail
        digest = SyncSendFile.hex(upload.data)
    }

    var file: Message.File { .init(name: upload.name, type: upload.type, size: upload.data.count, digest: digest) }

    static func == (a: ChatAttachment, b: ChatAttachment) -> Bool { a.id == b.id }
}

/// Bytes made ready to go: a photo as a JPEG of at most 2048 points on its
/// long side at quality 0.8 (HEIC too), a file as it is.
nonisolated enum AttachmentPrep {
    static let longSide = 2048
    static let quality = 0.8
    static let thumbSide = 360

    enum Failure: Error { case unreadable }

    /// A photo's bytes as they go: downscaled, oriented, a JPEG.
    static func photo(_ data: Data, name: String) -> ChatAttachment? {
        guard let jpeg = jpeg(data) else { return nil }
        let base = ((name as NSString).deletingPathExtension as NSString).lastPathComponent
        let upload = SendUpload(name: (base.isEmpty ? "Photo" : base) + ".jpg", type: "image/jpeg", data: jpeg)
        return ChatAttachment(upload: upload, thumbnail: thumbnail(jpeg))
    }

    /// The camera's picture.
    static func camera(_ image: UIImage) -> ChatAttachment? {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return photo(data, name: "Photo \(stamp)")
    }

    /// A file from Files, as it is; too big a file isn't read at all.
    static func file(at url: URL) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > SyncSendFile.most {
            throw SendUpload.Failure.tooBig
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure.unreadable }
        if data.count > SyncSendFile.most { throw SendUpload.Failure.tooBig }
        let kind = UTType(filenameExtension: url.pathExtension)
        let type = kind?.preferredMIMEType ?? "application/octet-stream"
        let picture = kind?.conforms(to: .image) == true ? thumbnail(data) : nil
        return ChatAttachment(upload: SendUpload(name: url.lastPathComponent, type: type, data: data), thumbnail: picture)
    }

    static func jpeg(_ data: Data) -> Data? {
        guard let image = scaled(data, side: longSide) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    static func thumbnail(_ data: Data) -> UIImage? {
        scaled(data, side: thumbSide).map { UIImage(cgImage: $0) }
    }

    /// At most `side` pixels on the long side, never larger than it was,
    /// turned the way it was taken.
    static func scaled(_ data: Data, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Pictures of photos sent from here, by their digest: the bubble shows
/// them after the send, and after the Mac's turn takes its place.
@MainActor
enum ChatThumbs {
    private static var memory: [String: UIImage] = [:]

    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ChatFiles", isDirectory: true)
    }

    static func keep(_ image: UIImage, digest: String) {
        memory[digest] = image
        let dir = folder
        let url = dir.appendingPathComponent(digest + ".jpg")
        let data = image.jpegData(compressionQuality: 0.8)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data?.write(to: url, options: .atomic)
        }
    }

    /// Only what this run already holds: for a first frame, no disk.
    static func inMemory(_ digest: String) -> UIImage? { memory[digest] }

    /// The picture, read from disk off the main thread when not in memory.
    static func load(_ digest: String) async -> UIImage? {
        if let image = memory[digest] { return image }
        let url = folder.appendingPathComponent(digest + ".jpg")
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
        if let image { memory[digest] = image }
        return image
    }

    static func image(_ digest: String) -> UIImage? {
        if let image = memory[digest] { return image }
        guard let image = UIImage(contentsOfFile: folder.appendingPathComponent(digest + ".jpg").path) else { return nil }
        memory[digest] = image
        return image
    }
}

// MARK: - in the field

/// + inside the field, as the Mac's: a quiet round 32, stronger while the
/// tray it opened is up.
struct FieldPlus: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let open = app.chatSheet.attachMenu
        Button { app.openAttachTray() } label: {
            ChatGlyph(.plusMedium, size: 16, color: ChatInk.gray(open ? 0.9 : 0.62))
                .frame(width: Metrics.Chats.fieldButton, height: Metrics.Chats.fieldButton)
                .background(ChatInk.fill(open ? 0.22 : 0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // The tray grows out of it, and goes back into it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.chatSheet.attachOrigin = $0 }
        .accessibilityIdentifier("chat.attach")
        .accessibilityLabel("Add Photos and Files")
    }
}

/// A photo or file going with the words, as the Mac's ChatFileChip: its
/// picture (or a document's mark), its name, its size, and × to leave it.
struct FieldChip: View {
    let item: ChatAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let picture = item.thumbnail {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .frame(width: 22, height: 22)
            }
            Text(item.upload.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 118, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.upload.data.count), countStyle: .file))
                .foregroundStyle(ChatInk.gray(0.55))
                .lineLimit(1)
                .fixedSize()
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .frame(width: 22, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.attachment.remove")
            .accessibilityLabel("Don\u{2019}t send \(item.upload.name)")
        }
        .font(.system(size: 13))
        .foregroundStyle(Ink.primary.opacity(0.8))
        .padding(.leading, item.thumbnail == nil ? 4 : 4)
        .frame(height: Metrics.Chats.fieldChip)
        .background(ChatInk.fill(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.attachment")
    }
}

// MARK: - in your bubble

/// Photos and files sent with your words, over their bubble: a photo as
/// itself, a file (or a photo whose picture isn't kept here) as a chip.
struct SentFiles: View {
    let files: [Message.File]

    var body: some View {
        let pictures = files.compactMap { file in file.isImage ? ChatThumbs.image(file.digest).map { (file, $0) } : nil }
        let chips = files.filter { file in !pictures.contains { $0.0 == file } }
        VStack(alignment: .trailing, spacing: 4) {
            if pictures.count == 1, let only = pictures.first {
                Image(uiImage: only.1)
                    .resizable()
                    .aspectRatio(only.1.size, contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel(only.0.name)
            } else if !pictures.isEmpty {
                // Two to a row, the last row's odd one at the right, as yours stand.
                let rows = stride(from: 0, to: pictures.count, by: 2).map { Array(pictures[$0..<min($0 + 2, pictures.count)]) }
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(rows[row], id: \.0.digest) { file, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 108, height: 108)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .accessibilityLabel(file.name)
                        }
                    }
                }
            }
            ForEach(chips, id: \.digest) { file in
                HStack(spacing: 10) {
                    Image(systemName: file.isImage ? "photo" : "doc.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(ChatInk.fill(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                            .font(.system(size: 13))
                            .foregroundStyle(ChatInk.gray(0.6))
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 14)
                .padding(.vertical, 8)
                .background(ChatInk.fill(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("chat.sentFiles")
    }
}

/// A row of Now handed to the agent on the Mac (Do It), over your "Do It",
/// read top down as the Mac's chat has it (HandedCard there): where it came
/// from (the site's mark, "Gmail · From Now"), the row's words, the gray
/// line under them, every line on one edge; 12 in, corners of 20.
struct HandedCard: View {
    let handed: Message.Handed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Favicon(icon: handed.host.isEmpty ? "mail" : handed.host, host: handed.host.isEmpty ? nil : handed.host, size: 16)
                Text(handed.from)
                    .font(.system(size: 12))
                    .foregroundStyle(ChatInk.gray(0.45))
                    .lineLimit(1)
            }
            Text(handed.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            if !handed.detail.isEmpty {
                Text(handed.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(Ink.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.outline.opacity(0.08), lineWidth: 0.5))
        .shadow(color: Ink.shadow.opacity(0.06), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.handed")
    }
}

// MARK: - the camera

/// The system's camera, full screen; the picture comes back as an image.
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (UIImage?) -> Void
        init(onPicked: @escaping (UIImage?) -> Void) { self.onPicked = onPicked }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPicked(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onPicked(nil) }
    }
}

// MARK: - the flow

extension AppModel {
    /// + shows for a chat whose Mac takes photos and files; never for a
    /// private chat or a task's.
    func canAttach(_ id: Chat.ID) -> Bool {
        guard let chat = chats.chat(id), chat.task == nil, !chats.isPrivate(id) else { return false }
        if isFixture { return AttachStandIns.attachments }
        return sync.canAttach(id)
    }

    /// Ready bytes into the chat's field; past the limits, said and left out.
    func attach(_ items: [ChatAttachment], to id: Chat.ID) {
        guard !items.isEmpty else { return }
        let sheet = chatSheet
        var all = sheet.attached[id] ?? []
        var refused: SendUpload.Failure?
        for item in items {
            if let failure = SendUpload.check((all + [item]).map(\.upload.data.count)) { refused = refused ?? failure; continue }
            all.append(item)
        }
        if Motion.disabled { sheet.attached[id] = all } else { withAnimation(.snappy(duration: 0.2)) { sheet.attached[id] = all } }
        if let refused { say(refused.localizedDescription, glyph: .exclamationCircle) }
    }

    func unattach(_ item: ChatAttachment, from id: Chat.ID) {
        let sheet = chatSheet
        let gone = { sheet.attached[id]?.removeAll { $0.id == item.id } }
        if Motion.disabled { gone() } else { withAnimation(.snappy(duration: 0.2)) { gone() } }
    }

    /// Photos from the system's picker (Photos not allowed to be read).
    func attachPicked(_ items: [PhotosPickerItem], to id: Chat.ID) {
        Task { @MainActor in
            var ready: [ChatAttachment] = []
            for (n, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                if let made = await Task.detached(operation: { AttachmentPrep.photo(data, name: "Photo \(n + 1)") }).value { ready.append(made) }
            }
            if ready.count < items.count { self.say("Some photos couldn’t be read", glyph: .exclamationCircle) }
            self.attach(ready, to: id)
        }
    }

    /// Files from Files, as they are.
    func attachFiles(_ urls: [URL], to id: Chat.ID) {
        Task { @MainActor in
            var ready: [ChatAttachment] = []
            var refused: Error?
            for url in urls {
                do { ready.append(try await Task.detached(operation: { try AttachmentPrep.file(at: url) }).value) }
                catch { refused = refused ?? error }
            }
            self.attach(ready, to: id)
            if let refused {
                self.say((refused as? SendUpload.Failure)?.localizedDescription ?? "That file couldn’t be read", glyph: .exclamationCircle)
            }
        }
    }

    func attachCamera(_ image: UIImage, to id: Chat.ID) {
        Task { @MainActor in
            guard let item = await Task.detached(operation: { AttachmentPrep.camera(image) }).value else { return }
            self.attach([item], to: id)
        }
    }

    /// A chat whose first message is only files is named after them.
    static func filesTitle(_ files: [Message.File]) -> String {
        if files.count == 1, let file = files.first { return file.isImage ? "Photo" : file.name }
        return files.allSatisfy(\.isImage) ? "\(files.count) Photos" : "\(files.count) Files"
    }
}
