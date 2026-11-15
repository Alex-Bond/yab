// Unapplied regression tests for the pinned upstream extensions_unittests target.
#include "extensions/browser/api/cookies/yab_cookie_store_policy.h"

#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/site_instance.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extensions_test.h"
#include "extensions/browser/test_extensions_browser_client.h"
#include "extensions/common/extension.h"
#include "extensions/common/extension_builder.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace extensions {
namespace {
constexpr char kExtensionId[] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr char kOtherExtensionId[] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
constexpr char kNamespaceA[] = "10000000-0000-4000-8000-000000000001";
constexpr char kNamespaceB[] = "10000000-0000-4000-8000-000000000002";

class CookieTestClient : public TestExtensionsBrowserClient {
 public:
  bool IsExtensionIncognitoEnabled(const ExtensionId&,
                                  content::BrowserContext*) const override {
    return incognito_enabled;
  }
  bool IsExtensionIncognitoEnabled(const Extension*,
                                  content::BrowserContext*) const override {
    return incognito_enabled;
  }
  bool incognito_enabled = false;
};

class YabCookieStorePolicyTest : public ExtensionsTest {
 public:
  void SetUp() override {
    auto client = std::make_unique<CookieTestClient>();
    client_ = client.get();
    SetExtensionsBrowserClient(std::move(client));
    ExtensionsTest::SetUp();
    extension_ = ExtensionBuilder("Native namespace test")
                     .SetID(kExtensionId)
                     .AddAPIPermission("cookies")
                     .AddHostPermission("https://example.test/*")
                     .Build();
    ASSERT_TRUE(ExtensionRegistry::Get(browser_context())->AddEnabled(extension_));
    policy_ = YabCookieStorePolicy::Get(browser_context(), /*create=*/true);
  }

  void TearDown() override {
    if (policy_) policy_->RevokeAll();
    policy_ = nullptr;
    ExtensionsTest::TearDown();
  }

  auto Config(content::BrowserContext* context, const char* name, bool memory = false) {
    return content::StoragePartitionConfig::Create(context, "YabWebsiteNamespace", name, memory);
  }

  std::unique_ptr<content::WebContents> Contents(
      content::BrowserContext* context, const char* name, bool memory = false) {
    auto site = content::SiteInstance::CreateForFixedStoragePartition(
        context, GURL(), Config(context, name, memory));
    content::WebContents::CreateParams params(context, std::move(site));
    params.desired_renderer_state = content::WebContents::CreateParams::kNoRendererProcess;
    return content::WebContents::Create(params);
  }

  std::string Grant(content::WebContents* proof, const char* name,
                    bool implicit_default = false, int tab_id = 41) {
    return policy_->Grant(browser_context(), proof->GetBrowserContext(), proof, kExtensionId,
        Config(proof->GetBrowserContext(), name, proof->GetBrowserContext()->IsOffTheRecord()),
        tab_id, implicit_default,
        base::BindRepeating([](bool* owner) { return *owner; }, &owner_current_));
  }

 protected:
  raw_ptr<CookieTestClient> client_ = nullptr;
  raw_ptr<YabCookieStorePolicy> policy_ = nullptr;
  scoped_refptr<const Extension> extension_;
  bool owner_current_ = true;
};

TEST_F(YabCookieStorePolicyTest, UnknownAndForeignStoresNeverResolve) {
  EXPECT_FALSE(policy_->Resolve(kExtensionId, "", true));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, "0", true));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, "1", true));
  auto contents = Contents(browser_context(), kNamespaceA);
  auto id = Grant(contents.get(), kNamespaceA);
  ASSERT_FALSE(id.empty());
  EXPECT_TRUE(policy_->Resolve(kExtensionId, id, true));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, "", true));
  EXPECT_FALSE(policy_->Resolve(kOtherExtensionId, id, true));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, "yab-unissued", true));
}

TEST_F(YabCookieStorePolicyTest, ImplicitDefaultDoesNotFollowAnotherNamespace) {
  auto a = Contents(browser_context(), kNamespaceA);
  auto b = Contents(browser_context(), kNamespaceB);
  const auto a_id = Grant(a.get(), kNamespaceA, true);
  ASSERT_FALSE(a_id.empty());
  EXPECT_TRUE(Grant(b.get(), kNamespaceB, true).empty());
  const auto b_id = Grant(b.get(), kNamespaceB, false);
  ASSERT_FALSE(b_id.empty());
  EXPECT_NE(a_id, b_id);
  auto implicit = policy_->Resolve(kExtensionId, "", true);
  ASSERT_TRUE(implicit);
  EXPECT_EQ(a_id, implicit->store_id());
  EXPECT_TRUE(implicit->Allows(a.get()));
  EXPECT_FALSE(implicit->Allows(b.get()));
  EXPECT_FALSE(policy_->Revoke(kOtherExtensionId, a_id));
  EXPECT_TRUE(policy_->Revoke(kExtensionId, a_id));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, "", true));
  EXPECT_TRUE(policy_->Resolve(kExtensionId, b_id, true));
}

