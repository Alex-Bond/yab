// Unapplied Yab Android policy for the pinned Chromium source.
#include "extensions/browser/api/cookies/yab_cookie_store_policy.h"

#include <memory>
#include <optional>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "build/build_config.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/api/cookies/cookies_helpers.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extensions_browser_client.h"
#include "extensions/common/constants.h"
#include "extensions/common/event_args.h"
#include "extensions/common/extension.h"
#include "extensions/common/permissions/permissions_data.h"
#include "net/cookies/cookie_constants.h"

namespace extensions {
namespace {
const char kPolicyKey[] = "YabNativeCookieStorePolicy";
constexpr size_t kMaximumCookieStoreGrants = 4096;

std::optional<std::string> ChangeCause(net::CookieChangeCause cause) {
  switch (cause) {
    case net::CookieChangeCause::INSERTED:
    case net::CookieChangeCause::EXPLICIT:
    case net::CookieChangeCause::INSERTED_NO_CHANGE_OVERWRITE:
    case net::CookieChangeCause::INSERTED_NO_VALUE_CHANGE_OVERWRITE:
      return "explicit";
    case net::CookieChangeCause::OVERWRITE:
      return "overwrite";
    case net::CookieChangeCause::EXPIRED:
      return "expired";
    case net::CookieChangeCause::EVICTED:
      return "evicted";
    case net::CookieChangeCause::EXPIRED_OVERWRITE:
      return "expired_overwrite";
    case net::CookieChangeCause::UNKNOWN_DELETION:
      return std::nullopt;
  }
  return std::nullopt;
}
}  // namespace

YabCookieStoreLease::YabCookieStoreLease(
    content::BrowserContext* caller,
    content::BrowserContext* target,
    content::WebContents* proof,
    std::string extension_id,
    content::StoragePartitionConfig partition,
    int extension_tab_id,
    bool implicit_default,
    base::RepeatingCallback<bool()> native_owner_current)
    : caller_(caller->GetWeakPtr()),
      target_(target->GetWeakPtr()),
      proofs_({{proof->GetWeakPtr(), extension_tab_id}}),
      extension_id_(std::move(extension_id)),
      approved_extension_(ExtensionRegistry::Get(caller)
          ? ExtensionRegistry::Get(caller)->enabled_extensions().GetByID(extension_id_) : nullptr),
      store_id_("yab-" + base::UnguessableToken::Create().ToString()),
      partition_(std::move(partition)),
      implicit_default_(implicit_default),
      native_owner_current_(std::move(native_owner_current)) {}

YabCookieStoreLease::~YabCookieStoreLease() = default;

bool YabCookieStoreLease::IsCurrent(bool include_incognito) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (revoked_) {
    return false;
  }
  if (!caller_ || !target_) {
    Revoke();
    return false;
  }
  if (caller_->IsOffTheRecord() && caller_.get() != target_.get()) return false;
  if (target_->IsOffTheRecord() &&
      ((target_.get() != caller_.get() && !include_incognito) ||
       !ExtensionsBrowserClient::Get()->IsExtensionIncognitoEnabled(
           extension_id_, caller_.get()))) {
    // A request without include_incognito does not revoke an otherwise valid native grant.
    if (target_.get() == caller_.get() || include_incognito) Revoke();
    return false;
  }
  auto* registry = ExtensionRegistry::Get(caller_.get());
  const Extension* extension =
      registry ? registry->enabled_extensions().GetByID(extension_id_) : nullptr;
  if (!extension || extension != approved_extension_.get() ||
      !extension->permissions_data()->HasAPIPermission("cookies")) {
    Revoke(); // Observed disable, reload or permission loss cannot revive this capability.
    return false;
  }
  if (native_owner_current_.is_null() || !native_owner_current_.Run()) {
    Revoke(); // A captured owner scope cannot revive after an observed rejection.
    return false;
  }
  bool has_proof = false;
  for (const auto& proof : proofs_) {
    if (Allows(proof.contents.get())) has_proof = true;
  }
  if (!has_proof) {
    return false;
  }
  return true;
}

bool YabCookieStoreLease::MatchesPartition(content::BrowserContext* target,
    const content::StoragePartitionConfig& partition) const {
  return target_.get() == target && partition_ == partition;
}

