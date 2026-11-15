#include "media_permission_route.h"
#include <cassert>
#include <initializer_list>
using yabcore::MediaPermissionRoute;
int main() {
  constexpr uint32_t devices = 3, desktop = 12;
  const yabcore::MediaPermissionOwner person{true, false, false, true, false, true};
  auto route = [&](uint32_t mask, const yabcore::MediaPermissionOwner& owner) {
    return yabcore::ClassifyMediaPermission(mask, devices, desktop, owner);
  };
  for (uint32_t mask : {1u, 2u, 3u}) assert(route(mask, person) == MediaPermissionRoute::kDeviceQuestion);
  for (uint32_t mask = 4; mask < 16; ++mask) assert(route(mask, person) == MediaPermissionRoute::kChromeDefault);
  // CEF maps GUM_TAB to0 today. No generic zero-mask delegation or unknown grant.
  assert(route(0, person) == MediaPermissionRoute::kDeny);
  assert(route(16, person) == MediaPermissionRoute::kDeny);
  assert(route(0x80000000u, person) == MediaPermissionRoute::kDeny);
  for (int condition = 0; condition < 6; ++condition) {
    auto bad = person;
    if (condition == 0) bad.present = false;
    if (condition == 1) bad.closing = true;
    if (condition == 2) bad.read = true;
    if (condition == 3) bad.adopted = false;
    if (condition == 4) bad.internal = true;
    if (condition == 5) bad.same_browser_frame = false;
    for (uint32_t mask = 4; mask < 16; ++mask) assert(route(mask, bad) == MediaPermissionRoute::kDeny);
  }
  for (uint32_t mask = 0; mask < 1024; ++mask) {
    auto read = person; read.read = true;
    assert(route(mask, read) == MediaPermissionRoute::kDeny);
    if (mask & ~15u) assert(route(mask, person) == MediaPermissionRoute::kDeny);
  }
  // Existing ordinary device question routing does not gain an unrelated
  // adopted/frame requirement. Read/closing/nil remain strict deny.
  auto device = person; device.adopted = false; device.internal = true; device.same_browser_frame = false;
  assert(route(3, device) == MediaPermissionRoute::kDeviceQuestion);
  assert(yabcore::ClassifyMediaPermission(4, 0, desktop, person) == MediaPermissionRoute::kDeny);
  assert(yabcore::ClassifyMediaPermission(4, devices, devices, person) == MediaPermissionRoute::kDeny);
}
