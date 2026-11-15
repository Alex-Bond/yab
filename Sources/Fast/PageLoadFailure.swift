import Foundation

enum PageLoadFailure {
    static let netNames: [Int: String] = [
        -3: "ERR_ABORTED", -7: "ERR_TIMED_OUT", -21: "ERR_NETWORK_CHANGED",
        -100: "ERR_CONNECTION_CLOSED", -101: "ERR_CONNECTION_RESET", -102: "ERR_CONNECTION_REFUSED",
        -103: "ERR_CONNECTION_ABORTED", -104: "ERR_CONNECTION_FAILED", -105: "ERR_NAME_NOT_RESOLVED",
        -106: "ERR_INTERNET_DISCONNECTED", -107: "ERR_SSL_PROTOCOL_ERROR", -109: "ERR_ADDRESS_UNREACHABLE",
        -118: "ERR_CONNECTION_TIMED_OUT", -137: "ERR_NAME_RESOLUTION_FAILED",
        -200: "ERR_CERT_COMMON_NAME_INVALID", -201: "ERR_CERT_DATE_INVALID", -202: "ERR_CERT_AUTHORITY_INVALID",
        -203: "ERR_CERT_CONTAINS_ERRORS", -207: "ERR_CERT_INVALID", -324: "ERR_EMPTY_RESPONSE"
    ]

    static func message(domain: String, code: Int) -> String {
        if domain == "net" {
            switch code {
            case -105, -137: return "Nothing answers at this address"
            case -106: return "You’re offline"
            case -7, -118: return "The site didn’t respond in time"
            case -102, -104, -109: return "The site won’t accept connections"
            case -100, -101, -103, -21, -324: return "The connection was interrupted"
            case -299 ... -200, -107: return "Can’t connect securely"
            default: return "The page couldn’t load"
            }
        }
        guard domain == NSURLErrorDomain else { return "The page couldn’t load" }
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "Nothing answers at this address"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "You’re offline"
        case NSURLErrorTimedOut: return "The site didn’t respond in time"
        case NSURLErrorCannotConnectToHost: return "The site won’t accept connections"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return "Can’t connect securely"
        default: return "The page couldn’t load"
        }
    }
}
