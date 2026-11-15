// Unapplied source scaffold for Chromium ac19329a1d32108fd05ead15568cb6e188f8615a.
package org.chromium.chrome.browser.tab;

import org.chromium.base.ThreadUtils;
import org.chromium.build.annotations.NullMarked;
import org.chromium.build.annotations.Nullable;
import org.chromium.chrome.browser.profiles.Profile;
import org.chromium.content_public.browser.WebContents;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.Map;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.Collections;
import java.util.function.BooleanSupplier;

/** Required-mode restore gate. Every entry point is native app code on the UI thread. */
@NullMarked
public final class YabNamespaceRuntime {
    private static boolean sRequired;
    private static final Map<Profile, Scope> sScopes = new IdentityHashMap<>();
    private static final Map<WebContents, Pending> sPending = new IdentityHashMap<>();
    private static final Map<Tab, Binding> sBindings = new IdentityHashMap<>();
    private static final Map<Tab, Binding> sDestroyed = new IdentityHashMap<>();
    private static final Map<WebContents, Creation> sCreations = new IdentityHashMap<>();
    private static final Map<WebContents, Scope> sAllocations = new IdentityHashMap<>();
    private static final Map<Tab, Scope> sAllocatedTabs = new IdentityHashMap<>();
    private static final Set<Tab> sDisposalCompleted = Collections.newSetFromMap(new IdentityHashMap<>());

    private static final class PrivateAccess {
        final String epoch;
        final BooleanSupplier lease;
        boolean revoked;
        PrivateAccess(String epoch, BooleanSupplier lease) {
            if (!java.util.UUID.fromString(epoch).toString().equals(epoch)) {
                throw new IllegalArgumentException("Private access epoch must be a canonical UUID");
            }
            this.epoch = epoch;
            this.lease = lease;
        }
        boolean isCurrent() {
            if (revoked) return false;
            try {
                if (!lease.getAsBoolean()) revoked = true;
            } catch (RuntimeException error) {
                revoked = true;
            }
            return !revoked;
        }
    }

    private static final class Creation {
        final Pending pending;
        final Tab tab;
        Creation(Pending pending, Tab tab) {
            this.pending = pending;
            this.tab = tab;
        }
    }

    private static final class Scope {
        final Profile profile;
        final String account;
        final BooleanSupplier ownerLease;
        final YabNamespaceIdentity.Store store;
        final Map<Integer, YabNamespaceIdentity> expected;
        boolean revoked;
        boolean uncertainTeardown;
        String cookieEpoch = java.util.UUID.randomUUID().toString();
        @Nullable PrivateAccess privateAccess;
        final Set<String> usedPrivateAccessEpochs = new HashSet<>();

        Scope(Profile profile, String account, File files, BooleanSupplier ownerLease,
                Map<Integer, YabNamespaceIdentity> expected) throws IOException {
            this.profile = profile;
            this.account = account;
            this.ownerLease = ownerLease;
            this.store = new YabNamespaceIdentity.Store(files, account);
            this.expected = new HashMap<>(expected);
            for (YabNamespaceIdentity identity : this.expected.values()) validate(identity);
        }

        void validate(YabNamespaceIdentity identity) {
            if (!account.equals(identity.accountId)
                    || profile.isOffTheRecord() != identity.privateMode) {
                throw new IllegalArgumentException("Namespace owner does not match captured Profile");
            }
        }

        boolean isCurrent() {
            if (revoked) return false;
            try {
                if (profile.getNativeBrowserContextPointer() == 0 || profile.shutdownStarted()
                        || !ownerLease.getAsBoolean()) revoked = true;
            } catch (RuntimeException error) {
                revoked = true;
            }
            return !revoked;
        }

        boolean mayAccess() {
            return isCurrent() && (!profile.isOffTheRecord()
                    || (privateAccess != null && privateAccess.isCurrent()));
        }
    }

    private static final class Pending {
        final Scope scope;
        final YabNamespaceIdentity identity;
        Pending(Scope scope, YabNamespaceIdentity identity) {
            this.scope = scope;
            this.identity = identity;
        }
    }