TEST_F(YabCookieStorePolicyTest, RejectsWrongActualNativePartition) {
  auto contents = Contents(browser_context(), kNamespaceA);
  EXPECT_TRUE(Grant(contents.get(), kNamespaceB).empty());
  EXPECT_TRUE(policy_->Stores(extension_.get(), true).empty());
}

TEST_F(YabCookieStorePolicyTest, SharedProofsSurviveOneTabButNotAllTabs) {
  auto first = Contents(browser_context(), kNamespaceA);
  auto second = Contents(browser_context(), kNamespaceA);
  const auto id = Grant(first.get(), kNamespaceA, false, 41);
  ASSERT_FALSE(id.empty());
  EXPECT_EQ(id, Grant(second.get(), kNamespaceA, false, 42));
  auto lease = policy_->Resolve(kExtensionId, id, true);
  ASSERT_TRUE(lease);
  EXPECT_EQ((std::vector<int>{41, 42}), lease->TabIds());
  first.reset();
  EXPECT_TRUE(policy_->Resolve(kExtensionId, id, true));
  EXPECT_EQ((std::vector<int>{42}), lease->TabIds());
  second.reset();
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, true));
  EXPECT_TRUE(policy_->Stores(extension_.get(), true).empty());
}

TEST_F(YabCookieStorePolicyTest, ObservedOwnerRejectionCannotRevive) {
  auto contents = Contents(browser_context(), kNamespaceA);
  const auto id = Grant(contents.get(), kNamespaceA, true);
  ASSERT_FALSE(id.empty());
  auto lease = policy_->Resolve(kExtensionId, id, true);
  ASSERT_TRUE(lease);
  owner_current_ = false;
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, true));
  owner_current_ = true;
  EXPECT_FALSE(lease->IsCurrent(true));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, "", true));
  const auto replacement = Grant(contents.get(), kNamespaceA, true);
  EXPECT_FALSE(replacement.empty());
  EXPECT_NE(id, replacement);
}

TEST_F(YabCookieStorePolicyTest, ReloadCannotInheritPreviousExtensionCapability) {
  auto contents = Contents(browser_context(), kNamespaceA);
  const auto id = Grant(contents.get(), kNamespaceA);
  ASSERT_FALSE(id.empty());
  auto old_lease = policy_->Resolve(kExtensionId, id, true);
  ASSERT_TRUE(old_lease);
  auto replacement = ExtensionBuilder("Reloaded extension")
                         .SetID(kExtensionId).AddAPIPermission("cookies").Build();
  auto* registry = ExtensionRegistry::Get(browser_context());
  ASSERT_TRUE(registry->RemoveEnabled(kExtensionId));
  ASSERT_TRUE(registry->AddEnabled(replacement));
  EXPECT_NE(extension_.get(), replacement.get());
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, true));
  EXPECT_TRUE(policy_->Stores(replacement.get(), true).empty());
  EXPECT_FALSE(policy_->AllowsWebContents(replacement.get(), contents.get(), true));
  const auto replacement_id = Grant(contents.get(), kNamespaceA);
  EXPECT_FALSE(replacement_id.empty());
  EXPECT_NE(id, replacement_id);
  EXPECT_FALSE(old_lease->IsCurrent(true));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, true));
}

TEST_F(YabCookieStorePolicyTest, ObservedDisableDoesNotReviveOnSameInstance) {
  auto contents = Contents(browser_context(), kNamespaceA);
  const auto id = Grant(contents.get(), kNamespaceA);
  ASSERT_FALSE(id.empty());
  auto* registry = ExtensionRegistry::Get(browser_context());
  ASSERT_TRUE(registry->RemoveEnabled(kExtensionId));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, true));
  ASSERT_TRUE(registry->AddEnabled(extension_));
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, true));
}

TEST_F(YabCookieStorePolicyTest, CookiesApiPermissionStillRequired) {
  auto contents = Contents(browser_context(), kNamespaceA);
  auto no_permission = ExtensionBuilder("No cookies permission").SetID(kOtherExtensionId).Build();
  ASSERT_TRUE(ExtensionRegistry::Get(browser_context())->AddEnabled(no_permission));
  EXPECT_TRUE(policy_->Grant(browser_context(), browser_context(), contents.get(), kOtherExtensionId,
      Config(browser_context(), kNamespaceA), 41, false, base::BindRepeating([] { return true; })).empty());
}

TEST_F(YabCookieStorePolicyTest, PrivateRequiresChromeOptInAndRequestPermission) {
  auto contents = Contents(incognito_context(), kNamespaceA, true);
  EXPECT_TRUE(Grant(contents.get(), kNamespaceA).empty());
  client_->incognito_enabled = true;
  const auto id = Grant(contents.get(), kNamespaceA);
  ASSERT_FALSE(id.empty());
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, false));
  EXPECT_TRUE(policy_->Resolve(kExtensionId, id, true));
  client_->incognito_enabled = false;
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, true));
  client_->incognito_enabled = true;
  EXPECT_FALSE(policy_->Resolve(kExtensionId, id, true));
}
}  // namespace
}  // namespace extensions
