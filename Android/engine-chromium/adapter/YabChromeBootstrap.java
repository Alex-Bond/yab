// Unapplied browser-process Application integration for the pinned Chromium source.
package org.chromium.chrome.browser.yab;

import android.app.Application;
import android.util.AtomicFile;

import org.chromium.base.ThreadUtils;
import org.chromium.build.annotations.NullMarked;
import org.chromium.build.annotations.Nullable;
import org.chromium.chrome.browser.profiles.Profile;
import org.chromium.chrome.browser.profiles.ProfileManager;
import org.chromium.chrome.browser.tab.Tab;
import org.chromium.chrome.browser.tab.YabNamespaceIdentity;
import org.chromium.chrome.browser.tab.YabNamespaceRuntime;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.BooleanSupplier;

/**
 * Hooks the real Chrome Application before popup/activity startup. Disk metadata is not an
 * authentication grant: Yab's native account owner must activate it before starting ChromeActivity.
 */
@NullMarked
public final class YabChromeBootstrap {
    private static @Nullable Application sApplication;
    private static @Nullable Snapshot sSnapshot;
    private static @Nullable Activation sActivation;
    private static final Map<Profile, Activation> sInstalled = new IdentityHashMap<>();
    private static @Nullable PrivateActivation sPrivateActivation;
    private static final Map<Profile, PrivateActivation> sPrivateInstalled = new IdentityHashMap<>();
    private static final Map<Profile, PrivateDestruction> sPrivateDestruction = new IdentityHashMap<>();

    private static final class PrivateActivation {
        final Activation accountOwner;
        final String epoch;
        final BooleanSupplier nativeSessionLease;
        @Nullable PrivateAccess access;
        final Set<String> usedAccessEpochs = new HashSet<>();
        boolean revoked;
        PrivateActivation(Activation owner, String epoch, BooleanSupplier lease) {
            accountOwner = owner;
            this.epoch = canonical(epoch);
            nativeSessionLease = lease;
        }
        boolean isCurrent() {
            if (revoked) return false;
            try {
                if (!accountOwner.isCurrent() || !nativeSessionLease.getAsBoolean()) revoked = true;
            } catch (RuntimeException error) {
                revoked = true;
            }
            return !revoked && sPrivateActivation == this;
        }
        boolean mayAccess() {
            return isCurrent() && access != null && access.isCurrent();
        }
    }

    private static final class PrivateAccess {
        final PrivateActivation session;
        final String epoch;
        final BooleanSupplier nativeUnlockLease;
        boolean revoked;
        PrivateAccess(PrivateActivation session, String epoch, BooleanSupplier lease) {
            this.session = session;
            this.epoch = canonical(epoch);
            nativeUnlockLease = lease;
        }
        boolean isCurrent() {
            if (revoked) return false;
            try {
                if (!session.isCurrent() || session.access != this
                        || !nativeUnlockLease.getAsBoolean()) revoked = true;
            } catch (RuntimeException error) {
                revoked = true;
            }
            return !revoked;
        }
    }

    private static final class PrivateDestruction {
        final PrivateActivation owner;
        PrivateDestruction(PrivateActivation owner) { this.owner = owner; }
    }

    private static final class Snapshot {
        final String account;
        final String epoch;
        final Map<Integer, YabNamespaceIdentity> tabs;
        Snapshot(String account, String epoch, Map<Integer, YabNamespaceIdentity> tabs) {
            this.account = canonical(account);
            this.epoch = canonical(epoch);
            this.tabs = new HashMap<>(tabs);
        }
    }

    private static final class Activation {
        final Snapshot snapshot;
        final BooleanSupplier nativeAccountLease;
        boolean revoked;
        Activation(Snapshot snapshot, BooleanSupplier lease) {
            this.snapshot = snapshot;
            nativeAccountLease = lease;
        }
        boolean isCurrent() {
            if (revoked) return false;
            try {
                if (!nativeAccountLease.getAsBoolean()) revoked = true;
            } catch (RuntimeException error) {
                revoked = true;
            }
            return !revoked && sActivation == this && sSnapshot == snapshot;
        }
    }

    private static String canonical(String id) {
        if (!UUID.fromString(id).toString().equals(id)) {
            throw new IllegalArgumentException("Owner identity must be a canonical UUID");
        }
        return id;
    }

