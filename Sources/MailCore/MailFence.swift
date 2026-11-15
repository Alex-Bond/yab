import Foundation

public enum MailFence {
    /// Words kept inside their fence: a closing tag of the fence's own in
    /// them (a mail that writes </mail> to end the data early, and its
    /// instructions after) is broken, so only Yab's own tag ends it.
    /// mail_read, mail_file and mail_recall, replies written ahead
    /// (MailDrafts) and the Mac's own model (MailSense) fence mail with it.
    public static func fenced(_ text: String, _ tag: String) -> String {
        text.replacingOccurrences(of: "</\\s*" + tag, with: "</ " + tag, options: [.regularExpression, .caseInsensitive])
    }
}
