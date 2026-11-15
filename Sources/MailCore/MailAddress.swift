import Foundation

public enum MailAddress {
    /// Whether it reads as an address someone could be written to at.
    public static func valid(_ text: String) -> Bool {
        text.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
    }
}
