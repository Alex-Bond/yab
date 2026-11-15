import Foundation
import YabCoreClient

/// Native CEF hang-monitor events belong to the live renderer, never a
/// replaced or already-ended process. Page/remote-tab identity is checked by
/// ChromiumPage.receive before this value is read.
struct ChromiumResponsiveness {
    let responsive: Bool

    init?(_ params: [String: JSONValue], rendererPID: pid_t?) {
        guard let rendererPID, rendererPID > 0,
              params["rendererPID"] == .number(Double(rendererPID)),
              case .bool(let value) = params["responsive"] else { return nil }
        responsive = value
    }
}