    private static final class Binding {
        final Scope scope;
        final YabNamespaceIdentity identity;
        Binding(Scope scope, YabNamespaceIdentity identity) {
            this.scope = scope;
            this.identity = identity;
        }
    }

    /** Called by Yab's Application before any ChromeActivity startup or restore. No disable path. */
    public static void enableRequiredMode() {
        ThreadUtils.assertOnUiThread();
        sRequired = true;
    }

    public static boolean isRequired() {
        return sRequired;
    }

    public static boolean isProfileCurrent(Profile profile) {
        ThreadUtils.assertOnUiThread();
        return scope(profile) != null;
    }

    /** Load native Yab account/tab metadata before Chrome is allowed to restore that Profile. */
    public static void install(Profile profile, String account, File appFilesDirectory,
            BooleanSupplier ownerLease, Map<Integer, YabNamespaceIdentity> expected) throws IOException {
        ThreadUtils.assertOnUiThread();
        if (profile.isOffTheRecord()) {
            throw new IllegalArgumentException("Private needs separate session and access leases");
        }
        installInternal(profile, account, appFilesDirectory, ownerLease, expected, null);
    }

    public static void installPrivate(Profile profile, String account, File appFilesDirectory,
            BooleanSupplier sessionLease, String accessEpoch, BooleanSupplier accessLease,
            Map<Integer, YabNamespaceIdentity> expected) throws IOException {
        ThreadUtils.assertOnUiThread();
        if (!profile.isOffTheRecord()) throw new IllegalArgumentException("Not a Private Profile");
        PrivateAccess access = new PrivateAccess(accessEpoch, accessLease);
        if (!access.isCurrent()) throw new IllegalStateException("Private access is not authorized");
        installInternal(profile, account, appFilesDirectory, sessionLease, expected, access);
    }

    private static void installInternal(Profile profile, String account, File appFilesDirectory,
            BooleanSupplier ownerLease, Map<Integer, YabNamespaceIdentity> expected,
            @Nullable PrivateAccess access) throws IOException {
        ThreadUtils.assertOnUiThread();
        if (!sRequired || !ownerLease.getAsBoolean() || sScopes.containsKey(profile)) {
            throw new IllegalStateException("Required mode or a fresh owner is missing");
        }
        Scope scope = new Scope(profile, account, appFilesDirectory, ownerLease, expected);
        scope.privateAccess = access;
        if (access != null) scope.usedPrivateAccessEpochs.add(access.epoch);
        sScopes.put(profile, scope);
    }

    private static @Nullable Scope scope(Profile profile) {
        Scope scope = sScopes.get(profile);
        return scope != null && scope.mayAccess() ? scope : null;
    }

    /** Revoke access only; keep the exact native Profile, Tabs and RAM partition owned. */
    public static void revokePrivateAccess(Profile profile) {
        ThreadUtils.assertOnUiThread();
        Scope captured = sScopes.get(profile);
        if (!profile.isOffTheRecord() || captured == null) {
            throw new IllegalStateException("Private Profile has no captured session");
        }
        if (captured.privateAccess != null) captured.privateAccess.revoked = true;
        if (profile.getNativeBrowserContextPointer() != 0) WebContentsState.revokeYabCookieStores(profile);
    }

    /** Explicit native unlock only. Old facades and grants retain the old revoked epoch. */
    public static void authorizePrivateAccess(Profile profile, String accessEpoch, BooleanSupplier lease) {
        ThreadUtils.assertOnUiThread();
        Scope captured = sScopes.get(profile);
        if (!profile.isOffTheRecord() || captured == null || !captured.isCurrent()
                || (captured.privateAccess != null && captured.privateAccess.isCurrent())) {
            throw new IllegalStateException("Private session is absent or access is already active");
        }
        PrivateAccess access = new PrivateAccess(accessEpoch, lease);
        if (captured.usedPrivateAccessEpochs.contains(accessEpoch)
                || captured.usedPrivateAccessEpochs.size() >= 4096 || !access.isCurrent()) {
            throw new IllegalStateException("Private access epoch is stale or its session bound was reached");
        }
        captured.usedPrivateAccessEpochs.add(accessEpoch);
        captured.privateAccess = access;
        captured.cookieEpoch = java.util.UUID.randomUUID().toString();
    }

