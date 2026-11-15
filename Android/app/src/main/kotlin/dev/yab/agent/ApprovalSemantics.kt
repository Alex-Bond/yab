package dev.yab.agent

/** Actual permit and typed detail decide the presentation. Text classification grants no authority. */
object ApprovalSemantics {
    fun kind(permit: String, pay: ApprovalPayment?, mails: List<ApprovalMail>, files: List<ApprovalFile>, person: String?, text: String?, choices: List<String>): ApprovalKind = when {
        pay != null -> ApprovalKind.PAYMENT
        mails.size > 1 || mails.firstOrNull()?.date != null -> ApprovalKind.MAIL_BATCH
        mails.isNotEmpty() -> ApprovalKind.MAIL
        permit == "mail.read" -> ApprovalKind.MAIL_SEARCH
        files.isNotEmpty() -> ApprovalKind.FILES
        person != null && text != null -> ApprovalKind.MESSAGE
        choices.isNotEmpty() -> ApprovalKind.ACCOUNTS
        else -> ApprovalKind.LINES
    }
    fun verb(explicit: String?, kind: ApprovalKind, place: String, permit: String, payment: ApprovalPayment?, mails: List<ApprovalMail>): String = explicit?.also { require(it.length <= 60) } ?: when {
        kind == ApprovalKind.PAYMENT -> "Pay ${payment?.amount.orEmpty()}"
        kind == ApprovalKind.MAIL_SEARCH -> "Allow in This Chat"
        kind == ApprovalKind.ACCOUNTS -> "Sign In"
        kind == ApprovalKind.MAIL_BATCH && mails.all { it.date == null } -> "Send All ${mails.size}"
        place.startsWith("chat:") -> if (permit.startsWith("mail.site:")) "Go" else "Allow"
        else -> "Approve"
    }
}
