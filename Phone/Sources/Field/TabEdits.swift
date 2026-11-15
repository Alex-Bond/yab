import SwiftUI
import UIKit

/// Native menu actions share one alert, including the UIKit pin menu.
@MainActor @Observable
final class TabEdits {
    enum Request {
        case tab(Space.ID, Tab)
        case folder(Space.ID, Folder)
        case newFolder(Space.ID, Folder.ID?, Tab?)

        var title: String {
            switch self {
            case .tab: "Rename Tab"
            case .folder: "Rename Folder"
            case .newFolder: "New Folder"
            }
        }
    }
    var request: Request?
    var text = ""

    func begin(_ request: Request) {
        switch request {
        case let .tab(_, tab): text = tab.name ?? tab.title
        case let .folder(_, folder): text = folder.name
        case .newFolder: text = ""
        }
        self.request = request
    }

    func save(in app: AppModel, reset: Bool = false) {
        guard let request else { return }
        self.request = nil
        let browser = app.browser
        switch request {
        case let .tab(space, tab):
            guard Self.isCurrentSpace(space, in: app), browser.tab(tab.id) == tab else { return }
            _ = browser.renameTab(tab.id, to: reset ? nil : text)
            Haptics.play(.light, reason: Haptics.Reason.edited)
        case let .folder(space, folder):
            guard Self.isCurrentSpace(space, in: app), app.sync.mayEditFolder(folder.id, in: space),
                  browser.space(space)?.folders.first(where: { $0.id == folder.id }) == folder else { return }
            _ = browser.renameFolder(folder.id, in: space, to: text)
            Haptics.play(.light, reason: Haptics.Reason.edited)
        case let .newFolder(space, parent, tab):
            guard Self.isCurrentSpace(space, in: app) else { return }
            if let parent { guard app.sync.mayEditFolder(parent, in: space) else { return } }
            if let tab { guard browser.tab(tab.id) == tab else { return } }
            guard let id = browser.createFolder(name: text, in: space, parent: parent) else { return }
            if let tab { Self.move(tab, in: space, to: id, app: app) }
            else { Haptics.play(.light, reason: Haptics.Reason.edited) }
        }
        app.sync.flushLocal()
    }

    static func isCurrentSpace(_ space: Space.ID, in app: AppModel) -> Bool {
        if app.field.shown, NewTabPager.shared.activeFieldMode != nil {
            return !app.field.isPrivate && !NewTabPager.shared.onChats && NewTabPager.shared.spaceID == space
        }
        return app.browser.spaceID == space
    }

    static func move(_ tab: Tab, in space: Space.ID, to folder: Folder.ID?, app: AppModel) {
        guard Self.isCurrentSpace(space, in: app), let owner = app.browser.space(space), !owner.isPrivate,
              owner.tab(tab.id) == tab, !tab.isPrivate, !tab.isMail,
              folder == nil || owner.folders.contains(where: { $0.id == folder }) else { return }
        if let folder { guard app.sync.mayEditFolder(folder, in: space) else { return } }
        if tab.place == .pinned { app.browser.unpin(tab.id); app.browser.keep(tab.id) }
        if tab.place == .today { app.browser.keep(tab.id) }
        _ = app.browser.moveIntoFolder(tab.id, in: space, to: folder)
        Haptics.play(.light, reason: Haptics.Reason.moved)
        app.sync.flushLocal()
    }

    static func destinations(in space: Space) -> [(folder: Folder, path: String)] {
        var result: [(Folder, String)] = []
        func walk(_ items: [KeptItem], prefix: String) {
            for item in items {
                guard case let .folder(folder) = item else { continue }
                let path = prefix.isEmpty ? folder.name : prefix + " / " + folder.name
                result.append((folder, path))
                walk(folder.items, prefix: path)
            }
        }
        walk(space.kept, prefix: "")
        return result
    }

    static func folderMenu(_ tab: Tab, app: AppModel) -> UIMenu? {
        guard !tab.isPrivate, !tab.isMail, let space = app.browser.space(holding: tab.id), !space.isPrivate else { return nil }
        var rows: [UIMenuElement] = [UIAction(title: "New Folder", image: UIImage(systemName: "folder.badge.plus")) { _ in
            app.tabEdits.begin(.newFolder(space.id, nil, tab))
        }]
        rows += destinations(in: space).filter { app.sync.mayEditFolder($0.folder.id, in: space.id) }.map { destination in
            UIAction(title: destination.path, image: .menuGlyph(GlyphName.folder1.rawValue),
                     state: space.folder(holding: tab.id)?.id == destination.folder.id ? .on : .off) { _ in
                guard app.browser.space(space.id)?.folders.first(where: { $0.id == destination.folder.id }) == destination.folder else { return }
                move(tab, in: space.id, to: destination.folder.id, app: app)
            }
        }
        return UIMenu(title: "Move to Folder", image: .menuGlyph(GlyphName.folder1.rawValue), children: rows)
    }
}

struct TabEditAlert: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var edits = app.tabEdits
        content.alert(edits.request?.title ?? "Rename Tab", isPresented: Binding(
            get: { edits.request != nil }, set: { if !$0 { edits.request = nil } }
        )) {
            TextField("Name", text: $edits.text)
            Button("Cancel", role: .cancel) { edits.request = nil }
            if case let .tab(_, tab) = edits.request, tab.name != nil {
                Button("Reset") { edits.save(in: app, reset: true) }
            }
            Button("Save") { edits.save(in: app) }
                .disabled(edits.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct MoveToFolderMenu: View {
    @Environment(AppModel.self) private var app
    let tab: Tab
    private var folderGlyph: Image {
        UIImage.menuGlyph(GlyphName.folder1.rawValue).map { Image(uiImage: $0) } ?? Image(systemName: "folder")
    }

    var body: some View {
        if let space = app.browser.space(holding: tab.id), !space.isPrivate, !tab.isPrivate, !tab.isMail {
            Menu {
                Button("New Folder", systemImage: "folder.badge.plus") { app.tabEdits.begin(.newFolder(space.id, nil, tab)) }
                ForEach(TabEdits.destinations(in: space).filter { app.sync.mayEditFolder($0.folder.id, in: space.id) }, id: \.folder.id) { destination in
                    Button {
                        guard app.browser.space(space.id)?.folders.first(where: { $0.id == destination.folder.id }) == destination.folder else { return }
                        TabEdits.move(tab, in: space.id, to: destination.folder.id, app: app)
                    } label: {
                        if space.folder(holding: tab.id)?.id == destination.folder.id {
                            Label(destination.path, systemImage: "checkmark")
                        } else {
                            Label { Text(destination.path) } icon: { folderGlyph }
                        }
                    }
                }
            } label: { Label { Text("Move to Folder") } icon: { folderGlyph } }
            if space.folder(holding: tab.id) != nil {
                Button("Move Out of Folder", systemImage: "arrow.up.forward") { TabEdits.move(tab, in: space.id, to: nil, app: app) }
            }
        }
    }
}
