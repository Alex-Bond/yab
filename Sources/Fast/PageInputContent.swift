import AppKit

/// Input hints belong to the page that owns the authenticated focus relay.
/// Updating one must never construct or substitute a different engine.
@MainActor
protocol PageInputContent: AnyObject {
    func updateInputContent(_ kind: String?)
}

extension PageView: PageInputContent {}

extension ChromiumPage: NSTextContent, PageInputContent {
    func updateInputContent(_ kind: String?) {
        switch kind {
        case "email": contentType = .emailAddress
        case "username": contentType = .username
        case "password": contentType = .password
        case "new-password": contentType = .newPassword
        case "code": contentType = .oneTimeCode
        case "phone": contentType = .telephoneNumber
        case "text": contentType = nil
        default: contentType = .URL
        }
    }

    func resetNativeTextInput() {
        discardNativeComposition()
        nativeText = nil
        contentType = .URL
        inputContext?.invalidateCharacterCoordinates()
    }
}