    /** Called from ChromeApplicationImpl.onCreate, browser process only, before popup factory. */
    public static void onApplicationCreate(Application application) {
        ThreadUtils.assertOnUiThread();
        YabNamespaceRuntime.enableRequiredMode();
        if (sApplication != null) throw new IllegalStateException("Application bootstrap already ran");
        sApplication = application;
        try {
            sSnapshot = read();
        } catch (IOException | JSONException | IllegalArgumentException error) {
            // Preserve corrupt/missing bytes. No account, default jar, or transient owner fallback.
            sSnapshot = null;
        }
    }

    /** Called only after native Yab authentication/current-account ownership was established. */
    public static boolean activateSavedOwner(String account, String expectedOwnerEpoch,
            BooleanSupplier nativeAccountLease) {
        ThreadUtils.assertOnUiThread();
        // False means this call left no native activation/resources to tear down. An existing
        // owner must remain on the producer's retained-port exception path, never be forgotten.
        if (sActivation != null || !sInstalled.isEmpty() || sPrivateActivation != null
                || !sPrivateInstalled.isEmpty() || !sPrivateDestruction.isEmpty()) {
            throw new IllegalStateException("Previous native owner has not completed teardown");
        }
        Snapshot snapshot = sSnapshot;
        if (sApplication == null || snapshot == null || !snapshot.account.equals(canonical(account))
                || !snapshot.epoch.equals(canonical(expectedOwnerEpoch))
                || !nativeAccountLease.getAsBoolean()) return false;
        sActivation = new Activation(snapshot, nativeAccountLease);
        return true;
    }

    /** Explicit native new-owner operation, never used as an automatic failed-restore fallback. */
    public static void startNewOwner(String account, String ownerEpoch, BooleanSupplier lease)
            throws IOException {
        ThreadUtils.assertOnUiThread();
        if (sApplication == null || sActivation != null || !sInstalled.isEmpty()
                || sPrivateActivation != null || !sPrivateInstalled.isEmpty()
                || !sPrivateDestruction.isEmpty()
                || !lease.getAsBoolean()) throw new IllegalStateException("Previous owner is not released");
        Snapshot snapshot = new Snapshot(account, ownerEpoch, new HashMap<>());
        write(snapshot);
        sSnapshot = snapshot;
        sActivation = new Activation(snapshot, lease);
    }

    /** Called before frozen creation or fresh facade creation, not after finishNativeInitialization. */
    public static boolean ensureProfile(Profile profile) {
        ThreadUtils.assertOnUiThread();
        Application application = sApplication;
        Activation owner = sActivation;
        if (application == null || owner == null || !owner.isCurrent()
                || profile.getNativeBrowserContextPointer() == 0 || profile.shutdownStarted()) return false;
        PrivateActivation privateOwner = profile.isOffTheRecord() ? sPrivateActivation : null;
        if (profile.isOffTheRecord() && (privateOwner == null
                || privateOwner.accountOwner != owner || !privateOwner.mayAccess())) return false;
        if (sInstalled.containsKey(profile)) {
            return sInstalled.get(profile) == owner && YabNamespaceRuntime.isProfileCurrent(profile)
                    && (!profile.isOffTheRecord() || sPrivateInstalled.get(profile) == privateOwner);
        }
        if (profile.isOffTheRecord() && sPrivateInstalled.size() >= 32) return false;
        for (Profile installed : sInstalled.keySet()) {
            if (!profile.isOffTheRecord() && !installed.isOffTheRecord()) return false;
        }
        try {
            Map<Integer, YabNamespaceIdentity> expected = profile.isOffTheRecord()
                    ? new HashMap<>() : owner.snapshot.tabs;
            if (privateOwner == null) {
                YabNamespaceRuntime.install(profile, owner.snapshot.account, application.getFilesDir(),
                        owner::isCurrent, expected);
            } else {
                PrivateAccess access = privateOwner.access;
                if (access == null || !access.isCurrent()) return false;
                YabNamespaceRuntime.installPrivate(profile, owner.snapshot.account, application.getFilesDir(),
                        privateOwner::isCurrent, access.epoch, access::isCurrent, expected);
            }
            sInstalled.put(profile, owner);
            if (privateOwner != null) sPrivateInstalled.put(profile, privateOwner);
            return true;
        } catch (IOException | IllegalArgumentException | IllegalStateException error) {
            return false;
        }
    }

    /** Explicit RAM session start, not unlock. The lease covers the complete Private session lifetime. */
    public static boolean beginPrivateSession(String privateEpoch, BooleanSupplier nativeSessionLease) {
        ThreadUtils.assertOnUiThread();
        Activation owner = sActivation;
        if (sPrivateActivation != null || !sPrivateInstalled.isEmpty() || !sPrivateDestruction.isEmpty()) {
            throw new IllegalStateException("Previous Private epoch has not completed native teardown");
        }
        String epoch = canonical(privateEpoch);
        if (owner == null || !owner.isCurrent() || !nativeSessionLease.getAsBoolean()) return false;
        sPrivateActivation = new PrivateActivation(owner, epoch, nativeSessionLease);
        return true;
    }