    /** Lifetime revoke on account replacement or Private session end; ordinary lock uses access revoke. */
    public static void revokeProfile(Profile profile) {
        ThreadUtils.assertOnUiThread();
        Scope captured = sScopes.get(profile);
        if (captured != null) captured.revoked = true;
        if (profile.getNativeBrowserContextPointer() != 0) WebContentsState.revokeYabCookieStores(profile);
    }

    /** Native extension-settings grant, never called from page URLs, messages or selected-tab inference. */
    public static String grantCookieStore(Profile callerProfile, Tab namespaceProof,
            String extensionId, boolean implicitDefault) {
        ThreadUtils.assertOnUiThread();
        Scope caller = scope(callerProfile);
        Scope target = scope(namespaceProof.getProfile());
        Binding binding = sBindings.get(namespaceProof);
        WebContents contents = namespaceProof.getWebContents();
        if (!sRequired || caller == null || target == null || binding == null
                || binding.scope != target || !caller.account.equals(target.account)
                || contents == null || !mayExpose(namespaceProof)) {
            throw new IllegalStateException("Cookie grant requires a current captured native namespace");
        }
        String granted = WebContentsState.grantYabCookieStore(callerProfile,
                namespaceProof.getProfile(), contents, extensionId, caller.account,
                caller.cookieEpoch, target.cookieEpoch, binding.identity.namespaceId,
                binding.identity.inMemory, implicitDefault);
        if (granted.isEmpty()) throw new IllegalStateException("Chrome refused the native cookie grant");
        return granted;
    }

    static boolean isCookieGrantCurrent(Profile callerProfile, Profile targetProfile,
            String account, String callerEpoch, String targetEpoch,
            String namespaceId, boolean inMemory) {
        ThreadUtils.assertOnUiThread();
        Scope caller = scope(callerProfile);
        Scope target = scope(targetProfile);
        if (!sRequired || caller == null || target == null || !caller.account.equals(account)
                || !target.account.equals(account) || !caller.cookieEpoch.equals(callerEpoch)
                || !target.cookieEpoch.equals(targetEpoch)) return false;
        for (Map.Entry<Tab, Binding> entry : sBindings.entrySet()) {
            Binding binding = entry.getValue();
            if (binding.scope == target && binding.identity.namespaceId.equals(namespaceId)
                    && binding.identity.inMemory == inMemory && mayExpose(entry.getKey())) return true;
        }
        return false;
    }

    public static boolean revokeCookieStore(Profile callerProfile, String extensionId, String storeId) {
        ThreadUtils.assertOnUiThread();
        if (scope(callerProfile) == null) return false;
        return WebContentsState.revokeYabCookieStore(callerProfile, extensionId, storeId);
    }

    /** Ownership ledger only. A revoked scope still owns allocations made before its revocation. */
    public static void reserveFactoryAllocation(Profile profile, WebContents contents) {
        ThreadUtils.assertOnUiThread();
        Scope captured = sScopes.get(profile);
        if (!sRequired || captured == null || contents.isDestroyed()
                || sAllocations.putIfAbsent(contents, captured) != null) {
            throw new IllegalStateException("Factory allocation has no unique captured owner");
        }
    }

    /** Stage only a factory-created WebContents whose native fixed partition matches identity. */
    public static void stage(Profile profile, WebContents contents, YabNamespaceIdentity identity) {
        ThreadUtils.assertOnUiThread();
        Scope scope = scope(profile);
        if (!sRequired || scope == null || contents.isDestroyed() || sAllocations.get(contents) != scope) {
            throw new IllegalStateException("Native namespace owner is unavailable");
        }
        scope.validate(identity);
        for (YabNamespaceIdentity existing : scope.expected.values()) {
            if (existing.tabId.equals(identity.tabId)) {
                throw new IllegalStateException("Yab tab identity already belongs to a Chrome tab");
            }
        }
        if (!WebContentsState.matchesYabNamespace(
                profile, contents, identity.namespaceId, identity.inMemory)) {
            throw new IllegalStateException("Factory WebContents belongs to another partition");
        }
        if (sPending.putIfAbsent(contents, new Pending(scope, identity)) != null) {
            throw new IllegalStateException("WebContents is already staged");
        }
    }

