#ifndef YABCORE_MEDIA_PERMISSION_ROUTE_H_
#define YABCORE_MEDIA_PERMISSION_ROUTE_H_
#include <cstdint>
namespace yabcore {
enum class MediaPermissionRoute { kDeny, kDeviceQuestion, kChromeDefault };
struct MediaPermissionOwner {
  bool present = false, closing = true, read = true;
  bool adopted = false, internal = true, same_browser_frame = false;
};
// Classification only. kChromeDefault returns the untouched ORIGINAL native
// query to Chrome's request/registry/picker policy. It never means permission.
inline MediaPermissionRoute ClassifyMediaPermission(
    uint32_t mask, uint32_t devices, uint32_t desktop,
    const MediaPermissionOwner& owner) {
  if (!owner.present || owner.closing || owner.read || !devices || !desktop ||
      (devices & desktop) || !mask || (mask & ~(devices | desktop)))
    return MediaPermissionRoute::kDeny;
  if (mask & desktop) {
    if (!owner.adopted || owner.internal || !owner.same_browser_frame)
      return MediaPermissionRoute::kDeny;
    return MediaPermissionRoute::kChromeDefault;
  }
  return MediaPermissionRoute::kDeviceQuestion;
}
} // namespace yabcore
#endif