bool YabCookieStoreLease::Allows(content::WebContents* contents) const {
  if (!target_ || !contents || contents->GetBrowserContext() != target_.get()) return false;
  auto* frame = contents->GetPrimaryMainFrame();
  return frame && frame->GetStoragePartition()->GetConfig() == partition_;
}

void YabCookieStoreLease::AddProof(content::WebContents* proof, int extension_tab_id) {
  if (!Allows(proof) || extension_tab_id < 0) return;
  for (const auto& existing : proofs_) {
    if (existing.contents.get() == proof) return;
  }
  proofs_.push_back({proof->GetWeakPtr(), extension_tab_id});
}

std::vector<int> YabCookieStoreLease::TabIds() const {
  std::vector<int> ids;
  for (const auto& proof : proofs_) {
    if (Allows(proof.contents.get())) ids.push_back(proof.tab_id);
  }
  return ids;
}

network::mojom::CookieManager* YabCookieStoreLease::GetCookieManager() {
  if (!target_) return nullptr;
  auto* partition = target_->GetStoragePartition(partition_, /*can_create=*/false);
  return partition ? partition->GetCookieManagerForBrowserProcess() : nullptr;
}

void YabCookieStoreLease::StartListening() {
  if (!IsCurrent(/*include_incognito=*/true)) return;
  auto* manager = GetCookieManager();
  if (!manager) return;
  manager->AddGlobalChangeListener(receiver_.BindNewPipeAndPassRemote());
  receiver_.set_disconnect_handler(base::BindOnce(
      [](YabCookieStoreLease* lease) {
        lease->receiver_.reset();
        lease->StartListening();
      }, base::Unretained(this)));
}

void YabCookieStoreLease::Revoke() {
  revoked_ = true;
  receiver_.reset();
}

void YabCookieStoreLease::OnCookieChange(const net::CookieChangeInfo& change) {
  if (!IsCurrent(/*include_incognito=*/true) ||
      (change.cookie.IsPartitioned() && !change.cookie.PartitionKey()->IsSerializeable())) {
    return;
  }
  auto cause = ChangeCause(change.cause);
  if (!cause) return;
  auto* registry = ExtensionRegistry::Get(caller_.get());
  const Extension* extension = registry->enabled_extensions().GetByID(extension_id_);
  const GURL domain = cookies_helpers::GetURLFromCanonicalCookie(change.cookie);
  if (!extension || extension->permissions_data()->GetPageAccess(
          domain, extension_misc::kUnknownTabId, nullptr) != PermissionsData::PageAccess::kAllowed) {
    return;
  }
  auto* router = EventRouter::Get(target_.get());
  if (!router) return;
  base::DictValue row;
  row.Set("removed", change.cause != net::CookieChangeCause::INSERTED &&
      change.cause != net::CookieChangeCause::INSERTED_NO_CHANGE_OVERWRITE &&
      change.cause != net::CookieChangeCause::INSERTED_NO_VALUE_CHANGE_OVERWRITE);
  row.Set("cookie", cookies_helpers::CreateCookie(change.cookie, store_id_).ToValue());
  row.Set("cause", *cause);
  auto args = base::MakeRefCounted<EventArgs>();
  args->data.Append(std::move(row));
  auto event = std::make_unique<Event>(events::COOKIES_ON_CHANGED,
      api::cookies::OnChanged::kEventName, std::move(args), target_.get());
  event->event_url = domain;
  event->will_dispatch_callback = base::BindRepeating(
      [](scoped_refptr<YabCookieStoreLease> lease, GURL domain,
         content::BrowserContext*, mojom::ContextType, const Extension* recipient,
         const base::DictValue*, std::optional<base::ListValue>&,
         mojom::EventFilteringInfoPtr&, bool*) {
        return lease->IsCurrent(/*include_incognito=*/true) && recipient &&
            recipient == lease->approved_extension() &&
            recipient->permissions_data()->GetPageAccess(
                domain, extension_misc::kUnknownTabId, nullptr) == PermissionsData::PageAccess::kAllowed;
      }, base::WrapRefCounted(this), domain);
  router->DispatchEventToExtension(extension_id_, std::move(event));
}

bool YabCookieStorePolicy::IsRequired() {
  // This is the Yab Android fork patch. It must deny access even before native owner installation.
  return BUILDFLAG(IS_ANDROID);
}