    public static void discardStaged(WebContents contents) {
        ThreadUtils.assertOnUiThread();
        Scope captured = sAllocations.get(contents);
        if (captured != null && captured.uncertainTeardown) return;
        Creation creation = sCreations.get(contents);
        if (!contents.isDestroyed() || (creation != null && !isDisposalComplete(creation.tab))) {
            return; // A failed cleanup remains in the ledger and blocks Profile reuse.
        }
        sPending.remove(contents);
        sCreations.remove(contents);
        sAllocations.remove(contents);
    }

    /** Contradictory native ownership requires explicit process/host recovery, never guessed disposal. */
    public static void retainUncertainFactoryOwner(WebContents contents) {
        ThreadUtils.assertOnUiThread();
        Scope captured = sAllocations.get(contents);
        if (captured != null) {
            captured.uncertainTeardown = true;
            revokeProfile(captured.profile);
        }
    }

    /** TabBuilder calls immediately after allocation, before window attachment or lease evaluation. */
    static void onTabAllocated(Tab tab, @Nullable WebContents contents) {
        ThreadUtils.assertOnUiThread();
        if (!sRequired) return;
        Scope captured = sScopes.get(tab.getProfile());
        if (captured == null) throw new IllegalStateException("Allocated Tab has no captured native owner");
        sAllocatedTabs.put(tab, captured); // A revoked scope still owns its uninitialized native helpers.
        Pending pending = contents == null ? null : sPending.get(contents);
        if (contents != null && pending != null && sAllocations.get(contents) == pending.scope) {
            Creation previous = sCreations.putIfAbsent(contents, new Creation(pending, tab));
            if (previous != null && previous.tab != tab) {
                retainUncertainFactoryOwner(contents);
                throw new IllegalStateException("Factory contents has multiple temporary Tab owners");
            }
        }
    }

    /** Only the successful tail of pinned TabImpl.destroyInternal may issue this completion marker. */
    static void onNativeDisposalCompleted(Tab tab, boolean deleteNativeWebContents) {
        ThreadUtils.assertOnUiThread();
        if (!sRequired) return;
        Scope captured = sAllocatedTabs.get(tab);
        if (captured == null) return;
        if (!deleteNativeWebContents) {
            // Native TakeWebContentsAndDestroyTab transfers a still-live WebContents elsewhere.
            // A transfer requires its own owner handoff proof; null Tab fields are not disposal.
            captured.uncertainTeardown = true;
            revokeProfile(captured.profile);
            return;
        }
        if (!tab.isDestroyed() || tab.isInitialized() || tab.getWebContents() != null
                || tab.getWebContentsState() != null) {
            throw new IllegalStateException("Tab destruction returned before native disposal");
        }
        Binding retired = sBindings.remove(tab);
        if (retired != null) sDestroyed.put(tab, retired);
        sDisposalCompleted.add(tab);
    }

    public static boolean isDisposalComplete(Tab tab) {
        ThreadUtils.assertOnUiThread();
        return sDisposalCompleted.contains(tab) && tab.isDestroyed() && !tab.isInitialized()
                && tab.getWebContents() == null && tab.getWebContentsState() == null;
    }

    /** Only after the facade has verified actual TabModel adoption, including another window. */
    public static void confirmFactoryAdopted(WebContents contents, Tab tab) {
        ThreadUtils.assertOnUiThread();
        if (!sAllocations.containsKey(contents)) return;
        Creation creation = sCreations.get(contents);
        Binding binding = sBindings.get(tab);
        if (creation == null || creation.tab != tab || binding == null
                || binding.scope != creation.pending.scope || tab.getWebContents() != contents) {
            throw new IllegalStateException("Factory allocation was not adopted by its captured Tab");
        }
        sPending.remove(contents);
        sCreations.remove(contents);
        sAllocations.remove(contents); // Its verified TabModel/binding now owns disposal.
    }

