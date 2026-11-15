package dev.yab.agent

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ApprovalFooterPresentationTest {
    private val request=ApprovalRequest("owned","account","mac",1,90_000,"Claude","Pay?","Exact facts",
        kind=ApprovalKind.PAYMENT,payment=ApprovalPayment("store.test","Book","$42"),verb="Pay $42",requestDigest="facts")
    private fun shown(receipt:ApprovalReceipt?=null,retry:ApprovalReceipt?=null)=ApprovalPresented(
        ApprovalPresentationKey(request.account,0,request.mac,request.id,request.fingerprint(),0),request,receipt=receipt,retry=retry)
    private fun result(phase:ApprovalResultPhase,words:String?=null,order:String?=null)=ApprovalResult(
        request.id,request.account,request.mac,"facts",phase,words,order,1.0)
    @Test fun busyNeverFabricatesSendingAndOnlyReadyOffersTheProofAction() {
        val ready=ApprovalFooterPresentation.from(shown(),false,null)
        assertEquals("Pay $42",ready.label);assertTrue(ready.proof);assertEquals(ApprovalFooterAction.APPROVE,ready.action)
        val busy=ApprovalFooterPresentation.from(shown(),true,null)
        assertEquals(ApprovalFooterPhase.BUSY,busy.phase);assertEquals("Pay $42",busy.label)
        assertFalse(busy.proof);assertEquals(ApprovalFooterAction.NONE,busy.action)
        assertEquals(ApprovalFooterPhase.SENDING,ApprovalFooterPresentation.from(shown(ApprovalReceipt(request,1000)),false,null).phase)
    }
    @Test fun onlyActualPaymentResultsProducePayingPaidDoneAndOrderWords() {
        fun model(phase:ApprovalResultPhase,order:String?=null)=ApprovalFooterPresentation.from(shown(ApprovalReceipt(request,1000,result(phase,order=order))),false,null)
        assertEquals("This can take a few seconds",model(ApprovalResultPhase.paying).line)
        assertEquals("Order owned-order",model(ApprovalResultPhase.paid,"owned-order").line)
        assertEquals("On store.test",model(ApprovalResultPhase.paid).line)
        assertTrue(model(ApprovalResultPhase.paid).success);assertTrue(model(ApprovalResultPhase.done).success)
        assertEquals(ApprovalFooterAction.NONE,model(ApprovalResultPhase.done).action)
    }
    @Test fun declineClosesWithoutAReaskAndFreshReaskOffersItsOwnAmount() {
        val receipt=ApprovalReceipt(request,1000,result(ApprovalResultPhase.declined,"Site declined"))
        val closed=ApprovalFooterPresentation.from(shown(receipt),false,null)
        assertEquals("Close",closed.label);assertEquals(ApprovalFooterAction.CLOSE_RESULT,closed.action);assertFalse(closed.proof)
        val next=request.copy(id="new",payment=request.payment!!.copy(amount="$43"))
        val retry=ApprovalFooterPresentation.from(shown(retry=receipt).copy(request=next),false,null)
        assertEquals("Try Again · $43",retry.label);assertTrue(retry.proof);assertEquals("Site declined",retry.line)
        assertEquals(ApprovalFooterAction.APPROVE,retry.action)
    }
    @Test fun localAndRemoteFailuresOnlyOfferTheirOwnCloseAndAccountHintDoesNotPretendToSend() {
        val local=ApprovalFooterPresentation.from(shown(),false,"Owned error")
        assertEquals(ApprovalFooterAction.CLOSE_FAILURE,local.action);assertEquals("Owned error",local.line);assertFalse(local.proof)
        val remote=ApprovalFooterPresentation.from(shown(ApprovalReceipt(request,1000,result(ApprovalResultPhase.failed,"Remote error"))),false,null)
        assertEquals(ApprovalFooterAction.CLOSE_RESULT,remote.action);assertEquals("Remote error",remote.line)
        val account=shown().copy(request=request.copy(payment=null,kind=ApprovalKind.ACCOUNTS,choices=listOf("one")))
        assertTrue(ApprovalFooterPresentation.from(account,false,null).accounts)
        assertTrue(ApprovalFooterPresentation.from(account,true,null).accounts)
        val failedAccount=ApprovalFooterPresentation.from(account,false,"Failed")
        assertTrue(failedAccount.accounts);assertEquals(ApprovalFooterAction.NONE,failedAccount.action)
        assertEquals("Failed",failedAccount.line)
    }
    private class Port:AgentSyncPort {
        override val connection=MutableStateFlow(RemoteConnection("account",listOf(RemoteMac("mac","Mac",true,emptySet()))))
        override val conversations=MutableStateFlow(emptyList<RemoteConversation>())
        var answers=0
        override suspend fun send(command:AgentSendCommand)=AgentSendReceipt()
        override suspend fun stop(owner:RemoteOwner) {}
        override suspend fun delete(owner:RemoteOwner) {}
        override suspend fun answerApproval(answer:ApprovalAnswer) { answers++ }
    }
    private val failing=object:ApprovalAuthentication {
        override suspend fun authenticate(reason:String):DeviceAuthenticationProof=error("Same owned error")
    }
    private fun active()=ApprovalInteractionLifetime().also{it.resume()}
    private fun ApprovalInteractionLifetime.ticket()=checkNotNull(capture(state.value))
    @Test fun equalErrorAbaCannotReviveAnOldCloseAndFreshCloseOnlyDefersLocally()=runBlocking {
        val port=Port();val c=ApprovalController(port){1000};c.replaceValidated(listOf(request))
        val displayed=checkNotNull(c.captureDisplayed(request));val life=active()
        c.answer(request.id,true,failing,displayed=displayed)
        val old=checkNotNull(c.captureFailure(displayed))
        c.answer(request.id,true,failing,displayed=displayed)
        val fresh=checkNotNull(c.captureFailure(displayed))
        assertTrue(fresh.revision>old.revision);assertEquals("Same owned error",c.state.value.error)
        assertFalse(c.closeFailure(old,life.ticket()));assertTrue(c.state.value.deferred.isEmpty())
        assertTrue(c.closeFailure(fresh,life.ticket()));assertEquals(setOf(request.id),c.state.value.deferred)
        assertFalse(c.closeFailure(fresh,life.ticket()));assertEquals(0,port.answers)
    }
    @Test fun oldFailureCannotCloseASeparateCurrentlyBusyAuthentication()=runBlocking {
        val port=Port();val c=ApprovalController(port){1000};c.replaceValidated(listOf(request));val life=active()
        val displayed=checkNotNull(c.captureDisplayed(request));c.answer(request.id,true,failing,displayed=displayed)
        val old=checkNotNull(c.captureFailure(displayed));val release=CompletableDeferred<Unit>()
        val blocked=object:ApprovalAuthentication { override suspend fun authenticate(reason:String):DeviceAuthenticationProof {
            release.await();error("Same owned error")
        } }
        val operation=async(start=CoroutineStart.UNDISPATCHED){c.answer(request.id,true,blocked,displayed=displayed)}
        assertEquals(request.id,c.state.value.busy);assertFalse(c.closeFailure(old,life.ticket()))
        release.complete(Unit);operation.await()
        assertFalse(c.closeFailure(old,life.ticket()));assertTrue(c.closeFailure(checkNotNull(c.captureFailure(displayed)),life.ticket()))
        assertEquals(0,port.answers)
    }
    @Test fun pauseAndStopCannotBorrowFreshResumeForTheOriginalFailureClose()=runBlocking {
        val port=Port();val c=ApprovalController(port){1000};c.replaceValidated(listOf(request));val life=active()
        val displayed=checkNotNull(c.captureDisplayed(request));c.answer(request.id,true,failing,displayed=displayed)
        val failure=checkNotNull(c.captureFailure(displayed));val original=life.ticket()
        life.pause();assertFalse(c.closeFailure(failure,original));life.stop();life.resume()
        assertFalse(c.closeFailure(failure,original));assertTrue(c.closeFailure(failure,life.ticket()));assertEquals(0,port.answers)
    }
    @Test fun oldFailureCannotDeferEqualIdNewFactsOrAnAccountEpochReturn()=runBlocking {
        for(epoch in listOf(false,true)) {
            val port=Port();val c=ApprovalController(port){1000};c.replaceValidated(listOf(request));val life=active()
            val displayed=checkNotNull(c.captureDisplayed(request));c.answer(request.id,true,failing,displayed=displayed)
            val old=checkNotNull(c.captureFailure(displayed))
            val next=if(epoch)request else request.copy(summary="Changed facts")
            if(epoch)port.connection.value=port.connection.value.copy(epoch=1)
            c.replaceValidated(listOf(next));assertFalse(c.closeFailure(old,life.ticket()))
            assertTrue(c.state.value.deferred.isEmpty());assertNull(c.state.value.error);assertEquals(0,port.answers)
        }
    }
}
