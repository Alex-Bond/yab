// A page's picture and its hide.
//
// Page.captureScreenshot asks the renderer for a fresh frame and waits for it
// to be presented; meanwhile its capturer (stay_hidden, stay_awake) keeps a
// hidden page painting, and its video capture lock wakes the page's hidden
// producer window, whose compositor draws again (WebContentsViewMac
// UpdateVideoCaptureLock, NativeWidgetMacNSWindowHost
// UpdateCompositorVisibility). With the page's view already down the page is
// not in what that window draws, its frame is never presented, and the
// picture strands: the hidden page and its window go on drawing (the stage's
// leaving picture did this, 4-6% CPU a hidden heavy tab and twice the GPU
// process's). With the view brought back up inside the hidden window the
// picture finishes, but the window stops drawing with the page in its last
// frame, and the GPU process keeps that frame until the tab is next shown.
// So a page is pictured as it is shown: the stage asks for its leaving
// picture before the page's hide (ChromiumPage snapshotInOrder), a hide that
// comes while a picture is in flight waits here, and then runs as it always
// does: view, empty frame, window (HideClearing).
struct PageSnapshot {
  std::string tab;
  uint64_t generation;
  NSDictionary* proof;
  NSString* request;
  NSDictionary* clip;
  // The page as it is shown now, copied from its surface (CopyPageSurface),
  // rather than drawn again for the picture (Page.captureScreenshot).
  bool surface = false;
  // Its pixels as they are, in shared memory (SharedPixels), not a JPEG.
  bool raw = false;
  bool finished = false;
};

// CEF patch 0118: a picture copied from the page's compositor surface and
// scaled by the GPU before it is read back, as Chromium's tab thumbnails are
// (ThumbnailTabHelper, RenderWidgetHostView::CopyFromSurface). It draws
// nothing again and holds no capturer, so no wake lock and no visibility.
#if defined(CEF_YAB_PAGE_SURFACE_VERSION) && CEF_API_ADDED(CEF_EXPERIMENTAL)
#define YABCORE_PAGE_SURFACE 1
class SurfaceCopy final : public CefPageSurfaceCallback {
 public:
  explicit SurfaceCopy(std::function<void(CefRefPtr<CefImage>)> done) : done_(std::move(done)) {}
  void OnPageSurface(CefRefPtr<CefImage> image) override {
    if (!done_) return;
    auto done = std::move(done_);
    done_ = nullptr;
    done(image && !image->IsEmpty() ? image : nullptr);
  }
 private:
  std::function<void(CefRefPtr<CefImage>)> done_;
  IMPLEMENT_REFCOUNTING(SurfaceCopy);
};
// A still's pixels for the client without a JPEG, base64 and a decode: a
// POSIX shared memory object only this user can open, under a name nobody
// can guess, sent by name. The client opens it, maps it and unlinks it; it
// is unlinked here too after a while, in case the client never came for it.
// In RAM only: a still never reaches the disk.
static NSDictionary* SharedPixels(CefRefPtr<CefImage> image) {
  int width = 0, height = 0;
  auto bits = image->GetAsBitmap(1, CEF_COLOR_TYPE_BGRA_8888, CEF_ALPHA_TYPE_PREMULTIPLIED, width, height);
  size_t size = bits ? bits->GetSize() : 0;
  if (width <= 0 || height <= 0 || size < size_t(width) * size_t(height) * 4) return nil;
  NSString* name = [@"/yc-" stringByAppendingString:[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:24]];
  int fd = shm_open(name.UTF8String, O_CREAT | O_EXCL | O_RDWR, 0600);
  if (fd < 0) return nil;
  void* map = ftruncate(fd, off_t(size)) == 0 ? mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
  close(fd);
  if (map == MAP_FAILED) { shm_unlink(name.UTF8String); return nil; }
  bits->GetData(map, size, 0);
  munmap(map, size);
  std::string kept = name.UTF8String;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ shm_unlink(kept.c_str()); });
  return @{@"shm": name, @"width": @(width), @"height": @(height), @"bytes": @(size), @"surface": @YES};
}
#else
#define YABCORE_PAGE_SURFACE 0
#endif

