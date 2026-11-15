// Test-only dyld interposer. Never linked into Yab or YabCore.
// Log query class/service/account and caller PCs, never returned secret data.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <execinfo.h>
#include <unistd.h>
#include <dlfcn.h>
__attribute__((constructor)) static void Loaded() {
  fprintf(stderr, "KEYCHAIN_LOADED pid=%d\n", getpid());
}
static void Trace(const char* function, CFDictionaryRef query = nullptr) {
  @autoreleasepool {
    NSDictionary* q = (__bridge NSDictionary*)query;
    fprintf(stderr, "KEYCHAIN_TRACE pid=%d %s class=%s service=%s account=%s\n", getpid(), function,
      [[q[(__bridge id)kSecClass] description] UTF8String] ?: "-",
      [[q[(__bridge id)kSecAttrService] description] UTF8String] ?: "-",
      [[q[(__bridge id)kSecAttrAccount] description] UTF8String] ?: "-");
    if (query) fprintf(stderr, "KEYCHAIN_QUERY pid=%d data=%d attributes=%d all=%d domain=%s label=%s\n", getpid(),
      [q[(__bridge id)kSecReturnData] boolValue], [q[(__bridge id)kSecReturnAttributes] boolValue],
      [q[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitAll],
      [[q[(__bridge id)kSecAttrSecurityDomain] description] UTF8String] ?: "-",
      [[q[(__bridge id)kSecAttrLabel] description] UTF8String] ?: "-");
    void* frames[24];
    int count = backtrace(frames, 24);
    for (int i = 1; i < count; ++i) {
      Dl_info info = {};
      if (dladdr(frames[i], &info))
        fprintf(stderr, "KEYCHAIN_FRAME pid=%d %s +0x%lx\n", getpid(), info.dli_fname ?: "?",
          (unsigned long)((char*)frames[i] - (char*)info.dli_fbase));
    }
  }
}
static OSStatus Matching(CFDictionaryRef query, CFTypeRef* result) {
  Trace("SecItemCopyMatching", query);
  return SecItemCopyMatching(query, result);
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus FindGeneric(CFTypeRef keychains, UInt32 serviceLength, const char* service,
    UInt32 accountLength, const char* account, UInt32* length, void** data, SecKeychainItemRef* item) {
  @autoreleasepool {
    NSString* name = service ? [[NSString alloc] initWithBytes:service length:serviceLength encoding:NSUTF8StringEncoding] : nil;
    NSString* user = account ? [[NSString alloc] initWithBytes:account length:accountLength encoding:NSUTF8StringEncoding] : nil;
    Trace("SecKeychainFindGenericPassword", (__bridge CFDictionaryRef)@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
      (__bridge id)kSecAttrService:name ?: @"-", (__bridge id)kSecAttrAccount:user ?: @"-"});
  }
  return SecKeychainFindGenericPassword(keychains, serviceLength, service, accountLength, account, length, data, item);
}
static OSStatus CopyContent(SecKeychainItemRef item, SecItemClass* kind, SecKeychainAttributeList* attributes, UInt32* length, void** data) {
  Trace("SecKeychainItemCopyContent");
  return SecKeychainItemCopyContent(item, kind, attributes, length, data);
}
static OSStatus Callback(SecKeychainCallback callback, SecKeychainEventMask mask, void* context) {
  fprintf(stderr, "KEYCHAIN_MASK pid=%d mask=0x%x\n", getpid(), (unsigned)mask);
  Trace("SecKeychainAddCallback");
  return SecKeychainAddCallback(callback, mask, context);
}
__attribute__((used)) static struct { const void* replacement; const void* original; }
  interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void*)Matching, (const void*)SecItemCopyMatching},
    {(const void*)Callback, (const void*)SecKeychainAddCallback},
    {(const void*)FindGeneric, (const void*)SecKeychainFindGenericPassword},
    {(const void*)CopyContent, (const void*)SecKeychainItemCopyContent}
  };
#pragma clang diagnostic pop
