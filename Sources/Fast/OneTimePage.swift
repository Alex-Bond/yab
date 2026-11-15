import AppKit
import Vision
import WebKit

// Adding a login's one-time code from the page that set it up. A site turning
// two-step sign-in on shows a QR code and a box for the first code; the page
// is under the box while Add a Code… is written, so Yab reads the QR from its
// picture, offers the key pale in the field (Tab takes it), and Save fills the
// page's box with the code it makes.

enum OneTimePage {
    /// The otpauth://totp link in a QR code on the picture, if there is one.
    nonisolated static func link(in image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap(\.payloadStringValue)
            .first { $0.lowercased().hasPrefix("otpauth://totp") }
    }

    /// What the field shows for a link: the key in fours, as sites write it
    /// out, when the link says nothing the key alone doesn't; else the link.
    static func shown(_ link: String) -> String {
        guard let setup = OneTime.parse(link), setup.digits == 6, setup.period == 30, setup.algorithm == "SHA1",
              let secret = URLComponents(string: link)?.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value
        else { return link }
        let clean = Array(secret.uppercased().filter { !" -=".contains($0) })
        return stride(from: 0, to: clean.count, by: 4)
            .map { String(clean[$0..<min($0 + 4, clean.count)]) }
            .joined(separator: " ")
    }

    /// The page's box for the first code: one marked for a code, or a row
    /// of one-digit boxes. `fill` false only says whether there is one.
    static let fill = """
    function seen(b) {
      var r = b.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && !b.disabled && !b.readOnly;
    }
    function asks(b) {
      if (['password', 'hidden', 'checkbox', 'radio', 'email', 'search'].indexOf((b.type || 'text').toLowerCase()) >= 0) return false;
      var words = [b.autocomplete, b.name, b.id, b.placeholder, b.getAttribute('aria-label'),
                   b.labels && b.labels[0] ? b.labels[0].textContent : ''].join(' ').toLowerCase();
      return /one-time-code|otp|totp|2fa|mfa|two.?factor|verif|authenticat|token|code/.test(words)
        || (b.inputMode === 'numeric' && b.maxLength >= 6 && b.maxLength <= 8);
    }
    var boxes = [].filter.call(document.querySelectorAll('input'), seen);
    var row = null;
    var one = boxes.filter(function (b) { return b.maxLength === 1; });
    if (one.length >= 6) {
      var up = one[0].parentElement;
      for (var i = 0; i < 3 && up && !row; i++, up = up.parentElement) {
        var all = one.filter(function (b) { return up.contains(b); });
        if (all.length === 6) row = all;
      }
    }
    if (!row) {
      var box = boxes.filter(function (b) { return b.maxLength !== 1 && !b.value && asks(b); })[0];
      if (box) row = [box];
    }
    if (!row || row.some(function (b) { return b.value; })) return false;
    if (!fill) return true;
    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    row.forEach(function (b, i) {
      var value = row.length === 1 ? code : code[i];
      b.focus();
      setter.call(b, value);
      b.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
      b.dispatchEvent(new Event('change', { bubbles: true }));
    });
    return row.map(function (b) { return b.value; }).join('') === code;
    """
}

extension Browser {
    /// Add a Code… with the site's page under the box: its QR read for the
    /// key, and its box for the first code looked for, so Save fills it.
    /// Another site's page is never read for this login.
    func readCodePage(host: String, user: String) {
        guard let tab = active, let site = tab.address?.host(), Vault.registrable(site) == Vault.registrable(host) else { return }
        let kind = PlaceEdit.Kind.code(host: host, user: user)
        if let web = tab.built {
            web.callAsyncJavaScript(OneTimePage.fill, arguments: ["code": "", "fill": false], in: nil, in: .defaultClient) { [weak self, weak tab] result in
                MainActor.assumeIsolated {
                    guard let self, let tab, case .success(let found) = result, found as? Bool == true,
                          self.query.edit?.kind == kind else { return }
                    self.query.edit?.fillTab = tab.id
                }
            }
        }
        tab.builtPage?.snapshot(PageShot(afterUpdates: false)) { [weak self] image, _ in
            guard let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            Task { @MainActor [weak self] in
                guard let link = await Task.detached(operation: { OneTimePage.link(in: image) }).value,
                      let self, var edit = self.query.edit, edit.kind == kind,
                      let index = edit.lines.firstIndex(where: { $0.key == "setup" }), edit.lines[index].value.isEmpty else { return }
                edit.lines[index].ghost = OneTimePage.shown(link)
                self.query.edit = edit
            }
        }
    }

    /// The code just made, into the page's box, the keyboard back on the page.
    func fillCodePage(_ code: String, tab id: Tab.ID, host: String) {
        guard let tab = autofillTab(id), let web = tab.built else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let site = tab.address?.host(), Vault.registrable(site) == Vault.registrable(host) else { return }
            web.window?.makeFirstResponder(web)
            web.callAsyncJavaScript(OneTimePage.fill, arguments: ["code": code, "fill": true], in: nil, in: .defaultClient) { _ in }
        }
    }
}
