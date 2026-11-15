import Testing
@testable import Fast

struct MailCodePreviewTests {
    @Test func repeatedSubjectsLeaveOnlyTheMail() {
        #expect(MailSense.line("Brex Verification Code · Confirm your payment", subject: "Brex verification code") == "Confirm your payment")
        #expect(MailSense.line("  WEEKLY  NEWS!  ", subject: "Weekly news") == "")
        #expect(MailSense.line("Newsletter for October", subject: "News") == "Newsletter for October")
        #expect(MailSense.line("The update is ready", subject: "Update") == "The update is ready")
        #expect(MailSense.line("Your meeting: Friday", subject: "Your meeting") == "Friday")
    }
}
