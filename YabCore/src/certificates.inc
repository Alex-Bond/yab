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
