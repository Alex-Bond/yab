import SwiftUI
#if canImport(SyncKit)
import SyncKit
#endif

/// A row grown into a window where it lay, to be read whole (Amber's card
/// into its window): the window's rect goes from the row's, wherever the row
/// is this frame, to under the status bar, and its words, laid out at full
/// size from the first frame, are cut by its growing edge while the row's
/// face fades over the first third. Sideways goes to the next item; down
/// from the top of the words folds it back into the row of the item open
/// now. Its button stands where the tray's does.
struct ApprovalWindow: View {
    let tray: ApprovalTray
    let content: ApprovalContent
    let geometry: ApprovalGeometry
    private typealias M = ApprovalMetrics

    var body: some View {
        let p = tray.win
        let open = geometry.windowRect
        let from = geometry.windowFromRect ?? open
        let rect = geometry.windowNow
        let scale = geometry.windowScale
        let fromRadius: CGFloat = tray.windowFrom == "tray:paper" ? M.group : 0
        let radius = geometry.lerp(fromRadius, M.radius, min(1, max(0, p)))
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let face = geometry.windowGhost
        ZStack(alignment: .topLeading) {
            inner(open)
                .frame(width: open.width, height: open.height, alignment: .topLeading)
                .opacity(geometry.windowWords)
            ghost(from: from)
                .opacity(face)
                .allowsHitTesting(false)
        }
        .frame(width: max(1, rect.width), height: max(1, rect.height), alignment: .topLeading)
        // Clear at first, over the row it is: the row's own ground shows
        // through, so the first frame is the row exactly.
        .background(Ink.card.opacity(geometry.windowGround))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.2 * Double(min(1, max(0, p)))), radius: 30, y: 10)
        .scaleEffect(scale, anchor: .top)
        .position(x: rect.midX, y: rect.midY)
        .opacity(tray.windowFade)
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(ApprovalGeometry.screenSpace))
                .onChanged { tray.windowDragChanged($0.translation) }
                .onEnded { tray.windowDragEnded($0.translation, velocity: $0.velocity) }
        )
        .allowsHitTesting(tray.windowOpen && tray.pictureFile == nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.window")
        .accessibilityAddTraits(.isModal)
    }

    /// The row's own face, at the row's size, at the window's top-left.
    @ViewBuilder
    private func ghost(from: CGRect) -> some View {
        if let index = tray.windowItem, let item = content.items[safe: index] {
            Group {
                if tray.windowFrom == "tray:paper" {
                    ApprovalPaper(mail: item.mail)
                } else {
                    ApprovalRow(item: item)
                }
            }
            .frame(width: from.width, height: from.height, alignment: .topLeading)
        }
    }

    private func inner(_ open: CGRect) -> some View {
        let items = content.items
        let index = tray.windowPage
        let item = items[safe: index]
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { tray.foldWindow() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .frame(width: M.close, height: M.close)
                        .background(ChatInk.fill(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("approval.window.fold")
                Spacer(minLength: 0)
                VStack(spacing: 1) {
                    if items.count > 1 {
                        Text("\(index + 1) of \(items.count)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Ink.primary)
                    }
                    Text(item.map { $0.mail?.date == nil ? "To \($0.title)" : $0.title } ?? "")
                        .font(.system(size: 12)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Color.clear.frame(width: M.close, height: M.close)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .frame(height: M.header)
            GeometryReader { viewport in
                let width = viewport.size.width
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        // Only the page in view and its neighbors are built:
                        // a list of fourteen opens as fast as one of three.
                        if abs(CGFloat(i) - tray.page) < 1.6 {
                            ApprovalMailPage(tray: tray, item: item, index: i)
                                .frame(width: width, alignment: .topLeading)
                                .offset(y: i == index ? -tray.scroll : 0)
                                .frame(width: width, height: viewport.size.height, alignment: .topLeading)
                                .clipped()
                        } else {
                            Color.clear.frame(width: width, height: viewport.size.height)
                        }
                    }
                }
                .offset(x: -tray.page * width)
                .onAppear {
                    tray.windowViewportWidth = width
                    tray.windowViewport = viewport.size.height
                }
                .onChange(of: viewport.size) { _, size in
                    tray.windowViewportWidth = size.width
                    tray.windowViewport = size.height
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                ApprovalFooter(tray: tray, content: content)
                    .background(
                        LinearGradient(colors: [Ink.card.opacity(0), Ink.card], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3))
                    )
            }
        }
    }
}

/// One mail as it will go, or as it came: who, the subject, every word,
/// its files, each opening full screen.
struct ApprovalMailPage: View {
    @Environment(AppModel.self) private var app
    let tray: ApprovalTray
    let item: ApprovalContent.Item
    let index: Int

    var body: some View {
        let mail = item.mail
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                let from = mail?.from?.name ?? "You"
                Text(ApprovalContent.initials(from))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(ApprovalContent.tint(from), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(from).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.primary)
                    Text("to " + (mail?.to.map(ApprovalContent.named).joined(separator: ", ") ?? ""))
                        .font(.system(size: 14)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(2)
                    if let cc = mail?.cc, !cc.isEmpty {
                        Text("cc " + cc.map(\.name).joined(separator: ", ")).font(.system(size: 14)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(1)
                    }
                    // Whom it also goes to unseen: shown, since the yes sends there too.
                    if let bcc = mail?.bcc, !bcc.isEmpty {
                        Text("bcc " + bcc.map(ApprovalContent.named).joined(separator: ", "))
                            .font(.system(size: 14)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(2)
                            .accessibilityIdentifier("approval.window.bcc")
                    }
                }
                Spacer(minLength: 0)
                Text(mail?.date.map { ApprovalWindowWords.date($0) } ?? "Draft")
                    .font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.6))
            }
            .padding(.top, 6)
            .padding(.bottom, 14)
            Text(mail?.subject ?? item.subtitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Text(mail?.body ?? item.snippet)
                .font(.system(size: 17))
                .lineSpacing(3)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let files = mail?.files, !files.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(files) { file in
                        let key = "win:att.\(item.id).\(file.id)"
                        HStack(spacing: 10) {
                            ApprovalPage(file: file, image: tray.request.flatMap { app.sync.assistantPreview($0, file: file.id, page: 0) })
                                .frame(width: 36, height: 46)
                                .opacity(tray.pictureFile?.id == file.id ? 0 : 1)
                                .trayFrame(tray, key)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.primary).lineLimit(1)
                                Text(ApprovalWords.size(file)).font(.system(size: 12)).foregroundStyle(ChatInk.gray(0.6))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(ChatInk.fill(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { tray.openPicture(file, key: key) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("approval.attachment.\(file.id)")
                    }
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, 20)
        // Room under the words for the button that stands over them.
        .padding(.bottom, 120)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if index == tray.windowPage { tray.windowContent = h }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.window.page.\(index)")
    }
}

enum ApprovalWindowWords {
    static func date(_ seconds: Double) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        let format = Calendar.current.isDateInToday(date) ? Date.FormatStyle(date: .omitted, time: .shortened) : Date.FormatStyle().month(.abbreviated).day()
        return date.formatted(format)
    }
}

// MARK: - a file's page full screen

/// A file's page grown out of its thumbnail (Amber's picture viewer): the
/// black comes in with it, a pull down sends it back.
struct ApprovalPicture: View {
    @Environment(AppModel.self) private var app
    let tray: ApprovalTray
    let file: AssistantApprovalRecords.Detail.File
    let geometry: ApprovalGeometry

    var body: some View {
        let p = tray.picture
        let drag = tray.pictureDrag
        let shown = geometry.pictureNow(fit: ApprovalPicture.fit(file, geometry))
        let black = geometry.pictureBlack
        ZStack(alignment: .topLeading) {
            Color.black.opacity(black)
                .ignoresSafeArea()
                .onTapGesture { tray.closePicture() }
            ApprovalPage(file: file, image: tray.request.flatMap { app.sync.assistantPreview($0, file: file.id, page: 0) })
                .frame(width: max(1, shown.width), height: max(1, shown.height))
                .clipShape(RoundedRectangle(cornerRadius: geometry.lerp(6, file.kind == "image" ? 0 : 4, p), style: .continuous))
                .position(x: shown.midX, y: shown.midY)
                .allowsHitTesting(false)
            HStack {
                Button { tray.closePicture() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Color.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("approval.picture.close")
                Spacer()
                Text(file.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 16)
            .padding(.top, geometry.safeTop + 6)
            .opacity(Double(max(0, (p - 0.6) / 0.4)) * (drag > 4 ? 0 : 1))
        }
        .opacity(tray.pictureFade)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { tray.pictureDragChanged($0.translation.height) }
                .onEnded { tray.pictureDragEnded($0.translation.height, velocity: $0.velocity.height) }
        )
        .allowsHitTesting(tray.pictureOpen)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.picture")
    }

    /// The page as large as the screen takes it, between the status bar and the bottom.
    static func fit(_ file: AssistantApprovalRecords.Detail.File, _ geometry: ApprovalGeometry) -> CGRect {
        let screen = geometry.screen
        let aspect: CGFloat = {
            if let w = file.width, let h = file.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
            return file.kind == "image" ? 1 : 8.5 / 11
        }()
        let top = geometry.safeTop + 56, bottom: CGFloat = 40
        let width = min(screen.width - 32, (screen.height - top - bottom) * aspect)
        let height = width / aspect
        return CGRect(x: (screen.width - width) / 2, y: top + (screen.height - top - bottom - height) / 2, width: width, height: height)
    }
}
