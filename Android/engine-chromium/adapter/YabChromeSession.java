// Source scaffold for Chromium ac19329a1d32108fd05ead15568cb6e188f8615a.
// Not compiled, applied, or used by the active upstream baseline build.
package org.chromium.chrome.browser.yab;

import android.view.View;

import org.chromium.base.ThreadUtils;
import org.chromium.build.annotations.NullMarked;
import org.chromium.build.annotations.Nullable;
import org.chromium.chrome.browser.app.ChromeActivity;
import org.chromium.chrome.browser.app.tabwindow.TabWindowManagerSingleton;
import org.chromium.chrome.browser.compositor.CompositorViewHolder;
import org.chromium.chrome.browser.content.WebContentsFactory;
import org.chromium.chrome.browser.init.ChromeBrowserInitializer;
import org.chromium.chrome.browser.profiles.Profile;
import org.chromium.chrome.browser.tab.Tab;
import org.chromium.chrome.browser.tab.TabLaunchType;
import org.chromium.chrome.browser.tab.TabSelectionType;
import org.chromium.chrome.browser.tab.TabObserver;
import org.chromium.chrome.browser.tab.TabUtils;
import org.chromium.chrome.browser.tab.YabNamespaceIdentity;
import org.chromium.chrome.browser.tab.YabNamespaceRuntime;
import org.chromium.chrome.browser.tabmodel.TabClosureParams;
import org.chromium.chrome.browser.tabmodel.TabModel;
import org.chromium.chrome.browser.tabmodel.TabModelActionListener;
import org.chromium.components.browser_ui.widget.ActionConfirmationResult;
import org.chromium.content_public.browser.LoadUrlParams;
import org.chromium.content_public.browser.WebContents;
import org.chromium.ui.base.WindowAndroid;

import java.util.Objects;
import java.util.concurrent.CompletableFuture;
import java.util.function.BooleanSupplier;

/**
 * A native-owner facade over a real Chrome Tab, not a WebView or content shell.
 *
 * The host must retain the normal ChromeActivity initialization, TabModel,
 * delegates and compositor hierarchy. The lease must be owned by native app
 * state and revoked on host/account/namespace replacement or Private lock.
 * No method of this class is a page JavaScript interface.
 */
@NullMarked
public final class YabChromeSession {
    private final ChromeActivity mActivity;
    private final WindowAndroid mWindow;
    private final CompositorViewHolder mSurface;
    private final Profile mProfile;
    private final TabModel mModel;
    private final Tab mTab;
    private final WebContents mContents;
    private final BooleanSupplier mOwnerLease;
    private final String mAccessEpoch;
    private boolean mClosePending;
    private boolean mTornDown;

    private YabChromeSession(ChromeActivity activity, WindowAndroid window,
            CompositorViewHolder surface, Profile profile, TabModel model,
            Tab tab, WebContents contents, BooleanSupplier ownerLease) {
        mActivity = activity;
        mWindow = window;
        mSurface = surface;
        mProfile = profile;
        mModel = model;
        mTab = tab;
        mContents = contents;
        mOwnerLease = ownerLease;
        mAccessEpoch = YabNamespaceRuntime.captureAccessEpoch(tab);
        tab.addObserver(new TabObserver() {
            @Override
            public void onClosingStateChanged(Tab observed, boolean closing) {
                if (!closing) mClosePending = false;
            }

            @Override
            public void onDestroyed(Tab observed) {
                mTornDown = true;
                mClosePending = false;
            }
        });
    }

    /** Call after the host's native initialization and selected TabModel are ready. */
    public static YabChromeSession create(ChromeActivity activity, Profile profile,
            YabNamespaceIdentity identity, BooleanSupplier ownerLease) {
        ThreadUtils.assertOnUiThread();
        Objects.requireNonNull(ownerLease);
        if (!ownerLease.getAsBoolean() || activity.isFinishing() || activity.isDestroyed()
                || !ChromeBrowserInitializer.getInstance().isFullBrowserInitialized()
                || !YabChromeBootstrap.ensureProfile(profile)) {
            throw new IllegalStateException("Chrome host or native owner is not ready");
        }
        WindowAndroid window = Objects.requireNonNull(activity.getWindowAndroid());
        CompositorViewHolder surface = Objects.requireNonNull(
                activity.getCompositorViewHolderSupplier().get());
        TabModel model = activity.getTabModelSelector().getModel(profile.isOffTheRecord());
        if (model.getProfile() != profile) {
            throw new IllegalStateException("Chrome model does not own the captured Profile");
        }
        WebContents contents = WebContentsFactory.createWebContentsForYabNamespace(
                profile, identity.namespaceId, identity.inMemory);
        try {
            YabNamespaceRuntime.reserveFactoryAllocation(profile, contents);
            YabNamespaceRuntime.stage(profile, contents, identity);
            Tab tab = activity.getTabCreator(profile.isOffTheRecord()).createTabWithWebContents(
                    null, false, contents, TabLaunchType.FROM_CHROME_UI,
                    CompletableFuture.completedFuture(true));
            if (tab == null || tab.getWebContents() != contents || model.indexOf(tab) < 0) {
                throw new IllegalStateException("Chrome did not adopt the factory contents into its TabModel");
            }
            YabNamespaceRuntime.confirmFactoryAdopted(contents, tab);
            try {
                YabChromeBootstrap.recordCreatedTab(tab, identity);
            } catch (java.io.IOException error) {
                throw new IllegalStateException("Cannot persist the native owner tab mapping", error);
            }
            return new YabChromeSession(activity, window, surface, profile, model,
                    tab, contents, ownerLease);
        } catch (RuntimeException | Error error) {
            try {
                disposeFailedCreation(model, contents);
            } catch (RuntimeException | Error cleanupError) {
                error.addSuppressed(cleanupError);
            }
            throw error;
        } finally {
            YabNamespaceRuntime.discardStaged(contents);
        }
    }

