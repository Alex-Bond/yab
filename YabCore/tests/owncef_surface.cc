#include "../src/owncef_surface.h"
#include <cassert>
#include <initializer_list>
#include <limits>

// Reject bad frame metadata without replacing a valid surface, and ensure
// context invalidation cannot retain old dimensions across a GPU/view reset.
int main() {
  yc::OwnCEFSurface surface;
  assert(surface.Update(12, 1600, 1200, 2));
  for (float factor : {0.f, -1.f, std::numeric_limits<float>::infinity(),
                        std::numeric_limits<float>::quiet_NaN()}) {
    assert(!surface.Update(13, 800, 600, factor));
    assert(surface.context == 12 && surface.pixelWidth == 1600 && surface.scale == 2);
  }
  assert(!surface.Update(13, 0, 600, 2));
  assert(!surface.Update(13, 800, -1, 2));
  assert(surface.context == 12);
  assert(surface.Update(0, 1600, 1200, 2));
  assert(surface.context == 0 && surface.pixelWidth == 0 && surface.pixelHeight == 0);
  assert(surface.Update(14, 1200, 800, 1));
  assert(surface.context == 14 && surface.pixelWidth == 1200 && surface.scale == 1);
}