// HideClearing asks first: true holds the hide until the pictures in flight
// are taken (FinishSnapshot runs it then).
static bool HoldHideForPicture(Tab& t) {
  t.clearAfterCapture = t.capturing > 0;
  return t.clearAfterCapture;
}

static bool SnapshotDocumentCurrent(const std::shared_ptr<PageSnapshot>& capture) {
  auto found = tabs.find(capture->tab);
  return found != tabs.end() && !found->second.closing &&
      found->second.documentGeneration == capture->generation &&
      DocumentMatches(found->second, capture->proof);
}

static void FinishSnapshot(std::shared_ptr<PageSnapshot> capture,
                           NSDictionary* result, NSString* error) {
  if (capture->finished) return;
  capture->finished = true;
  auto found = tabs.find(capture->tab);
  if (found != tabs.end()) {
    auto& owner = found->second;
    --owner.capturing;
    if (!owner.closing && !owner.capturing && owner.clearAfterCapture && !owner.visible) HideClearing(owner);
#if YABCORE_DISCARD
    if (!owner.capturing && owner.frozen && !owner.visible && owner.browser)
      owner.browser->GetHost()->SetPageFrozen(true);
#endif
  }
  Reply(capture->request, result, error);
}

// quality 0 is PNG. A picture of a full-page window, base64, ran past the wire
// (4.5 to 6.8 MB on a 5K window): it steps down instead of failing.
static void CaptureSnapshot(std::shared_ptr<PageSnapshot> capture, int quality) {
  if (capture->finished) return;
  if (!SnapshotDocumentCurrent(capture)) {
    FinishSnapshot(capture, nil, @"Snapshot document changed"); return;
  }
  auto& owner = tabs.at(capture->tab);
  if (owner.viewCleared && owner.view && ProducerShown(owner)) {
    // Asked just after a hide (not the stage's leaving picture, which comes
    // before it): the window still shows, so the page is still visible to
    // itself and its renderer draws, but without its view that frame is never
    // presented. The view comes back at once, the clear timers retire, and the
    // whole hide runs again after the picture (FinishSnapshot).
    ++owner.visibleTurn;
    owner.clearAfterCapture = true;
    owner.viewCleared = false;
    owner.view->SetVisible(true);
  }
#if YABCORE_PAGE_SURFACE
  // A passing JPEG of the whole page as shown: copied, encoded here. A page
  // with no surface to copy (its view let go) is pictured as below.
  if (capture->surface && quality && !capture->clip && owner.browser && !owner.viewCleared) {
    capture->surface = false;
    owner.browser->GetHost()->CopyPageSurface(0, 0, new SurfaceCopy([capture, quality](CefRefPtr<CefImage> image) {
      if (capture->finished) return;
      if (!SnapshotDocumentCurrent(capture)) { FinishSnapshot(capture, nil, @"Snapshot document changed"); return; }
      if (!image) { CaptureSnapshot(capture, quality); return; }
      if (capture->raw) {
        if (NSDictionary* shared = SharedPixels(image)) { FinishSnapshot(capture, shared, nil); return; }
      }
      int width = 0, height = 0;
      NSData* data = nil;
      for (int q : {quality, 40}) {
        auto jpeg = image->GetAsJPEG(1, q, width, height);
        size_t size = jpeg ? jpeg->GetSize() : 0;
        if (!size) break;
        NSMutableData* bytes = [NSMutableData dataWithLength:size];
        jpeg->GetData(bytes.mutableBytes, size, 0);
        data = bytes;
        if (size * 4 / 3 < kMaxMessage - 4096) break;
        data = nil;
      }
      if (!data) { CaptureSnapshot(capture, quality); return; }
      FinishSnapshot(capture, @{@"data": [data base64EncodedStringWithOptions:0], @"surface": @YES}, nil);
    }));
    return;
  }
#endif
  // A hidden window's page is pictured as it is: its view brought up inside
  // the hidden window would draw a frame that stays in the GPU process until
  // the tab is next shown.
  NSMutableDictionary* options = [(quality ? @{@"format": @"jpeg", @"quality": @(quality), @"optimizeForSpeed": @YES, @"captureBeyondViewport": @NO}
                                  : @{@"format": @"png", @"captureBeyondViewport": @NO}) mutableCopy];
  // A part of the document, past the viewport: a whole page's picture.
  if (capture->clip) { options[@"clip"] = capture->clip; options[@"captureBeyondViewport"] = @YES; }
  CDP(owner, @"Page.captureScreenshot", options,
    [capture, quality](NSDictionary* result, NSString* error) {
      if (capture->finished) return;
      if (!SnapshotDocumentCurrent(capture)) {
        FinishSnapshot(capture, nil, @"Snapshot document changed"); return;
      }
      NSString* data = [result[@"data"] isKindOfClass:NSString.class] ? result[@"data"] : nil;
      if (!error && data.length > kMaxMessage - 4096 && quality != 40) {
        CaptureSnapshot(capture, quality ? 40 : 75); return;
      }
      FinishSnapshot(capture, result, error);
    });
}

