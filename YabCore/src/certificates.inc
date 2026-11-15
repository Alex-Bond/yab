// Keep CEF's original candidates and callback alive until the native picker
// replies. Never export a private key or accept an identity supplied by the UI.
static bool AskClientCertificate(Tab* tab, bool proxy, NSString* host, int port,
    const CefRequestHandler::X509CertificateList& certificates,
    CefRefPtr<CefSelectClientCertificateCallback> callback) {
  if (!tab || tab->closing || IsReadTab(tab) || tab->internal || certificates.empty() || certificates.size() > 256) {
    callback->Select(nullptr); return true;
  }
  NSMutableArray* encoded = [NSMutableArray array];
  for (auto certificate : certificates) {
    auto bytes = certificate ? certificate->GetDEREncoded() : nullptr;
    if (!bytes || !bytes->GetSize() || bytes->GetSize() > 65536) { callback->Select(nullptr); return true; }
    NSMutableData* data = [NSMutableData dataWithLength:bytes->GetSize()];
    if (bytes->GetData(data.mutableBytes, data.length, 0) != data.length) { callback->Select(nullptr); return true; }
    [encoded addObject:[data base64EncodedStringWithOptions:0]];
  }
  AskQuestion(tab, @"clientCertificate", @{@"host": host, @"port": @(port), @"proxy": @(proxy),
      @"certificates": encoded}, [callback, certificates](NSDictionary* p) {
    NSNumber* index = [p[@"index"] isKindOfClass:NSNumber.class] ? p[@"index"] : nil;
    double value = index ? index.doubleValue : -1;
    if (!std::isfinite(value) || value < 0 || value >= certificates.size() || value != std::floor(value)) {
      callback->Select(nullptr); return;
    }
    callback->Select(certificates[static_cast<size_t>(value)]);
  });
  return true;
}

// Only CEF-evaluated invalid chains arrive here. No global ignore-errors flag.
static bool AskCertificate(Tab* tab, cef_errorcode_t code, NSString* url,
                            CefRefPtr<CefSSLInfo> info, CefRefPtr<CefCallback> callback) {
  auto certificate = info ? info->GetX509Certificate() : nullptr;
  if (!tab || !certificate) { callback->Cancel(); return true; }
  CefX509Certificate::IssuerChainBinaryList chain;
  certificate->GetDEREncodedIssuerChain(chain);
  chain.insert(chain.begin(), certificate->GetDEREncoded());
  if (chain.empty() || chain.size() > 16) { callback->Cancel(); return true; }
  NSMutableArray* encoded = [NSMutableArray array];
  for (auto bytes : chain) {
    if (!bytes || !bytes->GetSize() || bytes->GetSize() > 65536) { callback->Cancel(); return true; }
    NSMutableData* data = [NSMutableData dataWithLength:bytes->GetSize()];
    if (bytes->GetData(data.mutableBytes, data.length, 0) != data.length) { callback->Cancel(); return true; }
    [encoded addObject:[data base64EncodedStringWithOptions:0]];
  }
  // Pinned certificate_query::AllowCertificateError denies subresources
  // before reaching CefRequestHandler. This callback is native main-frame
  // provenance, including redirects, not a comparison of request URLs.
  AskQuestion(tab, @"certificate", @{@"origin": url, @"chain": encoded, @"code": @(code),
      @"mainFrame": @YES,
      @"subject": Str(certificate->GetSubject()->GetDisplayName()),
      @"issuer": Str(certificate->GetIssuer()->GetDisplayName())},
    [callback](NSDictionary* p) { if ([p[@"allow"] boolValue]) callback->Continue(); else callback->Cancel(); });
  return true;
}
