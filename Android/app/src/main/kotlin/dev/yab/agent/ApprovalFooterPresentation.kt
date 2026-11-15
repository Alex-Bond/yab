package dev.yab.agent

/** A local failure publication, not authority to answer or an authentication proof. */
internal data class ApprovalFailureLease(val displayed: ApprovalDisplayLease, val revision: Long)

internal enum class ApprovalFooterPhase { READY, BUSY, SENDING, PAYING, PAID, DECLINED, DONE, FAILED }
internal enum class ApprovalFooterAction { APPROVE, CLOSE_FAILURE, CLOSE_RESULT, NONE }
internal data class ApprovalFooterPresentation(
    val phase: ApprovalFooterPhase, val label: String, val line: String, val reserveLine: Boolean,
    val action: ApprovalFooterAction, val accounts: Boolean = false,
) {
    val proof get() = phase == ApprovalFooterPhase.READY || phase == ApprovalFooterPhase.DECLINED && action == ApprovalFooterAction.APPROVE
    val success get() = phase == ApprovalFooterPhase.PAID || phase == ApprovalFooterPhase.DONE
    val warning get() = phase == ApprovalFooterPhase.FAILED || phase == ApprovalFooterPhase.DECLINED

    companion object {
        /** BUSY spans authentication and guarded transport. It is never called a proved send. */
        fun from(shown: ApprovalPresented, busy: Boolean, failure: String?): ApprovalFooterPresentation {
            val request = shown.request
            val receipt = shown.receipt
            val result = receipt?.result
            val phase = when {
                receipt != null -> when (result?.phase) {
                    null -> ApprovalFooterPhase.SENDING
                    ApprovalResultPhase.paying -> ApprovalFooterPhase.PAYING
                    ApprovalResultPhase.paid -> ApprovalFooterPhase.PAID
                    ApprovalResultPhase.declined -> ApprovalFooterPhase.DECLINED
                    ApprovalResultPhase.done -> ApprovalFooterPhase.DONE
                    ApprovalResultPhase.failed -> ApprovalFooterPhase.FAILED
                }
                busy -> ApprovalFooterPhase.BUSY
                failure != null -> ApprovalFooterPhase.FAILED
                shown.retry != null -> ApprovalFooterPhase.DECLINED
                else -> ApprovalFooterPhase.READY
            }
            val retry = shown.retry != null && receipt == null && phase == ApprovalFooterPhase.DECLINED
            val verb = shown.content.verb ?: "Approve"
            val label = when {
                phase == ApprovalFooterPhase.FAILED || phase == ApprovalFooterPhase.DECLINED && !retry -> "Close"
                retry -> "Try Again · ${request.payment?.amount.orEmpty()}"
                else -> verb
            }
            val line = when (phase) {
                ApprovalFooterPhase.PAYING -> "This can take a few seconds"
                ApprovalFooterPhase.PAID -> result?.order?.let { "Order $it" } ?: "On ${request.payment?.site.orEmpty()}"
                ApprovalFooterPhase.DECLINED -> (shown.retry?.result ?: result)?.words ?: "Payment not completed"
                ApprovalFooterPhase.FAILED -> failure ?: result?.words ?: "It didn’t go through on your Mac."
                else -> ""
            }
            val action = when {
                request.choices.isNotEmpty() -> ApprovalFooterAction.NONE
                phase == ApprovalFooterPhase.FAILED && receipt == null -> ApprovalFooterAction.CLOSE_FAILURE
                phase in setOf(ApprovalFooterPhase.FAILED, ApprovalFooterPhase.DECLINED) && receipt != null -> ApprovalFooterAction.CLOSE_RESULT
                phase == ApprovalFooterPhase.READY || retry -> ApprovalFooterAction.APPROVE
                else -> ApprovalFooterAction.NONE
            }
            return ApprovalFooterPresentation(phase, label, line, request.payment != null || line.isNotEmpty(), action,
                accounts = request.choices.isNotEmpty())
        }
    }
}