    private static PrivateActivation requirePrivateEpoch(String expectedEpoch) {
        PrivateActivation captured = sPrivateActivation;
        if (captured == null || captured.accountOwner != sActivation
                || !captured.epoch.equals(canonical(expectedEpoch))) {
            throw new IllegalStateException("Private epoch is missing or stale");
        }
        return captured;
    }

    /** Native unlock of this retained RAM session; an old access epoch can never be revived. */
    public static boolean authorizePrivateAccess(String sessionEpoch, String accessEpoch,
            BooleanSupplier nativeUnlockLease) {
        ThreadUtils.assertOnUiThread();
        PrivateActivation captured = requirePrivateEpoch(sessionEpoch);
        String nextEpoch = canonical(accessEpoch);
        if (!captured.isCurrent() || !nativeUnlockLease.getAsBoolean()) return false;
        PrivateAccess previous = captured.access;
        if ((previous != null && previous.isCurrent()) || captured.usedAccessEpochs.contains(nextEpoch)
                || captured.usedAccessEpochs.size() >= 4096) {
            throw new IllegalStateException("Private access is active or the epoch was reused");
        }
        PrivateAccess next = new PrivateAccess(captured, nextEpoch, nativeUnlockLease);
        captured.usedAccessEpochs.add(nextEpoch);
        captured.access = next;
        try {
            for (Map.Entry<Profile, PrivateActivation> entry : sPrivateInstalled.entrySet()) {
                if (entry.getValue() != captured) throw new IllegalStateException("Mixed Private sessions");
                YabNamespaceRuntime.authorizePrivateAccess(entry.getKey(), nextEpoch, next::isCurrent);
            }
            return next.isCurrent();
        } catch (RuntimeException error) {
            // Partial authorization never makes an earlier Profile accessible after this failure.
            next.revoked = true;
            throw error;
        }
    }

    /** Ordinary lock revocation only: no Tab/Profile destruction or cookie/storage clearing. */
    public static void revokePrivateAccess(String sessionEpoch, String accessEpoch) {
        ThreadUtils.assertOnUiThread();
        PrivateActivation captured = requirePrivateEpoch(sessionEpoch);
        PrivateAccess access = captured.access;
        if (access == null || !access.epoch.equals(canonical(accessEpoch))) {
            throw new IllegalStateException("Private access epoch is missing or stale");
        }
        access.revoked = true;
        for (Map.Entry<Profile, PrivateActivation> entry : sPrivateInstalled.entrySet()) {
            if (entry.getValue() == captured) YabNamespaceRuntime.revokePrivateAccess(entry.getKey());
        }
    }

    /** Explicit session end/reset only. Ordinary Private lock must retain its RAM Profile/jar. */
    public static void endPrivateSession(String expectedEpoch) {
        ThreadUtils.assertOnUiThread();
        PrivateActivation captured = requirePrivateEpoch(expectedEpoch);
        captured.revoked = true;
        if (captured.access != null) captured.access.revoked = true;
        for (Map.Entry<Profile, PrivateActivation> entry : sPrivateInstalled.entrySet()) {
            if (entry.getValue() == captured) YabNamespaceRuntime.revokeProfile(entry.getKey());
        }
    }

    /** Request only after completed native Tab/WebContents teardown, never on request-to-close. */
    public static void requestPrivateProfileDestruction(Profile profile, String expectedEpoch) {
        ThreadUtils.assertOnUiThread();
        PrivateActivation captured = requirePrivateEpoch(expectedEpoch);
        if (!captured.revoked || !profile.isOffTheRecord()
                || sPrivateInstalled.get(profile) != captured
                || sInstalled.get(profile) != captured.accountOwner) {
            throw new IllegalStateException("Private Profile is not owned by the revoked captured epoch");
        }
        YabNamespaceRuntime.assertProfileResourcesDisposed(profile);
        if (sPrivateDestruction.containsKey(profile)) return; // Never schedule a duplicate native destroy.
        sPrivateDestruction.put(profile, new PrivateDestruction(captured));
        if (profile.getNativeBrowserContextPointer() != 0 && !profile.shutdownStarted()) {
            ProfileManager.destroyWhenAppropriate(profile); // A request, not a completion receipt.
        }
    }

