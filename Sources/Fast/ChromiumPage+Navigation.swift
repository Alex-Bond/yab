import AppKit
import YabCoreClient

extension ChromiumPage {
    /// A native callback can be waiting for the input or script at the head
    /// of the operation queue. Its answer must use the connection directly.
    func continueNativeQuestion(_ method: String, remote: String?, _ values: [String: JSONValue]) {
        guard let remote, remoteID == remote else { return }
        Task { @MainActor [weak self] in
            guard let self, self.remoteID == remote,
                  let core = try? await ChromiumProcess.shared.connection(),
                  self.remoteID == remote, ChromiumProcess.shared.isCurrent(core) else { return }
            var params = values; params["tab"] = .string(remote)
            _ = try? await core.request(method, params: params)
        }
    }

    /// These events originate in CEF/CDP, never in a page-authored payload.
    func receiveNavigation(_ event: YabCoreEvent) {
        let p = event.params
        switch event.name {
        case "dialog.open":
            guard let token = p["request"]?.string else { return }
            let remote = remoteID
            let finish: (Bool, String?) -> Void = { [weak self] accept, text in
                self?.continueNativeQuestion("dialog.reply", remote: remote,
                    ["request": .string(token), "accept": .bool(accept), "text": .string(text ?? "")])
            }
            let kind = PageDialog.Kind(rawValue: p["kind"]?.string ?? "")
            guard let kind, let source = p["origin"]?.string.flatMap(URL.init(string:)), let events else {
                finish(false, nil); return
            }
            let origin = PageOrigin(scheme: source.scheme ?? "", host: source.host ?? "", port: source.port ?? 0)
            let dialog = PageDialog(kind: kind, message: p["message"]?.string ?? "",
                                    defaultText: p["defaultText"]?.string, origin: origin)
            var answered = false
            events.page(self, dialog: dialog) { [weak self] reply in
                guard !answered, let self, self.remoteID == remote else { return }
                answered = true
                switch reply {
                case .accept(let text): finish(true, text)
                case .cancel:
                    finish(false, nil)
                    if kind == .beforeUnload { _ = self.navigationTab?.settleOnShown() }
                }
            }
        case "file.open":
            guard let token = p["request"]?.string else { return }
            let lifetime = fileRequests.begin(token)
            guard let events else {
                if fileRequests.finish(token, lifetime) { continueNativeQuestion("file.reply", remote: remoteID, ["request": .string(token), "paths": .array([])]) }
                return
            }
            let picker = PageFilePicker(allowsDirectories: p["directories"] == .bool(true),
                                        allowsMultiple: p["multiple"] == .bool(true),
                                        frame: scripts.fileFrame(p, tab: event.tab), lifetime: lifetime)
            let remote = remoteID
            events.page(self, chooseFiles: picker) { [weak self] urls in
                guard let self, self.remoteID == remote, self.fileRequests.finish(token, lifetime) else { return }
                let paths = (urls ?? []).filter(\.isFileURL).map { JSONValue.string($0.path) }
                self.continueNativeQuestion("file.reply", remote: remote, ["request": .string(token), "paths": .array(paths)])
            }
        case "file.closed":
            if let token = p["request"]?.string { fileRequests.cancel(token) }
        case "script.message":
            // A find update changes only find-bar counts. The world and binding
            // are supplied by CDP, not trusted from the message body.
            guard p["world"] == .string("yab-world-yab"), p["name"] == .string("yabFindChanged"),
                  let value = p["value"], let data = try? JSONEncoder().encode(value),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            navigationTab?.finder.heard(body)
        default: break
        }
    }
}
