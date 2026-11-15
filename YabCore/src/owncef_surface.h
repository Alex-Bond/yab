#pragma once
#include <cmath>
#include <cstdint>

namespace yc {
struct OwnCEFSurface {
  uint32_t context = 0;
  int pixelWidth = 0, pixelHeight = 0;
  float scale = 1;

  bool Update(uint32_t value, int width, int height, float factor) {
    if (!std::isfinite(factor) || factor <= 0 || width < 0 || height < 0 ||
        (value && (!width || !height))) return false;
    context = value;
    pixelWidth = value ? width : 0;
    pixelHeight = value ? height : 0;
    scale = factor;
    return true;
  }
};
}