YabCookieStorePolicy* YabCookieStorePolicy::Get(content::BrowserContext* context, bool create) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!context) return nullptr;
  auto* existing = static_cast<YabCookieStorePolicy*>(context->GetUserData(kPolicyKey));
  if (existing || !create) return existing;
  auto policy = std::make_unique<YabCookieStorePolicy>();
  auto* result = policy.get();
  context->SetUserData(kPolicyKey, std::move(policy));
  return result;
}

YabCookieStorePolicy::~YabCookieStorePolicy() { RevokeAll(); }

std::string YabCookieStorePolicy::Grant(
    content::BrowserContext* caller, content::BrowserContext* target,
    content::WebContents* proof, const std::string& extension_id,
    const content::StoragePartitionConfig& partition, int extension_tab_id,
    bool implicit_default, base::RepeatingCallback<bool()> native_owner_current) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!caller || !target || !proof || extension_tab_id < 0 ||
      (caller->IsOffTheRecord() && caller != target) ||
      ExtensionsBrowserClient::Get()->GetOriginalContext(caller) !=
          ExtensionsBrowserClient::Get()->GetOriginalContext(target)) return {};
  for (auto entry = grants_.begin(); entry != grants_.end();) {
    entry->second->IsCurrent(/*include_incognito=*/true);
    if (entry->second->revoked()) entry = grants_.erase(entry);
    else ++entry;
  }
  for (auto& [id, existing] : grants_) {
    if (existing->extension_id() == extension_id && existing->IsCurrent(true)) {
      if (existing->MatchesPartition(target, partition)) {
        if (existing->implicit_default() != implicit_default) return {};
        existing->AddProof(proof, extension_tab_id);
        return id;
      }
      if (implicit_default && existing->implicit_default()) return {};
    }
  }
  if (grants_.size() >= kMaximumCookieStoreGrants) return {};
  auto lease = base::MakeRefCounted<YabCookieStoreLease>(caller, target, proof,
      extension_id, partition, extension_tab_id, implicit_default, std::move(native_owner_current));
  if (!lease->IsCurrent(/*include_incognito=*/true)) return {};
  const std::string id = lease->store_id();
  grants_[id] = lease;
  lease->StartListening();
  return id;
}

scoped_refptr<YabCookieStoreLease> YabCookieStorePolicy::Resolve(
    const std::string& extension_id, const std::string& store_id, bool include_incognito) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  for (auto& [id, lease] : grants_) {
    if (lease->extension_id() == extension_id &&
        ((store_id.empty() && lease->implicit_default()) || id == store_id) &&
        lease->IsCurrent(include_incognito)) return lease;
  }
  return nullptr; // No "0"/"1", selected-tab, URL or default-partition inference.
}

std::vector<api::cookies::CookieStore> YabCookieStorePolicy::Stores(
    const Extension* extension, bool include_incognito) {
  std::vector<api::cookies::CookieStore> stores;
  if (!extension) return stores;
  for (auto& [id, lease] : grants_) {
    if (lease->approved_extension() != extension || !lease->IsCurrent(include_incognito)) continue;
    base::ListValue tabs;
    for (int tab_id : lease->TabIds()) tabs.Append(tab_id);
    base::DictValue row;
    row.Set("id", id);
    row.Set("tabIds", std::move(tabs));
    auto store = api::cookies::CookieStore::FromValue(row);
    if (store) stores.push_back(std::move(store).value());
  }
  return stores;
}

bool YabCookieStorePolicy::AllowsWebContents(const Extension* extension,
    content::WebContents* contents, bool include_incognito) {
  if (!extension) return false;
  for (auto& [id, lease] : grants_) {
    if (lease->approved_extension() == extension && lease->Allows(contents) &&
        lease->IsCurrent(include_incognito)) return true;
  }
  return false;
}

void YabCookieStorePolicy::RevokeAll() {
  for (auto& [id, lease] : grants_) lease->Revoke();
  grants_.clear();
}

bool YabCookieStorePolicy::Revoke(const std::string& extension_id, const std::string& store_id) {
  auto found = grants_.find(store_id);
  if (found == grants_.end() || found->second->extension_id() != extension_id) return false;
  found->second->Revoke();
  grants_.erase(found);
  return true;
}
}  // namespace extensions
