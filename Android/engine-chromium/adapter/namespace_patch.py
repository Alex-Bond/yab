"""Extend the unapplied patch in memory using exact pinned-source anchors."""
from pathlib import Path


def extend(source, changes, modify):
    here = Path(__file__).parent
    tab_java = 'chrome/browser/tab/java/src/org/chromium/chrome/browser/tab/'
    for name in ('YabNamespaceIdentity.java', 'YabNamespaceRuntime.java'):
        path = tab_java + name
        if (source / path).exists():
            raise RuntimeError('Existing namespace source must be preserved: ' + path)
        changes[path] = (here / name).read_text()
    modify('chrome/browser/tab/BUILD.gn',
           'android_library("java") {\n  sources = [\n',
           'android_library("java") {\n  sources = [\n'
           '    "java/src/org/chromium/chrome/browser/tab/YabNamespaceIdentity.java",\n'
           '    "java/src/org/chromium/chrome/browser/tab/YabNamespaceRuntime.java",\n')

    java = tab_java + 'WebContentsState.java'
    methods = '''    /** Restore only into the native owner's non-default fixed partition. No default fallback. */
    public @Nullable WebContents restoreWebContentsForYabNamespace(Profile profile,
            String namespaceId, boolean inMemory, boolean isHidden, boolean noRenderer) {
        return WebContentsStateJni.get().restoreContentsForYabNamespace(
                profile, buffer(), version(), namespaceId, inMemory, isHidden, noRenderer);
    }

    public static boolean matchesYabNamespace(Profile profile, WebContents contents,
            String namespaceId, boolean inMemory) {
        return !contents.isDestroyed() && WebContentsStateJni.get().matchesYabNamespace(
                profile, contents, namespaceId, inMemory);
    }

'''
    modify(java, '    @NativeMethods\n', methods + '    @NativeMethods\n')
    modify(java, '    public interface Natives {\n', '''    public interface Natives {
        @JniType("content::WebContents*")
        @Nullable WebContents restoreContentsForYabNamespace(
                @JniType("Profile*") Profile profile, ByteBuffer buffer, int savedStateVersion,
                @JniType("std::string") String namespaceId, boolean inMemory,
                boolean initiallyHidden, boolean noRenderer);

        boolean matchesYabNamespace(@JniType("Profile*") Profile profile,
                @JniType("content::WebContents*") WebContents contents,
                @JniType("std::string") String namespaceId, boolean inMemory);

''')

    cpp = 'chrome/browser/tab/web_contents_state.cc'
    modify(cpp, '#include "base/pickle.h"\n',
           '#include "base/pickle.h"\n#include "base/uuid.h"\n')
    modify(cpp, '#include "content/public/browser/restore_type.h"\n',
           '#include "content/public/browser/restore_type.h"\n'
           '#include "content/public/browser/render_frame_host.h"\n'
           '#include "content/public/browser/site_instance.h"\n'
           '#include "content/public/browser/storage_partition.h"\n'
           '#include "content/public/browser/storage_partition_config.h"\n')
    native = '''static bool JNI_WebContentsState_MatchesYabNamespace(
    JNIEnv* env,
    Profile* profile,
    WebContents* contents,
    const std::string& namespace_id,
    bool in_memory) {
  const base::Uuid id = base::Uuid::ParseLowercase(namespace_id);
  if (!profile || !contents || !id.is_valid() ||
      contents->GetBrowserContext() != profile ||
      (profile->IsOffTheRecord() && !in_memory)) {
    return false;
  }
  auto* frame = contents->GetPrimaryMainFrame();
  if (!frame) {
    return false;
  }
  const auto expected = content::StoragePartitionConfig::Create(
      profile, "YabWebsiteNamespace", id.AsLowercaseString(), in_memory);
  return frame->GetStoragePartition()->GetConfig() == expected;
}

static content::WebContents* JNI_WebContentsState_RestoreContentsForYabNamespace(
    JNIEnv* env,
    Profile* profile,
    const JavaRef<jobject>& state,
    int32_t saved_state_version,
    const std::string& namespace_id,
    bool in_memory,
    bool initially_hidden,
    bool no_renderer) {
  const base::Uuid id = base::Uuid::ParseLowercase(namespace_id);
  if (!profile || !id.is_valid() || (profile->IsOffTheRecord() && !in_memory)) {
    return nullptr;
  }
  bool saved_private = false;
  int selected = -1;
  std::vector<sessions::SerializedNavigationEntry> navigations;
  if (!WebContentsState::ExtractNavigationEntries(
          base::android::JavaByteBufferToSpan(env, state), saved_state_version,
          &saved_private, &selected, &navigations) ||
      saved_private != profile->IsOffTheRecord() || selected < 0 ||
      static_cast<size_t>(selected) >= navigations.size()) {
    return nullptr;
  }
  auto entries = sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(
      navigations, profile);
  const auto partition = content::StoragePartitionConfig::Create(
      profile, "YabWebsiteNamespace", id.AsLowercaseString(), in_memory);
  auto site_instance = content::SiteInstance::CreateForFixedStoragePartition(
      profile, GURL(), partition);
  WebContents::CreateParams params(profile, std::move(site_instance));
  params.initially_hidden = initially_hidden;
  if (no_renderer) {
    params.desired_renderer_state = WebContents::CreateParams::kNoRendererProcess;
  }
  auto contents = WebContents::Create(params);
  contents->GetController().Restore(selected, content::RestoreType::kRestored, &entries);
  if (!JNI_WebContentsState_MatchesYabNamespace(
          env, profile, contents.get(), namespace_id, in_memory)) {
    return nullptr;
  }
  return contents.release();
}

'''
    modify(cpp, 'static content::WebContents* JNI_WebContentsState_RestoreContentsFromByteBuffer(\n',
           native + 'static content::WebContents* JNI_WebContentsState_RestoreContentsFromByteBuffer(\n')

    creator = 'chrome/android/java/src/org/chromium/chrome/browser/tabmodel/ChromeTabCreator.java'
    modify(creator, 'import org.chromium.chrome.browser.tab.TabState;\n',
           'import org.chromium.chrome.browser.tab.TabState;\n'
           'import org.chromium.chrome.browser.tab.YabNamespaceRuntime;\n')
    modify(creator, '    public @Nullable Tab createFrozenTab(TabState state, int id, int index) {\n',
           '    public @Nullable Tab createFrozenTab(TabState state, int id, int index) {\n'
           '        if (!YabNamespaceRuntime.canRestore(getProfile(), id, state)) return null;\n')

    builder = 'chrome/android/java/src/org/chromium/chrome/browser/tab/TabBuilder.java'
    modify(builder, '        TabImpl tab = new TabImpl(mId, mProfile, mLaunchType);\n',
           '        TabImpl tab = new TabImpl(mId, mProfile, mLaunchType);\n'
           '        YabNamespaceRuntime.onTabAllocated(tab, mWebContents);\n')
    modify(builder, '        if (mPreInitializeAction != null) mPreInitializeAction.onResult(tab);\n',
           '        YabNamespaceRuntime.beforeInitialize(tab, mWebContents, mTabState);\n'
           '        if (mPreInitializeAction != null) mPreInitializeAction.onResult(tab);\n')

    extractor = tab_java + 'TabStateExtractor.java'
    modify(extractor, '        tabState.contentsState = getWebContentsState(tab);\n',
           '        tabState.contentsState = getWebContentsState(tab);\n'
           '        if (!YabNamespaceRuntime.seal(tab, tabState.contentsState)) {\n'
           '            if (tabState.contentsState != null) tabState.contentsState.destroy();\n'
           '            return null;\n'
           '        }\n')

    impl = 'chrome/android/java/src/org/chromium/chrome/browser/tab/TabImpl.java'
    modify(impl, '''            assert mNativeTabAndroid == 0;
        }
        return status;
''', '''            assert mNativeTabAndroid == 0;
        }
        YabNamespaceRuntime.onNativeDisposalCompleted(this, deleteNativeWebContents);
        return status;
''')
    modify(impl, '        if (!canLoadIfNeeded()) {\n',
           '        if (!canLoadIfNeeded() || !YabNamespaceRuntime.mayExpose(this)) {\n')
    modify(impl, '    private void restoreIfNeeded() {\n',
           '    private void restoreIfNeeded() {\n'
           '        if (!YabNamespaceRuntime.mayExpose(this)) return;\n')
    modify(impl, '            boolean initializeRenderer) {\n        if (isDormant()) {\n',
           '            boolean initializeRenderer) {\n'
           '        if (!YabNamespaceRuntime.mayExpose(this)) return;\n'
           '        if (isDormant()) {\n')
    modify(impl, '            unfreezeContents(/* noRenderer= */ true);\n',
           '            if (!unfreezeContents(/* noRenderer= */ true)) return;\n')
    modify(impl, '''            WebContents webContents =
                    mWebContentsState.restoreWebContents(getProfile(), isHidden(), noRenderer);
''', '''            WebContents webContents;
            if (YabNamespaceRuntime.isRequired()) {
                if (!YabNamespaceRuntime.mayExpose(this)) return false;
                YabNamespaceIdentity identity = YabNamespaceRuntime.require(this);
                webContents = mWebContentsState.restoreWebContentsForYabNamespace(
                        getProfile(), identity.namespaceId, identity.inMemory, isHidden(), noRenderer);
                if (webContents == null) {
                    for (TabObserver observer : mObservers) observer.onRestoreFailed(this);
                    // Keep the tab frozen. No default-jar WebContents or URL-only fallback.
                    return false;
                }
            } else {
                webContents = mWebContentsState.restoreWebContents(getProfile(), isHidden(), noRenderer);
            }
''')
    # All four normal/pending/failure factory sites must route through the same lease guard.
    current = changes[impl]
    needle = 'WebContentsFactory.createWebContents('
    if current.count(needle) != 4:
        raise RuntimeError('Unexpected count of pinned TabImpl factory paths')
    changes[impl] = current.replace(needle, 'createWebContentsForCurrentYabOwner(')
    helper = '''    private WebContents createWebContentsForCurrentYabOwner(
            Profile profile, boolean hidden, boolean initializeRenderer) {
        if (!YabNamespaceRuntime.isRequired()) {
            return WebContentsFactory.createWebContents(profile, hidden, initializeRenderer);
        }
        if (profile != mProfile) throw new IllegalStateException("Profile replacement is forbidden");
        YabNamespaceIdentity identity = YabNamespaceRuntime.require(this);
        return WebContentsFactory.createWebContentsForYabNamespace(profile,
                identity.namespaceId, identity.inMemory, hidden, initializeRenderer);
    }

'''
    modify(impl, '    private void initializeWebContents(\n', helper + '    private void initializeWebContents(\n')
