// Download objects remain native; the app receives copied state and UUIDs.
// File publication belongs to Yab. Synchronizing Chromium's extension journal
// is an additional SDK capability, advertised before the app chooses to use it.
#if defined(CEF_YAB_DOWNLOAD_PUBLICATION_VERSION) && CEF_YAB_DOWNLOAD_PUBLICATION_VERSION >= 2
static constexpr bool nativeDownloadPublication = true;
#else
static constexpr bool nativeDownloadPublication = false;
#endif
struct NativeDownload {
  std::string tab;
  NSString* token;
  CefRefPtr<CefBeforeDownloadCallback> destination;
  CefRefPtr<CefDownloadItemCallback> control;
  bool announced = false, canceled = false, interrupted = false;
};
// Chromium allocates IDs per profile, not per helper. Browser identity keeps
// independent profile downloads with the same numeric ID from aliasing.
static std::map<std::pair<int, uint32_t>, NativeDownload> nativeDownloads;
static void UpdateDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                            CefRefPtr<CefDownloadItemCallback> callback) {
  if (!browser) return;
  auto i = nativeDownloads.find({browser->GetIdentifier(), item->GetId()});
  if (i == nativeDownloads.end()) return;
  i->second.control = callback;
  if (i->second.canceled && item->IsInProgress()) { callback->Cancel(); return; }
  // Chromium keeps a resumable interruption's partial file and request;
  // the entry stays so Yab's Try Again can resume that same native item.
  i->second.interrupted = item->IsInterrupted();
  if (!i->second.announced) return;
  auto tab = tabs.find(i->second.tab);
  NSMutableDictionary* p = [@{@"download": i->second.token, @"tab": @(i->second.tab.c_str()),
      @"received": @(item->GetReceivedBytes()), @"total": @(item->GetTotalBytes()),
      @"complete": @(item->IsComplete()), @"canceled": @(item->IsCanceled()),
      @"interrupted": @(item->IsInterrupted()), @"reason": @(item->GetInterruptReason()),
      @"path": Str(item->GetFullPath()), @"resumable": @(item->IsInterrupted() && callback != nullptr)} mutableCopy];
  Event(@"download.updated", tab == tabs.end() ? nullptr : &tab->second, p);
  if (item->IsComplete() || item->IsCanceled()) nativeDownloads.erase(i);
}
static bool BeginDownload(Tab* tab, CefRefPtr<CefDownloadItem> item, NSString* name,
                           CefRefPtr<CefBeforeDownloadCallback> callback) {
  // No count of downloads: Chrome has none (DownloadRequestLimiter asks
  // about a page's automatic ones, it doesn't count). Past a fixed 128 held
  // here (interrupted ones stay for Try Again) every new one was dropped.
  if (!tab || tab->internal || !tab->adopted) return true;
  auto& download = nativeDownloads[{tab->browser->GetIdentifier(), item->GetId()}];
  download.tab = tab->id; download.token = NSUUID.UUID.UUIDString;
  download.destination = callback; download.announced = true;
  NSMutableDictionary* opened = [@{@"download": download.token, @"url": Str(item->GetURL()),
      @"originalURL": Str(item->GetOriginalUrl()), @"name": name, @"mime": Str(item->GetMimeType()),
      @"nativeId": @(item->GetId()), @"publication": @(nativeDownloadPublication), @"total": @(item->GetTotalBytes())} mutableCopy];
  [opened addEntriesFromDictionary:DownloadProvenance(item)];
  Event(@"download.open", tab, opened);
  return true;
}

static bool DownloadPublicationRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"download.published"]) return false;
#if defined(CEF_YAB_DOWNLOAD_PUBLICATION_VERSION) && CEF_YAB_DOWNLOAD_PUBLICATION_VERSION >= 2
  const auto profile = profiles.find(Key(S(p, @"profile")));
  const int64_t identifier = [p[@"nativeId"] longLongValue];
  if (profile == profiles.end() || !profile->second.ready || identifier <= 0 ||
      identifier > UINT32_MAX || ![S(p, @"previousPath") isAbsolutePath] || ![S(p, @"path") isAbsolutePath]) {
    Reply(request, nil, @"Invalid native download publication"); return true;
  }
  const bool published = profile->second.context->SetDownloadPublishedPath(
      identifier, Key(S(p, @"previousPath")), Key(S(p, @"path")));
  Reply(request, published ? @{@"published": @YES} : nil,
        published ? nil : @"Native download publication was rejected");
#else
  // This SDK can't move Chromium's record to the published path. The file is
  // already published by Swift; only Chromium's own path for it stays the
  // finished part's, so the download completes instead of failing.
  Reply(request, @{@"published": @NO}, nil);
#endif
  return true;
}
static bool DownloadRequest(NSString* tab, NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"download.destination"] && ![method isEqual:@"download.cancel"] && ![method isEqual:@"download.resume"]) return false;
  auto i = std::find_if(nativeDownloads.begin(), nativeDownloads.end(), [&](const auto& row) {
    return row.second.tab == Key(tab) && [row.second.token isEqual:S(p, @"download")];
  });
  if (i == nativeDownloads.end()) { Reply(request, nil, @"Unknown download"); return true; }
  if ([method isEqual:@"download.resume"]) {
    if (!i->second.interrupted || !i->second.control) { Reply(request, nil, @"Download is not resumable"); return true; }
    i->second.interrupted = false;
    Reply(request);
    i->second.control->Resume();
    return true;
  }
  if ([method isEqual:@"download.cancel"] || !S(p, @"path").length) {
    auto download = i->second;
    nativeDownloads.erase(i);
    Reply(request);
    Event(@"download.updated", nullptr, @{@"tab": @(download.tab.c_str()), @"download": download.token,
                                         @"canceled": @YES, @"received": @0, @"total": @-1});
    if (download.control) download.control->Cancel();
    // Releasing the retained destination cancels a not-yet-started item.
    download.destination = nullptr;
    return true;
  }
  NSString* path = S(p, @"path");
  if (![path isAbsolutePath] || !i->second.destination) { Reply(request, nil, @"Invalid or already-set download destination"); return true; }
  auto destination = i->second.destination; i->second.destination = nullptr;
  Reply(request);
  destination->Continue(Key(path), false);
  return true;
}