    /** The native completion callback is after the complete OTR destructor has returned. */
    public static boolean isPrivateProfileDestructionComplete(Profile profile, String expectedEpoch) {
        ThreadUtils.assertOnUiThread();
        PrivateActivation captured = requirePrivateEpoch(expectedEpoch);
        PrivateDestruction destruction = sPrivateDestruction.get(profile);
        if (!captured.revoked || sPrivateInstalled.get(profile) != captured
                || destruction == null || destruction.owner != captured) return false;
        YabNamespaceRuntime.assertProfileResourcesDisposed(profile);
        return profile.getNativeBrowserContextPointer() == 0
                && profile.isYabOffTheRecordDestructionComplete();
    }

    /** False keeps outstanding exact Profiles owned. A new epoch needs a new native Profile. */
    public static boolean releasePrivateAfterTeardown(String expectedEpoch) {
        ThreadUtils.assertOnUiThread();
        canonical(expectedEpoch);
        if (sPrivateActivation == null) {
            if (!sPrivateInstalled.isEmpty() || !sPrivateDestruction.isEmpty()) {
                throw new IllegalStateException("Private resources have no captured activation");
            }
            return true;
        }
        PrivateActivation captured = requirePrivateEpoch(expectedEpoch);
        if (!captured.revoked) throw new IllegalStateException("Private owner must be revoked first");
        boolean complete = true;
        Iterator<Map.Entry<Profile, PrivateActivation>> profiles = sPrivateInstalled.entrySet().iterator();
        while (profiles.hasNext()) {
            Map.Entry<Profile, PrivateActivation> entry = profiles.next();
            Profile profile = entry.getKey();
            if (entry.getValue() != captured) throw new IllegalStateException("Mixed Private generations");
            if (!isPrivateProfileDestructionComplete(profile, expectedEpoch)) {
                complete = false;
                continue;
            }
            YabNamespaceRuntime.releaseRevokedProfile(profile);
            sInstalled.remove(profile);
            sPrivateDestruction.remove(profile);
            profiles.remove();
        }
        if (complete) sPrivateActivation = null;
        return complete;
    }

    /** Persist native-created tab mapping only after verified Chrome TabModel adoption. */
    public static void recordCreatedTab(Tab tab, YabNamespaceIdentity identity) throws IOException {
        ThreadUtils.assertOnUiThread();
        Activation owner = sActivation;
        if (owner == null || !owner.isCurrent() || sInstalled.get(tab.getProfile()) != owner
                || !identity.equals(YabNamespaceRuntime.require(tab))) {
            throw new IllegalStateException("Tab does not belong to the current native account");
        }
        if (identity.privateMode) return;
        if (!identity.accountId.equals(owner.snapshot.account)) throw new IllegalStateException("Account mismatch");
        YabNamespaceIdentity previous = owner.snapshot.tabs.get(tab.getId());
        if (previous != null && !previous.equals(identity)) throw new IllegalStateException("Chrome ID conflict");
        for (Map.Entry<Integer, YabNamespaceIdentity> entry : owner.snapshot.tabs.entrySet()) {
            if (entry.getKey() != tab.getId() && entry.getValue().tabId.equals(identity.tabId)) {
                throw new IllegalStateException("Yab UUID is already bound to another Chrome ID");
            }
        }
        owner.snapshot.tabs.put(tab.getId(), identity);
        try {
            write(owner.snapshot);
        } catch (IOException error) {
            if (previous == null) owner.snapshot.tabs.remove(tab.getId());
            else owner.snapshot.tabs.put(tab.getId(), previous);
            throw error;
        }
    }

    /** Called after confirmed TabModel close and completed native destruction, never on request. */
    public static void forgetConfirmedClosedTab(Tab destroyed, String nativeYabTabId) throws IOException {
        ThreadUtils.assertOnUiThread();
        Activation owner = sActivation;
        if (owner == null || !owner.isCurrent() || sInstalled.get(destroyed.getProfile()) != owner) {
            throw new IllegalStateException("Closed tab account owner is no longer current");
        }
        YabNamespaceIdentity identity = owner.snapshot.tabs.get(destroyed.getId());
        if (!destroyed.getProfile().isOffTheRecord()
                && (identity == null || !identity.tabId.equals(nativeYabTabId))) {
            throw new IllegalStateException("Closed tab does not match persisted native identity");
        }
        YabNamespaceRuntime.forgetAfterConfirmedClose(destroyed, nativeYabTabId);
        if (identity == null) return; // Private identity was never serialized.
        owner.snapshot.tabs.remove(destroyed.getId());
        try {
            write(owner.snapshot);
        } catch (IOException error) {
            owner.snapshot.tabs.put(destroyed.getId(), identity);
            // The per-tab record is already gone: restart rejects this stale mapping.
            throw error;
        }
    }