    /** Native teardown can retry a failed allocation cleanup after the creation call has returned. */
    public static List<WebContents> pendingFactoryDisposal(Profile profile) {
        ThreadUtils.assertOnUiThread();
        List<WebContents> pending = new ArrayList<>();
        Scope captured = sScopes.get(profile);
        if (captured == null) return pending;
        for (Map.Entry<WebContents, Scope> entry : sAllocations.entrySet()) {
            if (entry.getValue() == captured) pending.add(entry.getKey());
        }
        return pending;
    }

    /** Includes a failed restored builder with no returned Tab or factory WebContents. */
    public static List<Tab> allocatedTabResources(Profile profile) {
        ThreadUtils.assertOnUiThread();
        List<Tab> allocated = new ArrayList<>();
        Scope captured = sScopes.get(profile);
        if (captured == null) return allocated;
        for (Map.Entry<Tab, Scope> entry : sAllocatedTabs.entrySet()) {
            if (entry.getValue() == captured) allocated.add(entry.getKey());
        }
        return allocated;
    }

    /** Includes a Tab whose initialize() threw before createTabWithWebContents returned. */
    public static @Nullable Tab creationOwner(WebContents contents) {
        ThreadUtils.assertOnUiThread();
        Creation creation = sCreations.get(contents);
        return creation == null ? null : creation.tab;
    }

    /** Only for an unsuccessful creation whose factory contents and temporary Tab are disposed. */
    public static void abandonDisposedCreation(WebContents contents) {
        ThreadUtils.assertOnUiThread();
        Creation creation = sCreations.get(contents);
        if (!contents.isDestroyed() || (creation != null && !isDisposalComplete(creation.tab))) {
            throw new IllegalStateException("Creation still has a native owner");
        }
        if (creation == null) {
            discardStaged(contents);
            return;
        }
        Scope captured = creation.pending.scope;
        if (creation.pending.identity.equals(captured.expected.get(creation.tab.getId()))) {
            if (!creation.pending.identity.privateMode) captured.store.remove(creation.tab.getId());
            captured.expected.remove(creation.tab.getId());
        }
        sBindings.remove(creation.tab);
        sDestroyed.remove(creation.tab);
        discardStaged(contents);
        sAllocatedTabs.remove(creation.tab);
        sDisposalCompleted.remove(creation.tab);
    }

    /** Hook in TabBuilder immediately before Tab.initialize, never after first navigation. */
    public static void beforeInitialize(Tab tab, @Nullable WebContents contents, @Nullable TabState state) {
        ThreadUtils.assertOnUiThread();
        if (!sRequired) return;
        Scope scope = scope(tab.getProfile());
        if (scope == null) throw new IllegalStateException("No native namespace owner");
        YabNamespaceIdentity identity;
        if (contents != null) {
            Pending pending = sPending.remove(contents);
            if (pending == null || pending.scope != scope) {
                throw new IllegalStateException("Unowned WebContents cannot become a Yab tab");
            }
            Creation creation = sCreations.get(contents);
            if (creation == null || creation.tab != tab || creation.pending != pending) {
                throw new IllegalStateException("Temporary Tab allocation was not reserved before initialization");
            }
            identity = pending.identity;
            if (scope.expected.containsKey(tab.getId())) {
                throw new IllegalStateException("Chrome tab ID still has a durable owner");
            }
            if (!identity.privateMode) {
                try {
                    scope.store.write(tab.getId(), identity, "UNSEALED");
                } catch (IOException error) {
                    throw new IllegalStateException("Identity must be durable before Tab initialization", error);
                }
            }
            scope.expected.put(tab.getId(), identity);
        } else {
            if (state == null || !canRestore(tab.getProfile(), tab.getId(), state)) {
                throw new IllegalStateException("Missing or mismatched durable namespace identity");
            }
            identity = scope.expected.get(tab.getId());
            if (identity == null) throw new IllegalStateException("Expected tab identity is absent");
        }
        sBindings.put(tab, new Binding(scope, identity));
        tab.addObserver(new TabObserver() {
            @Override
            public void onDestroyed(Tab destroyed) {
                // Destruction during host teardown is not proof of an intentional user close.
                // Keep durable identity until the host confirms closure, not beforeunload request.
                Binding binding = sBindings.remove(destroyed);
                if (binding != null) sDestroyed.put(destroyed, binding);
            }
        });
    }

