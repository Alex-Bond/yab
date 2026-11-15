"""Source hooks for explicit native namespace cookie grants. Never applies the patch."""
from pathlib import Path


def extend_cookies(source, changes, modify):
    here = Path(__file__).parent
    api_dir = 'extensions/browser/api/cookies/'
    for name in ('yab_cookie_store_policy.h', 'yab_cookie_store_policy.cc'):
        path = api_dir + name
        if (source / path).exists():
            raise RuntimeError('Existing cookies policy must be preserved: ' + path)
        changes[path] = (here / name).read_text()
    test = api_dir + 'yab_cookie_store_policy_unittest.cc'
    if (source / test).exists():
        raise RuntimeError('Existing policy test must be preserved: ' + test)
    changes[test] = (here / 'yab_cookie_store_policy_unittest.cc').read_text()
    modify('extensions/browser/BUILD.gn', '    "api/cookies/cookies_unittest.cc",\n',
           '    "api/cookies/cookies_unittest.cc",\n'
           '    "api/cookies/yab_cookie_store_policy_unittest.cc",\n')
    modify(api_dir + 'BUILD.gn', '    "cookies_helpers.h",\n',
           '    "cookies_helpers.h",\n    "yab_cookie_store_policy.cc",\n    "yab_cookie_store_policy.h",\n')

    java = 'chrome/browser/tab/java/src/org/chromium/chrome/browser/tab/WebContentsState.java'
    method = '''    /** Native-only capability creation. All identities are captured from YabNamespaceRuntime. */
    static String grantYabCookieStore(Profile caller, Profile target, WebContents proof,
            String extensionId, String account, String callerEpoch, String targetEpoch,
            String namespaceId, boolean inMemory, boolean implicitDefault) {
        return WebContentsStateJni.get().grantYabCookieStore(caller, target, proof,
                extensionId, account, callerEpoch, targetEpoch, namespaceId, inMemory, implicitDefault);
    }

    static void revokeYabCookieStores(Profile caller) {
        WebContentsStateJni.get().revokeYabCookieStores(caller);
    }

    static boolean revokeYabCookieStore(Profile caller, String extensionId, String storeId) {
        return WebContentsStateJni.get().revokeYabCookieStore(caller, extensionId, storeId);
    }

    @CalledByNative
    private static boolean isYabCookieGrantCurrent(@JniType("Profile*") Profile caller,
            @JniType("Profile*") Profile target, @JniType("std::string") String account,
            @JniType("std::string") String callerEpoch, @JniType("std::string") String targetEpoch,
            @JniType("std::string") String namespaceId, boolean inMemory) {
        return YabNamespaceRuntime.isCookieGrantCurrent(caller, target, account,
                callerEpoch, targetEpoch, namespaceId, inMemory);
    }

'''
    modify(java, '    @NativeMethods\n', method + '    @NativeMethods\n')
    modify(java, '    public interface Natives {\n', '''    public interface Natives {
        @JniType("std::string") String grantYabCookieStore(
                @JniType("Profile*") Profile caller, @JniType("Profile*") Profile target,
                @JniType("content::WebContents*") WebContents proof,
                @JniType("std::string") String extensionId, @JniType("std::string") String account,
                @JniType("std::string") String callerEpoch, @JniType("std::string") String targetEpoch,
                @JniType("std::string") String namespaceId, boolean inMemory, boolean implicitDefault);
        void revokeYabCookieStores(@JniType("Profile*") Profile caller);
        boolean revokeYabCookieStore(@JniType("Profile*") Profile caller,
                @JniType("std::string") String extensionId, @JniType("std::string") String storeId);

''')
    gn = 'chrome/browser/tab/BUILD.gn'
    modify(gn, 'import("//chrome/browser/buildflags.gni")\n',
           'import("//chrome/browser/buildflags.gni")\nimport("//extensions/buildflags/buildflags.gni")\n')
    modify(gn, '    "web_contents_state.cc",\n  ]\n  deps = [\n',
           '    "web_contents_state.cc",\n  ]\n  deps = [ "//extensions/buildflags" ]\n'
           '  if (enable_extensions_core) {\n'
           '    deps += [ "//extensions/browser/api/cookies" ]\n  }\n  deps += [\n')
    cpp = 'chrome/browser/tab/web_contents_state.cc'
    modify(cpp, '#include "base/containers/span.h"\n',
           '#include "base/containers/span.h"\n#include "base/functional/bind.h"\n')
    modify(cpp, '#include "content/public/common/referrer.h"\n',
           '#include "content/public/common/referrer.h"\n'
           '#include "extensions/buildflags/buildflags.h"\n'
           '#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)\n'
           '#include "extensions/browser/api/cookies/yab_cookie_store_policy.h"\n'
           '#include "extensions/browser/extensions_browser_client.h"\n#endif\n')
    native = '''static std::string JNI_WebContentsState_GrantYabCookieStore(
    JNIEnv* env, Profile* caller, Profile* target, WebContents* proof,
    const std::string& extension_id, const std::string& account,
    const std::string& caller_epoch, const std::string& target_epoch,
    const std::string& namespace_id, bool in_memory, bool implicit_default) {
#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)
  if (!caller || !target || !proof ||
      caller->GetOriginalProfile() != target->GetOriginalProfile() ||
      (caller->IsOffTheRecord() && caller != target) ||
      !base::Uuid::ParseLowercase(account).is_valid() ||
      !base::Uuid::ParseLowercase(caller_epoch).is_valid() ||
      !base::Uuid::ParseLowercase(target_epoch).is_valid() ||
      !JNI_WebContentsState_MatchesYabNamespace(env, target, proof, namespace_id, in_memory)) {
    return {};
  }
  auto validator = base::BindRepeating(
      [](base::WeakPtr<BrowserContext> caller, base::WeakPtr<BrowserContext> target,
         std::string account, std::string caller_epoch, std::string target_epoch,
         std::string namespace_id, bool in_memory) {
        if (!caller || !target) return false;
        return Java_WebContentsState_isYabCookieGrantCurrent(
            base::android::AttachCurrentThread(), Profile::FromBrowserContext(caller.get()),
            Profile::FromBrowserContext(target.get()), account, caller_epoch, target_epoch,
            namespace_id, in_memory);
      }, caller->GetWeakPtr(), target->GetWeakPtr(), account, caller_epoch, target_epoch,
      namespace_id, in_memory);
  if (!validator.Run()) return {};
  int tab_id = -1;
  int window_id = -1;
  extensions::ExtensionsBrowserClient::Get()->GetTabAndWindowIdForWebContents(proof, &tab_id, &window_id);
  const auto partition = content::StoragePartitionConfig::Create(
      target, "YabWebsiteNamespace", namespace_id, in_memory);
  return extensions::YabCookieStorePolicy::Get(caller, /*create=*/true)->Grant(
      caller, target, proof, extension_id, partition, tab_id, implicit_default, std::move(validator));
#else
  return {};
#endif
}

static void JNI_WebContentsState_RevokeYabCookieStores(JNIEnv* env, Profile* caller) {
#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)
  if (auto* policy = extensions::YabCookieStorePolicy::Get(caller)) policy->RevokeAll();
#endif
}

static bool JNI_WebContentsState_RevokeYabCookieStore(
    JNIEnv* env, Profile* caller, const std::string& extension_id, const std::string& store_id) {
#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)
  auto* policy = extensions::YabCookieStorePolicy::Get(caller);
  return policy && policy->Revoke(extension_id, store_id);
#else
  return false;
#endif
}

'''
    # MatchesYabNamespace is defined first so the grant validates an actual captured native partition.
    modify(cpp, 'static content::WebContents* JNI_WebContentsState_RestoreContentsForYabNamespace(\n',
           native + 'static content::WebContents* JNI_WebContentsState_RestoreContentsForYabNamespace(\n')

    header = api_dir + 'cookies_api.h'
    modify(header, 'class CookiesGetFunction : public ExtensionFunction {\n',
           'class YabCookieStoreLease;\n\nclass CookiesGetFunction : public ExtensionFunction {\n')
    current = (source / header).read_text()
    needle = '  mojo::Remote<network::mojom::CookieManager> store_browser_cookie_manager_;\n'
    if current.count(needle) != 4:
        raise RuntimeError('Unexpected cookies request state count')
    changes[header] = changes[header].replace(needle,
        needle + '  scoped_refptr<YabCookieStoreLease> yab_cookie_lease_;\n')

    cc = api_dir + 'cookies_api.cc'
    modify(cc, '#include "extensions/browser/api/cookies/cookies_helpers.h"\n',
           '#include "extensions/browser/api/cookies/cookies_helpers.h"\n'
           '#include "extensions/browser/api/cookies/yab_cookie_store_policy.h"\n')
    modify(cc, 'constexpr char kInvalidStoreIdError[] = "Invalid cookie store id: \\\"*\\\".";\n',
           'constexpr char kInvalidStoreIdError[] = "Invalid cookie store id: \\\"*\\\".";\n'
           'constexpr char kYabCookieLeaseError[] = "The native cookie namespace grant is unavailable.";\n')
    modify(cc, '''    bool include_incognito,
    std::string* store_id,
    std::string* error) {
  content::BrowserContext* store_context = nullptr;''', '''    bool include_incognito,
    const Extension* extension,
    scoped_refptr<YabCookieStoreLease>* native_lease,
    std::string* store_id,
    std::string* error) {
  if (YabCookieStorePolicy::IsRequired()) {
    auto* policy = YabCookieStorePolicy::Get(function_context);
    *native_lease = policy && extension
        ? policy->Resolve(extension->id(), *store_id, include_incognito) : nullptr;
    if (!*native_lease || (*native_lease)->approved_extension() != extension) {
      *error = kYabCookieLeaseError;
      return nullptr;
    }
    *store_id = (*native_lease)->store_id();
    auto* manager = (*native_lease)->GetCookieManager();
    if (!manager) *error = kYabCookieLeaseError;
    return manager;
  }
  content::BrowserContext* store_context = nullptr;''')
    current = changes[cc]
    call = '      browser_context(), include_incognito_information(), &store_id, &error);'
    if current.count(call) != 4:
        raise RuntimeError('Unexpected cookies route call count')
    current = current.replace(call,
        '      browser_context(), include_incognito_information(), extension(), &yab_cookie_lease_, &store_id, &error);')
    normalize = '  if (!parsed_args_->details.store_id) {\n'
    if current.count(normalize) != 4:
        raise RuntimeError('Unexpected normalized store ID count')
    changes[cc] = current.replace(normalize,
        '  if (YabCookieStorePolicy::IsRequired() || !parsed_args_->details.store_id) {\n')
    guard = '''  if (YabCookieStorePolicy::IsRequired() &&
      (!yab_cookie_lease_ || !yab_cookie_lease_->IsCurrent(include_incognito_information()) ||
       (!url_.is_empty() && (!extension() || !CheckHostPermissions(extension(), url_, nullptr))))) {
    Respond(Error(kYabCookieLeaseError));
    return;
  }
'''
    signatures = [
        'void CookiesGetFunction::GetCookieListCallback(\n    const net::CookieAccessResultList& cookie_list,\n    const net::CookieAccessResultList& excluded_cookies) {\n',
        'void CookiesGetAllFunction::GetAllCookiesCallback(\n    const net::CookieList& cookie_list) {\n',
        'void CookiesGetAllFunction::GetCookieListCallback(\n    const net::CookieAccessResultList& cookie_list,\n    const net::CookieAccessResultList& excluded_cookies) {\n',
        'void CookiesSetFunction::GetCookieListCallback(\n    const net::CookieAccessResultList& cookie_list,\n    const net::CookieAccessResultList& excluded_cookies) {\n',
        'void CookiesRemoveFunction::RemoveCookieCallback(uint32_t /* num_deleted */) {\n',
    ]
    for signature in signatures:
        modify(cc, signature, signature + guard)
    modify(cc, '  CHECK(render_frame_host);\n', '''  CHECK(render_frame_host);
  if (YabCookieStorePolicy::IsRequired()) {
    auto* policy = YabCookieStorePolicy::Get(browser_context());
    if (!policy || !policy->AllowsWebContents(extension(), web_contents, include_incognito_information())) {
      return RespondNow(Error(kYabCookieLeaseError));
    }
  }
''')
    modify(cc, 'ExtensionFunction::ResponseAction CookiesGetAllCookieStoresFunction::Run() {\n',
           '''ExtensionFunction::ResponseAction CookiesGetAllCookieStoresFunction::Run() {
  if (YabCookieStorePolicy::IsRequired()) {
    auto* policy = YabCookieStorePolicy::Get(browser_context());
    auto stores = policy ? policy->Stores(extension(), include_incognito_information())
                         : std::vector<api::cookies::CookieStore>();
    return RespondNow(ArgumentList(api::cookies::GetAllCookieStores::Results::Create(stores)));
  }
''')
    modify(cc, 'void CookiesEventRouter::MaybeStartListening() {\n',
           'void CookiesEventRouter::MaybeStartListening() {\n  if (YabCookieStorePolicy::IsRequired()) return;\n')
    modify(cc, '''    content::BrowserContext& context) {
  network::mojom::CookieManager* cookie_manager =''', '''    content::BrowserContext& context) {
  if (YabCookieStorePolicy::IsRequired()) return;
  network::mojom::CookieManager* cookie_manager =''')
    modify(cc, 'void CookiesAPI::OnListenerAdded(const EventListenerInfo& details) {\n',
           '''void CookiesAPI::OnListenerAdded(const EventListenerInfo& details) {
  if (YabCookieStorePolicy::IsRequired()) {
    EventRouter::Get(browser_context_)->UnregisterObserver(this);
    return; // Namespace grants own targeted listeners; never bind default-jar broadcast.
  }
''')