    /** Rebind only an already-live restored/replaced Tab with the exact native producer identity. */
    public static YabChromeSession bindExisting(ChromeActivity activity, Tab tab,
            YabNamespaceIdentity expected, BooleanSupplier ownerLease) {
        ThreadUtils.assertOnUiThread();
        Objects.requireNonNull(expected);
        Objects.requireNonNull(ownerLease);
        Profile profile = tab.getProfile();
        if (!ownerLease.getAsBoolean() || activity.isFinishing() || activity.isDestroyed()
                || !ChromeBrowserInitializer.getInstance().isFullBrowserInitialized()
                || !YabChromeBootstrap.ensureProfile(profile)
                || !expected.equals(YabNamespaceRuntime.require(tab))) {
            throw new IllegalStateException("Restored Tab does not match the captured native owner");
        }
        WindowAndroid window = Objects.requireNonNull(activity.getWindowAndroid());
        CompositorViewHolder surface = Objects.requireNonNull(
                activity.getCompositorViewHolderSupplier().get());
        TabModel model = activity.getTabModelSelector().getModel(profile.isOffTheRecord());
        WebContents contents = Objects.requireNonNull(tab.getWebContents(),
                "Chrome restore/unfreeze must finish before binding its live session");
        if (tab.isDestroyed() || contents.isDestroyed() || model.getProfile() != profile
                || model.indexOf(tab) < 0 || tab.getWindowAndroid() != window
                || TabUtils.fromWebContents(contents) != tab) {
            throw new IllegalStateException("Restored Tab is not owned by the captured Chrome host");
        }
        return new YabChromeSession(activity, window, surface, profile, model, tab, contents, ownerLease);
    }

    private static void disposeFailedCreation(TabModel model, WebContents contents) {
        @Nullable Tab owner = YabNamespaceRuntime.creationOwner(contents);
        @Nullable Tab nativeOwner = contents.isDestroyed() ? null : TabUtils.fromWebContents(contents);
        if (owner != null && nativeOwner != null && owner != nativeOwner) {
            YabNamespaceRuntime.retainUncertainFactoryOwner(contents);
            throw new IllegalStateException("Ambiguous native ownership; preserve Tab-owned contents");
        }
        @Nullable Tab registered = owner != null ? owner : nativeOwner;
        if (registered != null && (model.indexOf(registered) >= 0
                || TabWindowManagerSingleton.getInstance().getTabModelForTab(registered) != null)) {
            // A callback threw after model adoption. The model retains the resource;
            // its normal TabRemover owns any subsequent close. Never delete its WebContents.
            try {
                YabNamespaceRuntime.confirmFactoryAdopted(contents, registered);
            } catch (RuntimeException | Error error) {
                YabNamespaceRuntime.retainUncertainFactoryOwner(contents);
                throw error;
            }
            return;
        }
        if (owner == null && nativeOwner != null) {
            YabNamespaceRuntime.retainUncertainFactoryOwner(contents);
            throw new IllegalStateException("Untracked native Tab owns the allocation; preserve its contents");
        }
        if (owner != null && owner.isDestroyed() && !YabNamespaceRuntime.isDisposalComplete(owner)) {
            throw new IllegalStateException("Partial Tab destruction is not safely retryable; retain native owner");
        }
        // This is our temporary, unregistered Tab, including a partial initialize() failure.
        try {
            if (owner != null && !owner.isDestroyed()) owner.destroy();
        } finally {
            if (!contents.isDestroyed()) {
                if ((owner != null && owner.getWebContents() == contents)
                        || TabUtils.fromWebContents(contents) != null) {
                    throw new IllegalStateException("Contents is still Tab-owned after failed creation");
                }
                contents.destroy();
            }
        }
        YabNamespaceRuntime.abandonDisposedCreation(contents);
    }