static void SnapshotPage(std::string tab, uint64_t generation, NSDictionary* proof,
                         NSString* request, int quality, NSDictionary* clip = nil, bool surface = false, bool raw = false) {
  auto capture = std::make_shared<PageSnapshot>();
  capture->tab = tab; capture->generation = generation; capture->proof = proof;
  capture->request = request; capture->clip = clip; capture->surface = surface; capture->raw = raw;
  DRMWhenReady(tab, [capture, quality](Tab&) { CaptureSnapshot(capture, quality); },
               [capture](NSString* error) { FinishSnapshot(capture, nil, error); }, Running() + 10);
}

// How light the page is as it is shown, for the bar over it (Tab.reshade):
// the GPU scales the page's surface to a few pixels, and only numbers come
// back, the sums Tab.lightness takes of its own small picture (premultiplied
// 299 R + 587 G + 114 B, and alpha). No picture is encoded, sent or decoded.
static void PageTone(Tab& t, NSDictionary* p, NSString* request) {
#if YABCORE_PAGE_SURFACE
  if (!t.browser || t.closing || t.crashed) { Reply(request, nil, @"Page tone browser not ready"); return; }
  if (t.frozen) { Reply(request, nil, @"Page is frozen"); return; }
  if (!t.visible || t.viewCleared) { Reply(request, nil, @"Page is hidden"); return; }
  int width = std::clamp([p[@"width"] intValue], 1, 64), height = std::clamp([p[@"height"] intValue], 1, 64);
  std::string tab = t.id;
  uint64_t generation = t.documentGeneration;
  t.browser->GetHost()->CopyPageSurface(width, height, new SurfaceCopy([request, tab, generation](CefRefPtr<CefImage> image) {
    auto found = tabs.find(tab);
    if (found == tabs.end() || found->second.closing || found->second.documentGeneration != generation) {
      Reply(request, nil, @"Snapshot document changed"); return;
    }
    if (!image) { Reply(request, nil, @"No page surface"); return; }
    int w = 0, h = 0;
    auto bits = image->GetAsBitmap(1, CEF_COLOR_TYPE_BGRA_8888, CEF_ALPHA_TYPE_PREMULTIPLIED, w, h);
    size_t size = bits ? bits->GetSize() : 0;
    if (w <= 0 || h <= 0 || size < size_t(w) * size_t(h) * 4) { Reply(request, nil, @"No page surface"); return; }
    std::vector<uint8_t> px(size);
    bits->GetData(px.data(), size, 0);
    uint64_t sum = 0, cover = 0;
    for (size_t i = 0; i + 3 < size_t(w) * size_t(h) * 4; i += 4) {
      sum += 114 * uint64_t(px[i]) + 587 * uint64_t(px[i + 1]) + 299 * uint64_t(px[i + 2]);
      cover += px[i + 3];
    }
    Reply(request, @{@"sum": @(sum), @"cover": @(cover), @"pixels": @(w * h), @"width": @(w), @"height": @(h)});
  }));
#else
  (void)t; (void)p;
  Reply(request, nil, @"Unknown method");
#endif
}
