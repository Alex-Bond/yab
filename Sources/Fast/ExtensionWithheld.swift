import AppKit
import SwiftUI

// iCloud Passwords' button while macOS kills Apple's helper for Yab
// (docs/evidence/icloud-passwords-2026-10-08.md): the extension's own popup
// would only ask for a code no helper will ever show, so a popover of the
// browser's own hangs from the button in its place, saying why, with the
// extension's page in Settings a press away. It hangs and goes as the popup
// would (ExtensionPopup): from the button, or taking over the extensions
// list's popover it was pressed in, and a second press on the button closes
// it. Signed with Apple's entitlement, none of this is reached.

@available(macOS 15.4, *)
@MainActor
final class ExtensionWithheld: NSObject, NSPopoverDelegate {
    static let shared = ExtensionWithheld()

    private var popover: NSPopover?
    private(set) var extensionID: String?
    /// The extension's own button, when the popover hangs from it.
    private weak var button: NSView?
    /// Closed by a click on its own button: the popover goes on that
    /// click's mouse-down, and the button's press comes after, on its
    /// mouse-up, which would open it again.
    private var closedByButton: (id: String, at: Date)?

    var isShown: Bool { popover?.isShown == true }

    /// For the bench: what is up, and its window, for a picture of it.
    var state: [String: Any] {
        ["shown": isShown, "id": extensionID ?? "",
         "window": popover?.contentViewController?.view.window?.windowNumber ?? 0]
    }

    /// `taken`: the extensions list's popover, already up, which this takes
    /// over in place of opening one of its own (ExtensionPanel).
    func show(_ id: String, from anchor: NSView?, reusing taken: NSPopover? = nil) {
        close()
        let extensions = Extensions.here
        let name = extensions.installed.first { $0.id == id }?.name ?? "iCloud Passwords"
        let host = NSHostingController(rootView: WithheldView(id: id, name: name, icon: extensions.icon(for: id, side: 32)) { [weak self] in
            self?.close()
            guard let browser = BrowserWindows.shared.activeBrowser ?? extensions.browser else { return }
            SettingsWindow.shared.showExtension(id, for: browser)
        })
        let size = host.view.fittingSize
        host.sizingOptions = []
        let popover = taken ?? NSPopover()
        if let taken {
            ExtensionPanel.replace(in: taken, with: host)
            taken.contentSize = size
        } else {
            popover.contentViewController = host
            popover.contentSize = size
            popover.behavior = .transient
            popover.animates = true
        }
        popover.delegate = self
        self.popover = popover
        extensionID = id
        button = anchor != nil && anchor === extensions.anchors[id]?.view ? anchor : nil
        if taken != nil {
            // Already on screen, as the list.
        } else if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: (anchor as? AnchorView)?.edge ?? .maxY)
        } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
            let spot = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
        }
    }

    func close() {
        guard let popover else { return }
        popover.performClose(nil)
        if self.popover === popover { forget() }
    }

    /// A press on the button of the extension whose popover is up closes
    /// it, as a popup's would: whether the popover is still there or went
    /// on this click's mouse-down. Closed, it is not opened again.
    func closes(_ id: String) -> Bool {
        defer { closedByButton = nil }
        if popover != nil, extensionID == id {
            close()
            return true
        }
        guard let closed = closedByButton, closed.id == id else { return false }
        return Date().timeIntervalSince(closed.at) < 1.5
    }

    private func forget() {
        popover = nil
        extensionID = nil
        button = nil
    }

    /// Closing on a mouse-down over the extension's own button.
    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID,
              let button, let window = button.window, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let spot = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if button.bounds.contains(spot) { closedByButton = (id, Date()) }
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        forget()
    }
}

/// The extension by name and icon, the line its row in Settings has, the
/// note its page has, and the way to that page.
@available(macOS 15.4, *)
private struct WithheldView: View {
    let id: String
    let name: String
    let icon: NSImage?
    let settings: () -> Void

    static let width: CGFloat = 320

    /// One apostrophe, the typeset one, as the corner says things.
    static func typeset(_ words: String) -> String { words.replacingOccurrences(of: "'", with: "\u{2019}") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(Self.typeset(ExtensionDetail.waitingTitle))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            Text(Self.typeset(ExtensionDetail.stoppedNote(id)))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            // Not the first responder's ring: the popover is read, not typed in.
            Button("Extension Settings", action: settings)
                .buttonStyle(.yab(.secondary, .small))
                .focusEffectDisabled()
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .background(Palette.ground)
    }
}
