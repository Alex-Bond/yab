#import <Foundation/Foundation.h>
#include <cassert>
#include <cmath>
#include <functional>
#include <iostream>
#include <memory>
#include <vector>
using CefString = NSString*;
template<class T> using CefRefPtr = std::shared_ptr<T>;
struct Binary {
  size_t GetSize() { return 1; }
  size_t GetData(void* out, size_t, size_t) { *(char*)out = 'a'; return 1; }
};
struct Certificate { std::shared_ptr<Binary> GetDEREncoded() { return std::make_shared<Binary>(); } };
using X509CertificateList = std::vector<std::shared_ptr<Certificate>>;
struct CefRequestHandler { using X509CertificateList = ::X509CertificateList; };
struct CefBrowser {};
struct CefSelectClientCertificateCallback {
  int calls = 0;
  std::shared_ptr<Certificate> selected;
  void Select(std::shared_ptr<Certificate> value) { ++calls; selected = value; }
};
struct Tab { bool closing = false, internal = false, read = false; };
static Tab tab;
static bool IsReadTab(Tab* t) { return t->read; }
static Tab* Find(CefRefPtr<CefBrowser>) { return &tab; }
static NSString* Str(NSString* s) { return s; }
static std::function<void(NSDictionary*)> answer;
static void AskQuestion(Tab*, NSString* kind, NSDictionary* values, std::function<void(NSDictionary*)> reply) {
  assert([kind isEqual:@"clientCertificate"]);
  assert([values[@"host"] isEqual:@"mtls.invalid"] && [values[@"port"] intValue] == 443);
  assert([values[@"certificates"] count] == 2);
  answer = reply;
}
#include CERTIFICATE_IMPLEMENTATION
int main(int argc, char**) { @autoreleasepool {
  Client client;
  auto a = std::make_shared<Certificate>(), b = std::make_shared<Certificate>();
  X509CertificateList certificates{a, b};
  auto ask = [&] {
    answer = nullptr;
    auto callback = std::make_shared<CefSelectClientCertificateCallback>();
    assert(client.OnSelectClientCertificate(nullptr, false, @"mtls.invalid", 443, certificates, callback));
    return callback;
  };
  auto callback = ask();
  if (argc > 1) {
    assert(!answer && callback->calls == 1 && !callback->selected);
    std::cout << "PASS untouched base skips 2 eligible certificates without asking\n"; return 0;
  }
  assert(answer && !callback->calls);
  answer(@{@"index": @1}); assert(callback->calls == 1 && callback->selected == b);
  std::cout << "PASS picker selects the original CEF candidate\n";
  for (NSDictionary* reply in @[@{}, @{@"index": @(-1)}, @{@"index": @2}, @{@"index": @0.5},
                                 @{@"index": @"0"}, @{@"index": @(NAN)}]) {
    callback = ask(); answer(reply); assert(callback->calls == 1 && !callback->selected);
  }
  std::cout << "PASS cancel and invalid indices do not select a certificate\n";
  for (int reason = 0; reason < 3; ++reason) {
    tab.closing = reason == 0; tab.internal = reason == 1; tab.read = reason == 2;
    callback = ask(); assert(!answer && callback->calls == 1 && !callback->selected);
  }
  tab = {}; certificates.clear(); callback = ask(); assert(!answer && callback->calls == 1 && !callback->selected);
  std::cout << "PASS closed, internal, read-only and empty-candidate requests do not prompt\n";
} }
