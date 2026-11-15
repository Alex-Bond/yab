import AppKit
import Security
import Testing
import YabDesign
@testable import Fast

/// Synthetic dictionaries, drafts and isolated browser state. No personal
/// saved-login listing, authentication prompt or real Keychain operation.
@Suite(.serialized)
@MainActor
struct PasswordEditTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
    }

    private func entry() -> Vault.Entry {
        Vault.Entry(host: "edit-\(UUID().uuidString).invalid", user: "alex@example.invalid", used: nil, saved: nil)
    }

    @Test func replacementChangesOnlyTheSecretAndMarksSyncOnce() {
        let entry = entry()
        let item = "login/" + entry.id
        let date = Date(timeIntervalSince1970: 123)
        var row: [String: Any] = [
            kSecAttrServer as String: entry.host, kSecAttrAccount as String: entry.user,
            kSecAttrProtocol as String: kSecAttrProtocolHTTP,
            kSecAttrSecurityDomain as String: "owned synthetic domain",
            kSecAttrLabel as String: "synthetic label",
            kSecAttrCreationDate as String: date, kSecAttrComment as String: "123",
            Vault.spaceKey: UUID().uuidString, "otp-association": "unchanged",
            kSecValueData as String: Data("old synthetic password".utf8),
        ]
        let before = row as NSDictionary
        let marks = Vault.localChanges()[item] ?? 0
        let raw = "  new π🔑\t\n  "
        var calls = 0
        let saved = Vault.replacePassword(host: entry.host, user: entry.user, password: raw) { host, user, fields in
            calls += 1
            #expect(host == entry.host && user == entry.user)
            #expect(Set(fields.keys) == [kSecValueData as String])
            row.merge(fields) { _, value in value }
            return errSecSuccess
        }
        #expect(saved && calls == 1)
        #expect(row[kSecValueData as String] as? Data == Data(raw.utf8))
        for key in row.keys where key != kSecValueData as String {
            #expect((row[key] as? NSObject)?.isEqual(before[key]) == true)
        }
        #expect(Vault.localChanges()[item] == marks + 1)
    }

    @Test func missingOrRefusedRowsStayMissingAndDoNotMarkSync() {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed] {
            let entry = entry()
            let item = "login/" + entry.id
            let before = Vault.localChanges()[item]
            var calls = 0
            #expect(!Vault.replacePassword(host: entry.host, user: entry.user, password: "synthetic") { _, _, _ in
                calls += 1
                return status
            })
            #expect(calls == 1)
            #expect(Vault.localChanges()[item] == before)
        }
    }

    @Test func emptyInputNeverReachesStorageAndNamelessLoginKeepsItsIdentity() {
        var calls = 0
        #expect(!Vault.replacePassword(host: "fixture.invalid", user: "", password: "") { _, _, _ in
            calls += 1; return errSecSuccess
        })
        #expect(!Vault.replacePassword(host: "", user: "name", password: "synthetic") { _, _, _ in
            calls += 1; return errSecSuccess
        })
        #expect(calls == 0)
        let host = "nameless-\(UUID().uuidString).invalid"
        // An empty account is passed to the narrow identity resolver as-is,
        // rather than renamed or used to create a new item.
        let replaced = Vault.replacePassword(host: host, user: "", password: " ") { site, user, fields in
            calls += 1
            #expect(site == host && user.isEmpty)
            #expect(fields[kSecValueData as String] as? Data == Data(" ".utf8))
            return errSecSuccess
        }
        #expect(replaced)
        #expect(calls == 1)
    }

    @Test func referenceResolutionHandlesNamelessRowsAndRefusesAmbiguity() {
        let ref = Data("synthetic persistent reference".utf8)
        let nameless: [String: Any] = [kSecAttrServer as String: "fixture.invalid",
                                        kSecValuePersistentRef as String: ref]
        var named = nameless
        named[kSecAttrAccount as String] = "alex@example.invalid"
        #expect(Vault.replacementReference(host: "fixture.invalid", user: "", owned: [nameless, named]) == ref)
        #expect(Vault.replacementReference(host: "fixture.invalid", user: "alex@example.invalid", owned: [nameless, named]) == ref)
        var empty = nameless
        empty[kSecAttrAccount as String] = ""
        #expect(Vault.replacementReference(host: "fixture.invalid", user: "", owned: [empty]) == ref)
        // HTTP and HTTPS with the same visible identity must not both change.
        var http = named
        http[kSecAttrProtocol as String] = kSecAttrProtocolHTTP
        var https = named
        https[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
        https[kSecValuePersistentRef as String] = Data("another reference".utf8)
        #expect(Vault.replacementReference(host: "fixture.invalid", user: "alex@example.invalid", owned: [http, https]) == nil)
        #expect(Vault.replacementReference(host: "elsewhere.invalid", user: "", owned: [nameless]) == nil)
        #expect(Vault.replacementReference(host: "fixture.invalid", user: "", owned: []) == nil)
        #expect(Vault.replacementReference(host: "fixture.invalid", user: "", owned: [[kSecAttrServer as String: "fixture.invalid"]]) == nil)
    }

    @Test func editorStartsWithSavedSiteAndNameAndAnEmptyPassword() {
        _ = NSApplication.shared
        let entry = entry()
        let editor = PasswordEditController(entry: entry, prove: { _ in Issue.record("Unexpected proof") },
                                            write: { _, _, _ in Issue.record("Unexpected write"); return .failed }, didSave: {})
        let model = editor.model
        #expect(model.website == entry.host && model.userName == entry.user && model.password.isEmpty)
        #expect(!model.showing && !model.changed && !model.canSave)
        editor.save(nil)
        #expect(!editor.finished && !editor.waiting)
        editor.cancel(nil)
    }

    @Test func saveNeedsAChangeAndASite() {
        let entry = entry()
        let model = PasswordEditModel(entry: entry)
        model.userName = "other@example.invalid"
        #expect(model.changed && model.canSave)
        model.website = "  "
        #expect(!model.canSave)
        model.website = "https://Example.INVALID/path"
        #expect(model.host == "example.invalid" && model.canSave)
        model.website = "two words"
        #expect(model.host == nil && !model.canSave)
        model.website = entry.host
        model.userName = entry.user
        model.password = " "
        #expect(model.canSave)
    }

    @Test func savePreservesRawPasswordAndFinishesExactlyOnce() {
        _ = NSApplication.shared
        var writes: [String?] = []
        var saves = 0
        let editor = PasswordEditController(entry: entry(), prove: { $0(true) }, write: { _, _, password in
            writes.append(password); return .saved
        }, didSave: { saves += 1 })
        let raw = "  синтетический π🔑  "
        editor.model.password = raw
        #expect(editor.model.canSave)
        editor.save(nil)
        #expect(writes == [raw] && saves == 1)
        #expect(editor.finished && editor.model.password.isEmpty && !editor.model.canSave)
    }

    @Test func renameSendsTheNewNamesAndNoPasswordWhenNoneWasTyped() {
        _ = NSApplication.shared
        var seen: [(String, String, String?)] = []
        let editor = PasswordEditController(entry: entry(), prove: { $0(true) }, write: { host, user, password in
            seen.append((host, user, password)); return .saved
        }, didSave: {})
        editor.model.website = "https://New.Example.invalid/"
        editor.model.userName = "new@example.invalid"
        editor.save(nil)
        #expect(seen.count == 1 && seen[0].0 == "new.example.invalid" && seen[0].1 == "new@example.invalid" && seen[0].2 == nil)
    }

    @Test func takenAndFailedWritesStayRecoverableWithoutLosingTheDraft() {
        _ = NSApplication.shared
        var result = Vault.LoginEdit.taken
        var writes = 0
        var saves = 0
        let editor = PasswordEditController(entry: entry(), prove: { $0(true) }, write: { _, _, _ in
            writes += 1; return result
        }, didSave: { saves += 1 })
        editor.model.password = "synthetic draft"
        editor.save(nil)
        #expect(!editor.finished && editor.model.error == "That login is already saved.")
        #expect(editor.model.password == "synthetic draft" && editor.model.canSave && saves == 0)
        result = .failed
        editor.save(nil)
        #expect(!editor.finished && editor.model.error != nil && editor.model.password == "synthetic draft")
        result = .saved
        editor.save(nil)
        #expect(editor.finished && writes == 3 && saves == 1)
    }

    @Test func deniedProofDoesNotWriteAndCanBeRetried() {
        _ = NSApplication.shared
        var allowed = false
        var writes = 0
        let editor = PasswordEditController(entry: entry(), prove: { $0(allowed) }, write: { _, _, _ in
            writes += 1; return .saved
        }, didSave: {})
        editor.model.password = "synthetic draft"
        editor.save(nil)
        #expect(writes == 0 && !editor.waiting && !editor.finished && editor.model.canSave)
        allowed = true
        editor.save(nil)
        #expect(writes == 1 && editor.finished)
    }

    @Test func repeatedSaveWaitsAndCancellationRejectsALateProof() {
        _ = NSApplication.shared
        var answer: ((Bool) -> Void)?
        var proofs = 0
        var writes = 0
        let editor = PasswordEditController(entry: entry(), prove: { done in
            proofs += 1; answer = done
        }, write: { _, _, _ in writes += 1; return .saved }, didSave: { Issue.record("Unexpected save") })
        editor.model.password = "synthetic draft"
        editor.save(nil)
        editor.save(nil)
        #expect(proofs == 1 && editor.waiting && !editor.model.canSave)
        editor.cancel(nil)
        answer?(true)
        #expect(writes == 0 && editor.finished && editor.model.password.isEmpty)
    }

    @Test func removingOrReplacingThePlaceDraftRejectsLateProof() {
        let query = Query()
        for replace in [false, true] {
            var answer: ((Bool) -> Void)?
            var writes = 0
            var ended = 0
            let editor = PasswordEditController(entry: entry(), prove: { answer = $0 },
                write: { _, _, _ in writes += 1; return .saved }, endEditing: { ended += 1 }, didSave: {})
            query.edit = PlaceEdit(kind: .login(editor), title: "Edit Login", lines: [])
            editor.model.password = "synthetic draft"
            editor.model.showing = true
            editor.save(nil)
            // Dismiss, selection change, another place or another editor.
            if replace {
                query.edit = PlaceEdit(kind: .profile, title: "Your Profile", lines: [])
            } else {
                query.edit = nil
            }
            answer?(true)
            #expect(writes == 0 && editor.finished && !editor.waiting)
            #expect(editor.model.password.isEmpty && !editor.model.showing)
            #expect(ended == 2, "Commit the field at Save and clear it on discard")
        }
    }

    @Test func placeRoutesSaveAndCancelToTheSameDraftWithoutOpeningAWindow() {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        defer {
            browser.dismiss()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        var answer: ((Bool) -> Void)?
        var writes = 0
        let editor = PasswordEditController(entry: entry(), prove: { answer = $0 },
            write: { _, _, _ in writes += 1; return .saved }, didSave: {})
        let windows = NSApp.windows.count
        browser.query.acting = 0
        browser.query.revealed = (id: "fixture", text: "synthetic revealed value")
        browser.beginEdit(.login(editor))
        #expect(NSApp.windows.count == windows)
        #expect(browser.query.edit?.passwordEditor === editor)
        #expect(browser.query.edit?.title == "Edit Login")
        #expect(browser.query.acting == nil && browser.query.revealed == nil)
        #expect(browser.editActions.map(\.id) == ["save", "cancel"])
        editor.model.password = "synthetic draft"
        browser.editActions[0].run()
        #expect(editor.waiting && writes == 0)
        let focus = browser.query.focusRequest
        browser.editActions[1].run()
        answer?(true)
        #expect(browser.query.edit == nil && browser.query.focusRequest == focus + 1)
        #expect(editor.finished && editor.model.password.isEmpty && writes == 0)
    }

    @Test func newActionGlyphsDecodeAtSixteenAndThirtyTwoPoints() throws {
        let names = ["yab.key.pen", "yab.globe.pen", "yab.clock.plus"]
        let sheet = NSImage(size: NSSize(width: 360, height: 150))
        sheet.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 360, height: 150).fill()
        for (index, name) in names.enumerated() {
            for side in [16, 32] {
                let icon = try #require(Glyphs.image(name, side: CGFloat(side)))
                #expect(icon.size == NSSize(width: side, height: side))
                #expect(icon.tiffRepresentation?.isEmpty == false)
                icon.draw(in: NSRect(x: 20 + index * 115, y: side == 16 ? 82 : 35, width: side, height: side))
            }
            (name as NSString).draw(at: NSPoint(x: 12 + index * 115, y: 118),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
        }
        sheet.unlockFocus()
        if let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] {
            let data = try #require(sheet.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("glyphs-16-32.png"))
        }
    }

    @Test func renameMovesTheItemInPlaceAndMarksBothNamesForSync() {
        let old = entry()
        let newHost = "moved-\(UUID().uuidString).invalid"
        let oldItem = "login/" + old.id
        let newItem = "login/" + newHost + "\u{1}" + "new@example.invalid"
        let marks = Vault.localChanges()[newItem] ?? 0
        var fields: [String: Any] = [:]
        let result = Vault.updateLogin(host: old.host, user: old.user, newHost: newHost, newUser: "new@example.invalid",
                                       password: nil, taken: { _, _ in false }, update: { given in
            fields = given; return errSecSuccess
        })
        #expect(result == .saved)
        #expect(fields[kSecAttrServer as String] as? String == newHost)
        #expect(fields[kSecAttrAccount as String] as? String == "new@example.invalid")
        #expect(fields[kSecValueData as String] == nil, "No typed password keeps the saved secret")
        #expect(Vault.changedItems().isSuperset(of: [oldItem, newItem]))
        #expect(Vault.localChanges()[newItem] == marks + 1)
    }

    @Test func renameRefusesAnExistingLoginAndANeedlessOrBrokenWrite() {
        let old = entry()
        var updates = 0
        #expect(Vault.updateLogin(host: old.host, user: old.user, newHost: "b.invalid", newUser: "x", password: nil,
                                  taken: { _, _ in true }, update: { _ in updates += 1; return errSecSuccess }) == .taken)
        #expect(updates == 0)
        #expect(Vault.updateLogin(host: old.host, user: old.user, newHost: "b.invalid", newUser: "x", password: nil,
                                  taken: { _, _ in false }, update: { _ in errSecDuplicateItem }) == .taken)
        for status in [errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed] {
            let item = "login/b.invalid\u{1}x"
            let before = Vault.localChanges()[item]
            #expect(Vault.updateLogin(host: old.host, user: old.user, newHost: "b.invalid", newUser: "x", password: nil,
                                      taken: { _, _ in false }, update: { _ in status }) == .failed)
            #expect(Vault.localChanges()[item] == before)
        }
        #expect(Vault.updateLogin(host: old.host, user: old.user, newHost: "", newUser: "x", password: nil,
                                  taken: { _, _ in false }, update: { _ in updates += 1; return errSecSuccess }) == .failed)
        #expect(Vault.updateLogin(host: old.host, user: old.user, newHost: "b.invalid", newUser: "x", password: "",
                                  taken: { _, _ in false }, update: { _ in updates += 1; return errSecSuccess }) == .failed)
        #expect(updates == 0)
    }

    @Test func cleanHostKeepsOnlyABareLowercaseSite() {
        #expect(Vault.cleanHost("  Example.COM ") == "example.com")
        #expect(Vault.cleanHost("https://accounts.example.com/login?x=1") == "accounts.example.com")
        #expect(Vault.cleanHost("example.com/") == "example.com")
        #expect(Vault.cleanHost("") == nil)
        #expect(Vault.cleanHost("a b") == nil)
        #expect(Vault.cleanHost("example.com/path") == nil)
    }
}
