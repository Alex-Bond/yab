import Foundation

extension StateCatalog {
    static let tabEdits: [NamedState] = [
        NamedState("tabedits.1", "Names and folders", "Native menus on a pin, a kept page and a folder.") { app in
            let page = Tab(id: "edit-tab", title: "Design references", site: "Example", icon: "globe", page: "blank")
            let pin = Tab(id: "edit-pin", title: "Pinned reference", site: "Example", icon: "globe", page: "blank")
            let space = Space(id: "edit-space", name: "Work", emoji: "", tint: RGB(226, 233, 244),
                              pins: [pin], kept: [.tab(page), .folder(Folder(id: "edit-folder", name: "Research", tabs: []))], current: page.id)
            app.browser.adopt([space])
            app.browser.showSpace(space.id)
            app.field.openSpaces()
        },
    ]
}