    /** Revoke all owners before UI hiding and teardown on logout/account replacement. */
    public static void revokeOwner() {
        ThreadUtils.assertOnUiThread();
        if (sActivation != null) sActivation.revoked = true;
        if (sPrivateActivation != null) sPrivateActivation.revoked = true;
        for (Profile profile : sInstalled.keySet()) YabNamespaceRuntime.revokeProfile(profile);
    }

    /** After all native resources are disposed. It does not clear website data. */
    public static void releaseAfterTeardown() {
        ThreadUtils.assertOnUiThread();
        if (sActivation == null) {
            if (!sInstalled.isEmpty() || sPrivateActivation != null
                    || !sPrivateInstalled.isEmpty() || !sPrivateDestruction.isEmpty()) {
                throw new IllegalStateException("Installed Profile has no activation");
            }
            return; // A throwing activation may have failed before installing any native owner.
        }
        if (sActivation.isCurrent()) throw new IllegalStateException("Owner is not revoked");
        PrivateActivation privateOwner = sPrivateActivation;
        if (privateOwner != null && !releasePrivateAfterTeardown(privateOwner.epoch)) {
            throw new IllegalStateException("Private native Profile destruction is not complete");
        }
        Iterator<Profile> profiles = sInstalled.keySet().iterator();
        while (profiles.hasNext()) {
            YabNamespaceRuntime.releaseRevokedProfile(profiles.next());
            profiles.remove();
        }
        sActivation = null;
    }

    private static AtomicFile file() {
        Application application = sApplication;
        if (application == null) throw new IllegalStateException("Application is unavailable");
        return new AtomicFile(new File(application.getFilesDir(), "yab-chrome-owner.json"));
    }

    private static Snapshot read() throws IOException, JSONException {
        try (FileInputStream stream = file().openRead()) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] chunk = new byte[4096];
            int count;
            while ((count = stream.read(chunk)) != -1) {
                if (bytes.size() + count > 4 * 1024 * 1024) throw new IOException("Owner metadata is too large");
                bytes.write(chunk, 0, count);
            }
            JSONObject root = new JSONObject(bytes.toString(StandardCharsets.UTF_8.name()));
            if (root.getInt("format") != 1) throw new IOException("Unsupported owner metadata");
            String account = canonical(root.getString("account"));
            JSONArray rows = root.getJSONArray("tabs");
            Map<Integer, YabNamespaceIdentity> tabs = new HashMap<>();
            Map<String, Integer> ids = new HashMap<>();
            for (int i = 0; i < rows.length(); ++i) {
                JSONObject row = rows.getJSONObject(i);
                int chromeId = row.getInt("chromeId");
                YabNamespaceIdentity identity = new YabNamespaceIdentity(account,
                        row.getString("tab"), row.getString("namespace"), row.getBoolean("inMemory"), false);
                if (chromeId < 0 || tabs.put(chromeId, identity) != null
                        || ids.put(identity.tabId, chromeId) != null) throw new IOException("Duplicate tab identity");
            }
            return new Snapshot(account, root.getString("epoch"), tabs);
        }
    }

    private static void write(Snapshot snapshot) throws IOException {
        AtomicFile destination = file();
        FileOutputStream stream = null;
        try {
            JSONObject root = new JSONObject();
            root.put("format", 1);
            root.put("account", snapshot.account);
            root.put("epoch", snapshot.epoch);
            JSONArray tabs = new JSONArray();
            for (Map.Entry<Integer, YabNamespaceIdentity> entry : snapshot.tabs.entrySet()) {
                YabNamespaceIdentity identity = entry.getValue();
                if (identity.privateMode || !identity.accountId.equals(snapshot.account)) {
                    throw new IOException("Refused private or foreign-account identity");
                }
                JSONObject row = new JSONObject();
                row.put("chromeId", entry.getKey());
                row.put("tab", identity.tabId);
                row.put("namespace", identity.namespaceId);
                row.put("inMemory", identity.inMemory);
                tabs.put(row);
            }
            root.put("tabs", tabs);
            stream = destination.startWrite();
            stream.write(root.toString().getBytes(StandardCharsets.UTF_8));
            destination.finishWrite(stream);
        } catch (JSONException error) {
            if (stream != null) destination.failWrite(stream);
            throw new IOException("Cannot encode owner metadata", error);
        } catch (IOException error) {
            if (stream != null) destination.failWrite(stream);
            throw error;
        }
    }
}
