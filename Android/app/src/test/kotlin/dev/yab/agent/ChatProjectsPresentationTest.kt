package dev.yab.agent

import dev.yab.core.sync.SyncProject
import org.junit.Assert.*
import org.junit.Test

class ChatProjectsPresentationTest {
    private fun project(id: String = "prj-one", pinned: Boolean = false, archived: Boolean = false) =
        SyncProject(id, id, "", "blue", pinned = pinned, archived = archived, order = "", created = 0.0, updated = 0.0)
    private class Scene {
        var live = true
        var connection = RemoteConnection("account", epoch = 7)
        var snapshot = ChatProjectsSnapshot("account", "phone", 7, listOf(SyncProject("prj-one", "One", "", "blue", order = "", created = 0.0, updated = 0.0)))
        val flow = ChatProjectsPresentation()
        fun open() = flow.open(snapshot, connection, "prj-one") { live }
        fun control() = flow.control(snapshot, { connection }, { snapshot })!!
    }
    @Test fun cardsUseNewestMemberRankAndStableEmptyProjectOrder() {
        val chats = listOf(AgentChat("a", project = "prj-two"), AgentChat("loose"), AgentChat("b", project = "prj-one"))
        val projects = listOf(project(), project("prj-two"), project("prj-empty"), project("prj-last"))
        val cards = FieldChatGroups.projectCards(chats, chats, projects)
        assertEquals(listOf("prj-two", "loose", "prj-one", "prj-empty", "prj-last"), cards.map { when(it) {
            is FieldProjectCard.Chat -> it.chat.id; is FieldProjectCard.Project -> it.project.id
        } })
        assertEquals(listOf("a"), (cards.first() as FieldProjectCard.Project).chats.map { it.id })
    }
    @Test fun pinnedMembersStayInTheirCircleAndUnknownArchivedReferencesStayVisible() {
        val chats = listOf(AgentChat("p", project = "prj-pin"), AgentChat("unknown", project = "prj-missing"),
            AgentChat("old", project = "prj-old"), AgentChat("nil"))
        val cards = FieldChatGroups.projectCards(chats, chats, listOf(project("prj-pin", pinned = true), project("prj-old", archived = true)))
        assertEquals(listOf("unknown", "old", "nil"), cards.map { (it as FieldProjectCard.Chat).chat.id })
    }
    @Test fun projectMemberRankIncludesTaskAndRoutineChatsWithoutMovingLooseGroups() {
        val task = AgentChat("task", origin = "command", project = "prj-one")
        val routine = AgentChat("routine", routine = "r", project = "prj-one")
        val loose = AgentChat("loose")
        val all = listOf(task, routine, loose)
        val known = setOf("prj-one")
        val groups = FieldChatGroups.read(all.filter { it.project !in known })
        assertEquals(listOf(loose), groups.single().chats)
        val cards = FieldChatGroups.projectCards(groups.single().chats, all, listOf(project()))
        assertEquals(listOf(task, routine), (cards.first() as FieldProjectCard.Project).chats)
    }
    @Test fun metadataReplacesControlsButKeepsPresenceCoverAndDraft() {
        val s = Scene(); assertTrue(s.open()); val old = s.control(); val owner = s.flow.frame.value!!.owner
        assertTrue(s.flow.draft(old, "unfinished"))
        s.snapshot = ChatProjectsSnapshot.publish(s.snapshot, "account", "phone", 7, listOf(s.snapshot.projects.single().copy(name = "Renamed")))
        s.flow.observe(s.snapshot, s.connection)
        assertSame(owner, s.flow.frame.value!!.owner); assertEquals("unfinished", s.flow.draft.value)
        assertFalse(s.flow.close(old)); assertTrue(s.flow.draft(s.control(), "continued")); assertEquals("continued", s.flow.draft.value)
    }
    @Test fun removalAndReadditionBeforeObservationNeverRevivesOldCover() {
        val s = Scene(); assertTrue(s.open()); val old = s.control()
        s.snapshot = ChatProjectsSnapshot.publish(s.snapshot, "account", "phone", 7, emptyList())
        s.snapshot = ChatProjectsSnapshot.publish(s.snapshot, "account", "phone", 7, listOf(project()))
        assertFalse(old.current()); s.flow.observe(s.snapshot, s.connection); assertNull(s.flow.frame.value)
        assertTrue(s.open()); assertFalse(s.flow.close(old)); assertNotNull(s.flow.frame.value)
    }
    @Test fun originalHostFailureIsPermanentAndCannotCloseFreshCover() {
        val s = Scene(); assertTrue(s.open()); val old = s.control()
        s.live = false; assertFalse(old.current()); s.flow.observe(s.snapshot, s.connection)
        s.live = true; assertTrue(s.open()); assertFalse(s.flow.info(old, true)); assertNotNull(s.flow.frame.value)
    }
    @Test fun accountDeviceAndEpochReplacementRetireOriginalOwner() {
        for (replacement in listOf(Triple("other", "phone", 7L), Triple("account", "new-phone", 7L), Triple("account", "phone", 8L))) {
            val s = Scene(); assertTrue(s.open()); val old = s.control()
            s.snapshot = ChatProjectsSnapshot.publish(s.snapshot, replacement.first, replacement.second, replacement.third, listOf(project()))
            s.connection = RemoteConnection(replacement.first, epoch = replacement.third)
            assertFalse(s.flow.close(old)); s.flow.observe(s.snapshot, s.connection); assertNull(s.flow.frame.value)
        }
    }
    @Test fun infoBackFocusAndDraftHaveSeparateOriginalActionPhases() {
        val s = Scene(); assertTrue(s.open()); val page = s.control(); assertTrue(s.flow.draft(page, "one")); assertTrue(s.flow.draft(page, "two"))
        assertTrue(s.flow.info(page, true)); assertFalse(s.flow.draft(page, "stale"))
        val info = s.control(); assertFalse(s.flow.draft(info, "hidden")); assertTrue(s.flow.info(info, false, focus = true))
        assertFalse(s.flow.close(info)); assertEquals(1L, s.flow.frame.value!!.focus); assertEquals("two", s.flow.draft.value)
    }
    @Test fun reopeningSameProjectIsNewOwnerAndResetsOnlyThatNewDraft() {
        val s = Scene(); assertTrue(s.open()); val old = s.control(); assertTrue(s.flow.draft(old, "old"))
        assertTrue(s.open()); assertEquals("", s.flow.draft.value); val fresh = s.control(); assertTrue(s.flow.draft(fresh, "new"))
        assertFalse(s.flow.clearDraft(old)); assertFalse(s.flow.close(old)); assertEquals("new", s.flow.draft.value)
    }
    @Test fun nestedChatReturnsToItsOriginalProjectWithoutDiscardingDraft() {
        val s = Scene(); assertTrue(s.open()); val page = s.control(); assertTrue(s.flow.draft(page, "project words"))
        val chat = AgentChat("chat", project = "prj-one", owner = RemoteOwner("account", "mac", "a:chat", AgentProvider.CLAUDE))
        assertTrue(s.flow.conversation(page, chat)); val nested = s.flow.frame.value!!
        assertTrue(s.flow.conversationCurrent(nested, chat.copy(title = "Updated", messages = listOf(AgentMessage("m", MessageRole.ASSISTANT, "Answer", 1))), s.snapshot, s.connection))
        assertFalse(s.flow.info(page, true)); val back = s.control(); assertTrue(s.flow.backFromChat(back))
        assertEquals("prj-one", s.flow.frame.value!!.project); assertNull(s.flow.frame.value!!.conversation)
        assertFalse(s.flow.backFromChat(back)); assertEquals("project words", s.flow.draft.value)
    }
    @Test fun nestedChatRejectsForeignReplacementAndCannotReviveAfterObservedLoss() {
        val s = Scene(); assertTrue(s.open()); val chat = AgentChat("chat", project = "prj-one", owner = RemoteOwner("account", "mac", "a:c", AgentProvider.CLAUDE))
        assertTrue(s.flow.conversation(s.control(), chat)); val frame = s.flow.frame.value!!
        assertFalse(s.flow.conversationCurrent(frame, chat.copy(owner = chat.owner!!.copy(account = "other")), s.snapshot, s.connection))
        assertFalse(s.flow.conversationCurrent(frame, chat, s.snapshot, s.connection))
    }
    @Test fun freshProjectDraftCanAdoptOneOriginalAccountMacOwnerButCannotChangeItAgain() {
        val s = Scene(); assertTrue(s.open()); val draft = AgentChat("new", ephemeral = true, forceMac = true, project = "prj-one")
        assertTrue(s.flow.conversation(s.control(), draft)); val frame = s.flow.frame.value!!
        assertTrue(s.flow.conversationCurrent(frame, draft, s.snapshot, s.connection))
        val owned = draft.copy(owner = RemoteOwner("account", "mac", "a:new", AgentProvider.CLAUDE))
        assertTrue(s.flow.conversationCurrent(frame, owned, s.snapshot, s.connection))
        assertFalse(s.flow.conversationCurrent(frame, owned.copy(owner = owned.owner!!.copy(mac = "another")), s.snapshot, s.connection))
        assertFalse(s.flow.conversationCurrent(frame, owned, s.snapshot, s.connection))
    }
    @Test fun privateOrForeignChatCannotBeOpenedOverOriginalProject() {
        val s = Scene(); assertTrue(s.open()); val control = s.control()
        assertFalse(s.flow.conversation(control, AgentChat("private", privateOrigin = true)))
        assertFalse(s.flow.conversation(control, AgentChat("foreign", owner = RemoteOwner("other", "mac", "a:x", AgentProvider.CLAUDE))))
        assertNull(s.flow.frame.value!!.conversation)
    }
    @Test fun originalMonotonicHostScopeRejectsUnobservedForegroundAndCoverAba() {
        val s = Scene(); var generation = 1
        val captured = generation
        assertTrue(s.flow.open(s.snapshot, s.connection, "prj-one") { generation == captured })
        val old = s.control(); generation++; generation++
        assertFalse(old.current()); assertFalse(s.flow.draft(old, "after ABA")); s.flow.observe(s.snapshot, s.connection); assertNull(s.flow.frame.value)
    }
    @Test fun navigationRevisionIsPublishedBeforeEveryFrameAndCapturesFastOpenCloseAba() {
        val s = Scene(); val original = s.flow.revision.value
        assertTrue(s.open()); val opened = s.flow.revision.value; assertTrue(opened > original)
        val page = s.control(); assertTrue(s.flow.draft(page, "draft")); assertEquals(opened, s.flow.revision.value)
        assertTrue(s.flow.close(page)); assertNull(s.flow.frame.value); assertTrue(s.flow.revision.value > opened)
        val closed = s.flow.revision.value; assertFalse(s.flow.close(page)); assertEquals(closed, s.flow.revision.value)
        assertTrue(s.open()); val fresh = s.control(); assertTrue(s.flow.info(fresh, true)); assertTrue(s.flow.revision.value > closed)
        val info = s.control(); val before = s.flow.revision.value; assertTrue(s.flow.info(info, true)); assertEquals(before, s.flow.revision.value)
        s.live = false; s.flow.observe(s.snapshot, s.connection); assertNull(s.flow.frame.value); assertTrue(s.flow.revision.value > before)
    }