    public static boolean canRestore(Profile profile, int chromeId, TabState state) {
        ThreadUtils.assertOnUiThread();
        if (!sRequired) return true;
        Scope scope = scope(profile);
        YabNamespaceIdentity identity = scope == null ? null : scope.expected.get(chromeId);
        return scope != null && identity != null && !identity.privateMode
                && state.contentsState != null
                && scope.store.matches(chromeId, identity, digest(state.contentsState));
    }

    /** Use before paint preview, lazy load and every adapter operation, including after account switch. */
    public static boolean mayExpose(Tab tab) {
        ThreadUtils.assertOnUiThread();
        if (!sRequired) return true;
        Binding binding = sBindings.get(tab);
        if (tab.isDestroyed() || binding == null || scope(tab.getProfile()) != binding.scope) return false;
        WebContents contents = tab.getWebContents();
        if (contents != null && !WebContentsState.matchesYabNamespace(tab.getProfile(), contents,
                binding.identity.namespaceId, binding.identity.inMemory)) return false;
        WebContentsState frozen = tab.getWebContentsState();
        return frozen == null || (!binding.identity.privateMode && binding.scope.store.matches(
                tab.getId(), binding.identity, digest(frozen)));
    }

    public static YabNamespaceIdentity require(Tab tab) {
        if (!sRequired || !mayExpose(tab)) throw new IllegalStateException("Namespace lease is stale");
        Binding binding = sBindings.get(tab);
        if (binding == null) throw new IllegalStateException("Namespace binding is absent");
        return binding.identity;
    }

    /** Capture on native facade/bridge creation; a later unlock never revives an old handle. */
    public static String captureAccessEpoch(Tab tab) {
        ThreadUtils.assertOnUiThread();
        require(tab);
        Scope current = scope(tab.getProfile());
        if (current == null) throw new IllegalStateException("No current native access epoch");
        return current.cookieEpoch;
    }

    public static boolean isAccessEpochCurrent(Tab tab, String capturedEpoch) {
        ThreadUtils.assertOnUiThread();
        Scope current = scope(tab.getProfile());
        return current != null && current.cookieEpoch.equals(capturedEpoch) && mayExpose(tab);
    }

    /** TabStateExtractor calls this on its owned ref-counted snapshot before it can be persisted. */
    public static boolean seal(Tab tab, @Nullable WebContentsState state) {
        ThreadUtils.assertOnUiThread();
        if (!sRequired) return true;
        if (state == null || !mayExpose(tab)) return false;
        Binding binding = sBindings.get(tab);
        if (binding == null || binding.identity.privateMode) return false;
        // Never bless a substituted frozen buffer by hashing it as if freshly extracted.
        if (tab.getWebContents() == null) {
            return binding.scope.store.matches(tab.getId(), binding.identity, digest(state));
        }
        try {
            binding.scope.store.write(tab.getId(), binding.identity, digest(state));
            return true;
        } catch (IOException error) {
            return false;
        }
    }

    /** The caller must have observed confirmed TabModel closure and actual Tab destruction. */
    public static void forgetAfterConfirmedClose(Tab destroyed, String yabTabId) {
        ThreadUtils.assertOnUiThread();
        if (!isDisposalComplete(destroyed)) {
            throw new IllegalStateException("Native Tab destruction has not completed");
        }
        int chromeId = destroyed.getId();
        Scope scope = scope(destroyed.getProfile());
        if (scope == null) throw new IllegalStateException("No current account owner");
        Binding retired = sDestroyed.get(destroyed);
        YabNamespaceIdentity identity = scope.expected.get(chromeId);
        if (retired == null || retired.scope != scope || identity == null
                || !identity.equals(retired.identity) || !identity.tabId.equals(yabTabId)) {
            throw new IllegalStateException("Closed tab identity does not match");
        }
        for (Map.Entry<Tab, Binding> entry : sBindings.entrySet()) {
            if (entry.getValue().scope == scope && entry.getKey().getId() == chromeId) {
                throw new IllegalStateException("A live tab still owns this identity");
            }
        }
        if (!identity.privateMode) scope.store.remove(chromeId);
        scope.expected.remove(chromeId);
        sDestroyed.remove(destroyed);
        sAllocatedTabs.remove(destroyed);
        sDisposalCompleted.remove(destroyed);
        // This removes only tab metadata, never a shared namespace's cookies or storage.
    }