    /** Retry unstarted cleanup only. Partial Tab destruction is retained for explicit host recovery. */
    public static void retryFailedCreationDisposal(ChromeActivity activity, Profile profile) {
        ThreadUtils.assertOnUiThread();
        TabModel model = activity.getTabModelSelector().getModel(profile.isOffTheRecord());
        if (model.getProfile() != profile) throw new IllegalStateException("Cleanup Profile mismatch");
        for (WebContents contents : YabNamespaceRuntime.pendingFactoryDisposal(profile)) {
            try {
                disposeFailedCreation(model, contents);
            } finally {
                YabNamespaceRuntime.discardStaged(contents);
            }
        }
    }

    /** Dispose failed restored builders. Registered Tabs remain owned by their native TabModels. */
    public static void disposeUnregisteredTabs(ChromeActivity activity, Profile profile) {
        ThreadUtils.assertOnUiThread();
        TabModel model = activity.getTabModelSelector().getModel(profile.isOffTheRecord());
        if (model.getProfile() != profile) throw new IllegalStateException("Cleanup Profile mismatch");
        for (Tab tab : YabNamespaceRuntime.allocatedTabResources(profile)) {
            if (model.indexOf(tab) >= 0
                    || TabWindowManagerSingleton.getInstance().getTabModelForTab(tab) != null
                    || YabNamespaceRuntime.isDisposalComplete(tab)) continue;
            if (tab.isDestroyed()) {
                throw new IllegalStateException("Partial restored Tab destruction requires explicit recovery");
            }
            tab.destroy();
            if (!YabNamespaceRuntime.isDisposalComplete(tab)) {
                throw new IllegalStateException("Unregistered Tab disposal did not complete");
            }
        }
        // This keeps saved restore identities and buffers on disk; it is not confirmed user Close.
    }

    private void requireCurrent() {
        ThreadUtils.assertOnUiThread();
        if (mTornDown || !mOwnerLease.getAsBoolean() || mActivity.isFinishing()
                || mActivity.isDestroyed() || mActivity.getWindowAndroid() != mWindow
                || mActivity.getCompositorViewHolderSupplier().get() != mSurface
                || mModel.getProfile() != mProfile || mModel.indexOf(mTab) < 0
                || mTab.isDestroyed() || mTab.getProfile() != mProfile || mTab.getWindowAndroid() != mWindow
                || !YabNamespaceRuntime.isAccessEpochCurrent(mTab, mAccessEpoch)
                || mTab.getWebContents() != mContents || mContents.isDestroyed()) {
            throw new IllegalStateException("The captured Chrome session is no longer current");
        }
    }

    /**
     * This is the existing Chrome compositor host. Keep it in its ChromeActivity
     * hierarchy and lay out Yab UI around it; do not reparent it into a second
     * compositor or assume that Tab.getView() alone contains GPU output.
     */
    public View nativeSurface() {
        requireCurrent();
        if (mActivity.getTabModelSelector().getCurrentModel() != mModel
                || mActivity.getTabModelSelector().getCurrentTab() != mTab) {
            throw new IllegalStateException("The shared compositor belongs to another selected Tab");
        }
        return mSurface;
    }

    public void select() {
        requireCurrent();
        mActivity.getTabModelSelector().selectModel(mProfile.isOffTheRecord());
        mModel.setIndex(mModel.indexOf(mTab), TabSelectionType.FROM_USER);
    }

    /** Navigation policy must already have approved these native-owned parameters. */
    public void navigate(LoadUrlParams params) {
        requireCurrent();
        mTab.loadUrl(params);
    }

    public void goBack() {
        requireCurrent();
        if (mContents.getNavigationController().canGoBack()) {
            mTab.goBack(); // Preserve Chrome's native beforeunload handling.
        }
    }

    public void goForward() {
        requireCurrent();
        if (mContents.getNavigationController().canGoForward()) mTab.goForward();
    }

    public void reload() {
        requireCurrent();
        mTab.reload();
    }

    public void stop() {
        requireCurrent();
        mTab.stopLoading();
    }

    /** A request through Chrome's remover; the host observes actual destruction. */
    public void requestClose() {
        requireCurrent();
        if (mClosePending) return;
        mClosePending = true;
        try {
            mModel.getTabRemover().closeTabs(
                    TabClosureParams.closeTab(mTab).allowUndo(false).build(), true,
                    new TabModelActionListener() {
                        @Override
                        public void onConfirmationDialogResult(@TabModelActionListener.DialogType int dialogType,
                                @ActionConfirmationResult int result) {
                            // TabRemover reports a negative result for a cancelled beforeunload.
                            // A request is never the session's teardown, regardless of result.
                            mClosePending = false;
                        }
                    });
        } catch (RuntimeException | Error error) {
            mClosePending = false;
            throw error;
        }
    }
}
