#ifndef YABCORE_PAGE_ZOOM_H_
#define YABCORE_PAGE_ZOOM_H_
#include <cmath>
#include <cstdint>

// The zoom a page is drawn at, for turning the pointer's AppKit points into
// the CSS pixels Input.dispatchMouseEvent and dispatchDragEvent take.
//
// CefBrowserHost::GetZoomLevel is the zoom controller's level. In manual mode
// that is a number its client keeps for itself: Chrome's PDF viewer puts its
// tab in manual mode and reports its own zoom there (fit to width, 190% in a
// wide window) while the page itself stays at the default zoom. The pointer's
// point divided by that zoom landed short of where it was, toward the top
// left: a thumbnail opened another page, a selection took other words (#1906).
// The page's own renderer says what it is drawn at (Page.getLayoutMetrics,
// cssVisualViewport.zoom): that is read once for a document and a controller
// level, and again when either changes.
namespace yabcore {

struct PageZoomCache {
  double zoom = 0;             // CSS pixels to points, as the renderer reported it
  uint64_t generation = 0;     // the document it was read for
  double level = NAN;          // the controller's level when it was read
  int asking = 0;              // reads in flight; events wait behind them, in order
  uint64_t askedFor = 0;       // the document those reads are for

  // A read is starting for this document. Reads for an earlier document
  // can't hold this one's events: those events are refused anyway.
  void Ask(uint64_t document) {
    if (askedFor != document) asking = 0, askedFor = document;
    ++asking;
  }

  void Answered(uint64_t document) {
    if (askedFor == document && asking > 0) --asking;
  }

  // Whether the kept zoom is this document's at this level, with nothing
  // asked before it that has not answered yet.
  bool Usable(uint64_t document, double controller) const {
    return zoom > 0 && (asking == 0 || askedFor != document) && generation == document && level == controller;
  }

  void Keep(double reported, uint64_t document, double controller) {
    zoom = reported, generation = document, level = controller;
  }
};

// What the renderer reported, or the controller's level where it reported
// nothing usable (an older engine without the field).
inline double PageZoomOr(double reported, double controllerLevel) {
  if (std::isfinite(reported) && reported > 0.01 && reported < 100) return reported;
  return std::pow(1.2, controllerLevel);
}

}  // namespace yabcore
#endif