    @Test fun approvalRetiresOnlyOriginalActionsAndFreshCancelSourceKeepsCoverAndDraft() {
        val s = Scene(); assertTrue(s.open()); val owner = s.flow.frame.value!!.owner
        var allowed = true
        val old = s.flow.control(s.snapshot, { s.connection }, { s.snapshot }) { allowed }!!
        assertTrue(s.flow.draft(old, "keep through approval"))
        allowed = false; assertFalse(old.current()); s.flow.observe(s.snapshot, s.connection)
        assertSame(owner, s.flow.frame.value!!.owner); assertEquals("keep through approval", s.flow.draft.value)
        allowed = true; assertFalse(s.flow.close(old))
        val fresh = s.flow.control(s.snapshot, { s.connection }, { s.snapshot }) { allowed }!!
        assertTrue(s.flow.draft(fresh, "after cancel")); assertSame(owner, s.flow.frame.value!!.owner)
        assertEquals("after cancel", s.flow.draft.value); assertTrue(s.flow.info(fresh, true))
    }
    @Test fun logicalMenuPhasesRetireSavedControlsWhileOrdinaryDraftUpdatesKeepTheirSource() {
        var phase = 0L
        val menu = ProjectLocalState(false) { phase++ }
        val captured = phase
        val old = ProjectUiLifetime { phase == captured }
        var draft = "first"; assertTrue(old.current()); draft = "second"; assertTrue(old.current())
        menu.value = true; assertFalse(old.current()); assertEquals(1L, phase)
        menu.value = true; assertEquals(1L, phase)
        menu.value = false; menu.value = true
        assertEquals(3L, phase); assertFalse(old.current()); assertEquals("second", draft)
        val current = phase; val fresh = ProjectUiLifetime { phase == current }; assertTrue(fresh.current())
        menu.value = false; assertFalse(fresh.current())
    }

}
