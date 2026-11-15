// Unapplied Yab Android policy for the pinned Chromium source.
#ifndef EXTENSIONS_BROWSER_API_COOKIES_YAB_COOKIE_STORE_POLICY_H_
#define EXTENSIONS_BROWSER_API_COOKIES_YAB_COOKIE_STORE_POLICY_H_

#include <map>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/supports_user_data.h"
#include "content/public/browser/storage_partition_config.h"
#include "extensions/common/api/cookies.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"

namespace content {
class BrowserContext;
class WebContents;
}  // namespace content

namespace extensions {
class Extension;

class YabCookieStoreLease : public base::RefCounted<YabCookieStoreLease>,
                            public network::mojom::CookieChangeListener {
 public:
  YabCookieStoreLease(content::BrowserContext* caller,
                      content::BrowserContext* target,
                      content::WebContents* proof,
                      std::string extension_id,
                      content::StoragePartitionConfig partition,
                      int extension_tab_id,
                      bool implicit_default,
                      base::RepeatingCallback<bool()> native_owner_current);
  bool IsCurrent(bool include_incognito);
  network::mojom::CookieManager* GetCookieManager();
  void StartListening();
  void Revoke();
  void OnCookieChange(const net::CookieChangeInfo& change) override;

  const std::string& store_id() const { return store_id_; }
  const std::string& extension_id() const { return extension_id_; }
  const Extension* approved_extension() const { return approved_extension_.get(); }
  bool implicit_default() const { return implicit_default_; }
  bool revoked() const { return revoked_; }
  bool MatchesPartition(content::BrowserContext* target,
                        const content::StoragePartitionConfig& partition) const;
  bool Allows(content::WebContents* contents) const;
  void AddProof(content::WebContents* proof, int extension_tab_id);
  std::vector<int> TabIds() const;

 private:
  friend class base::RefCounted<YabCookieStoreLease>;
  ~YabCookieStoreLease() override;
  base::WeakPtr<content::BrowserContext> caller_;
  base::WeakPtr<content::BrowserContext> target_;
  struct Proof {
    base::WeakPtr<content::WebContents> contents;
    int tab_id;
  };
  std::vector<Proof> proofs_;
  const std::string extension_id_;
  const scoped_refptr<const Extension> approved_extension_;
  const std::string store_id_;
  const content::StoragePartitionConfig partition_;
  const bool implicit_default_;
  base::RepeatingCallback<bool()> native_owner_current_;
  bool revoked_ = false;
  mojo::Receiver<network::mojom::CookieChangeListener> receiver_{this};
};

// BrowserContext-owned; grants are process-local native capabilities, never restored from JS.
class YabCookieStorePolicy : public base::SupportsUserData::Data {
 public:
  static bool IsRequired();
  static YabCookieStorePolicy* Get(content::BrowserContext* context, bool create = false);
  ~YabCookieStorePolicy() override;

  std::string Grant(content::BrowserContext* caller,
                    content::BrowserContext* target,
                    content::WebContents* proof,
                    const std::string& extension_id,
                    const content::StoragePartitionConfig& partition,
                    int extension_tab_id,
                    bool implicit_default,
                    base::RepeatingCallback<bool()> native_owner_current);
  scoped_refptr<YabCookieStoreLease> Resolve(const std::string& extension_id,
                                           const std::string& store_id,
                                           bool include_incognito);
  std::vector<api::cookies::CookieStore> Stores(const Extension* extension,
                                               bool include_incognito);
  bool AllowsWebContents(const Extension* extension,
                         content::WebContents* contents,
                         bool include_incognito);
  bool Revoke(const std::string& extension_id, const std::string& store_id);
  void RevokeAll();

 private:
  std::map<std::string, scoped_refptr<YabCookieStoreLease>> grants_;
};

}  // namespace extensions
#endif
