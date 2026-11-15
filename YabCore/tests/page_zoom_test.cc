#include "page_zoom.h"
#include <cassert>
#include <cmath>

// Chrome's PDF viewer in manual zoom mode: the controller says 190%, the page
// is drawn at 100%. The page's own report wins (#1906).
int main() {
  using yabcore::PageZoomCache;
  using yabcore::PageZoomOr;
  double viewer = std::log(1.9) / std::log(1.2);
  assert(PageZoomOr(1.0, viewer) == 1.0);
  assert(std::fabs(PageZoomOr(1.25, 0) - 1.25) < 1e-9);
  // Nothing usable reported: the controller's level, as before.
  assert(std::fabs(PageZoomOr(0, viewer) - 1.9) < 1e-9);
  assert(std::fabs(PageZoomOr(NAN, 1) - 1.2) < 1e-9);

  PageZoomCache cache;
  assert(!cache.Usable(1, viewer));
  cache.Ask(1);
  cache.Keep(1.0, 1, viewer);
  // An answer still out: later events wait behind it, in order.
  assert(!cache.Usable(1, viewer));
  cache.Answered(1);
  assert(cache.Usable(1, viewer) && cache.zoom == 1.0);
  // The viewer zooms again, or ⌘+ changes the page: read again.
  assert(!cache.Usable(1, viewer + 1));
  // Another document: read again.
  assert(!cache.Usable(2, viewer));
  // A read for an earlier document that never answers doesn't hold the next one.
  cache.Ask(2);
  cache.Ask(3);
  cache.Keep(1.5, 3, 0);
  cache.Answered(3);
  assert(cache.Usable(3, 0) && cache.zoom == 1.5);
  return 0;
}