    private static Scope requireDisposedRevokedProfile(Profile profile) {
        ThreadUtils.assertOnUiThread();
        Scope captured = sScopes.get(profile);
        if (captured == null || captured.isCurrent()) {
            throw new IllegalStateException("Profile owner must be revoked first");
        }
        if (captured.uncertainTeardown) throw new IllegalStateException("Native ownership requires process recovery");
        for (Map.Entry<Tab, Scope> entry : sAllocatedTabs.entrySet()) {
            if (entry.getValue() == captured && !isDisposalComplete(entry.getKey())) {
                throw new IllegalStateException("Profile still owns an incompletely destroyed allocated Tab");
            }
        }
        for (Binding binding : sBindings.values()) {
            if (binding.scope == captured) throw new IllegalStateException("Profile still owns a live tab");
        }
        for (Map.Entry<Tab, Binding> entry : sDestroyed.entrySet()) {
            if (entry.getValue().scope == captured && !isDisposalComplete(entry.getKey())) {
                throw new IllegalStateException("Profile native destruction is not complete");
            }
        }
        for (Map.Entry<WebContents, Pending> entry : sPending.entrySet()) {
            if (entry.getValue().scope == captured && !entry.getKey().isDestroyed()) {
                throw new IllegalStateException("Profile still owns pending WebContents");
            }
        }
        for (Map.Entry<WebContents, Scope> entry : sAllocations.entrySet()) {
            if (entry.getValue() != captured) continue;
            Creation creation = sCreations.get(entry.getKey());
            if (!entry.getKey().isDestroyed() || (creation != null && !isDisposalComplete(creation.tab))) {
                throw new IllegalStateException("Profile still owns a failed factory allocation");
            }
        }
        return captured;
    }

    /** Check before requesting native OTR Profile destruction; no scope is removed by this call. */
    public static void assertProfileResourcesDisposed(Profile profile) {
        ThreadUtils.assertOnUiThread();
        requireDisposedRevokedProfile(profile);
    }

    /** Revoke the owner first, close every tab, then release this captured Profile for a new epoch. */
    public static void releaseRevokedProfile(Profile profile) {
        ThreadUtils.assertOnUiThread();
        Scope captured = requireDisposedRevokedProfile(profile);
        sDestroyed.entrySet().removeIf(entry -> entry.getValue().scope == captured);
        sPending.entrySet().removeIf(entry -> entry.getValue().scope == captured);
        sCreations.entrySet().removeIf(entry -> entry.getValue().pending.scope == captured);
        sAllocations.entrySet().removeIf(entry -> entry.getValue() == captured);
        sAllocatedTabs.entrySet().removeIf(entry -> {
            if (entry.getValue() != captured) return false;
            sDisposalCompleted.remove(entry.getKey());
            return true;
        });
        sScopes.remove(profile);
        // Durable namespace identities survive owner release; this is not a data-clear operation.
    }

    private static String digest(WebContentsState state) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            // Include serialized format; do not mutate buffer position or ref-count ownership.
            digest.update(ByteBuffer.allocate(4).putInt(state.version()).array());
            ByteBuffer buffer = state.buffer().asReadOnlyBuffer();
            buffer.clear();
            digest.update(buffer);
            StringBuilder text = new StringBuilder(64);
            for (byte value : digest.digest()) {
                text.append(Character.forDigit((value >>> 4) & 15, 16));
                text.append(Character.forDigit(value & 15, 16));
            }
            return text.toString();
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException("SHA-256 is required", error);
        }
    }
}
